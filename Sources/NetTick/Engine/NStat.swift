import Darwin
import Foundation

/// 私有框架 NetworkStatistics 的桥接：系统对每条 TCP / UDP 连接记的收发字节。
///
/// 实测（2026-11-24，见项目 CLAUDE.md「取数方式」）：
/// - 不需要私有权限，但只给**当前用户**的进程的连接；root 和系统账户的收不到。
/// - 启动前就建立的连接也会报上来，计数从连接建立时累计 —— 调用方要自己记基线。
/// - `startAbsoluteTime` 计入睡眠时间，换算用 `mach_continuous_time()`。
/// - block 参数在 `@convention(c)` 函数类型里必须标 `@escaping`，否则回调一触发就崩。
///
/// 所有回调都在构造时传入的串行队列上执行。
final class NStat {

    struct Description {
        var pid: Int
        var epid: Int
        var processName: String
        var isTCP: Bool
        var interfaceIndex: Int
        var local: String
        var remote: String
        /// Unix 秒；拿不到时为 nil
        var start: Double?
    }

    typealias Ref = UnsafeMutableRawPointer
    private typealias CreateFn = @convention(c) (CFAllocator?, DispatchQueue, @escaping @convention(block) (Ref, Ref?) -> Void) -> Ref?
    private typealias AddFn = @convention(c) (Ref) -> Int32
    private typealias QueryFn = @convention(c) (Ref, @escaping @convention(block) () -> Void) -> Void
    private typealias DictBlockFn = @convention(c) (Ref, @escaping @convention(block) (CFDictionary) -> Void) -> Void
    private typealias VoidBlockFn = @convention(c) (Ref, @escaping @convention(block) () -> Void) -> Void

    private let queue: DispatchQueue
    private var manager: Ref?
    private var queryAll: QueryFn?
    private var queryDesc: QueryFn?
    private var nextID = 1

    /// (源 id, 描述)
    var onDescription: ((Int, Description) -> Void)?
    /// (源 id, 累计收, 累计发)
    var onCounts: ((Int, UInt64, UInt64) -> Void)?
    /// 源 id
    var onRemoved: ((Int) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// 打开框架、订阅全部 TCP / UDP。失败（系统升级后符号变了）返回 false，调用方降级成只显示总速率。
    func start() -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW) else {
            log("NetworkStatistics 打不开：\(String(cString: dlerror()))")
            return false
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { log("NetworkStatistics 缺符号 \(name)"); return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let create = sym("NStatManagerCreate", CreateFn.self),
              let addTCP = sym("NStatManagerAddAllTCP", AddFn.self),
              let addUDP = sym("NStatManagerAddAllUDP", AddFn.self),
              let setDesc = sym("NStatSourceSetDescriptionBlock", DictBlockFn.self),
              let setCounts = sym("NStatSourceSetCountsBlock", DictBlockFn.self),
              let setRemoved = sym("NStatSourceSetRemovedBlock", VoidBlockFn.self),
              let queryAll = sym("NStatManagerQueryAllSources", QueryFn.self) else { return false }
        self.queryAll = queryAll
        self.queryDesc = sym("NStatManagerQueryAllSourcesDescriptions", QueryFn.self)

        let mgr = create(kCFAllocatorDefault, queue) { [weak self] src, _ in
            guard let self else { return }
            let id = self.nextID
            self.nextID += 1
            setDesc(src) { [weak self] cf in
                guard let self, let d = Self.parse(cf as NSDictionary) else { return }
                self.onDescription?(id, d)
            }
            setCounts(src) { [weak self] cf in
                let d = cf as NSDictionary
                let rx = (d["rxBytes"] as? NSNumber)?.uint64Value ?? 0
                let tx = (d["txBytes"] as? NSNumber)?.uint64Value ?? 0
                self?.onCounts?(id, rx, tx)
            }
            setRemoved(src) { [weak self] in
                self?.onRemoved?(id)
            }
        }
        guard let mgr else { log("NStatManagerCreate 返回空"); return false }
        manager = mgr
        let t = addTCP(mgr), u = addUDP(mgr)
        log("NetworkStatistics 已订阅（TCP \(t)，UDP \(u)）")
        return true
    }

    /// 请求一轮计数；completion 在这一轮计数全部回调完之后（同一队列）执行。
    ///
    /// 不要每轮都 QueryAllSourcesDescriptions：新连接的描述系统会自己推一次，
    /// 每 2 秒把几百条连接的描述全要一遍，CPU 从约 0.3% 涨到约 2.8%（2026-11-24 实测）。
    /// 只在启动时要一次，补上启动前就有的那批老连接。
    func poll(completion: @escaping () -> Void) {
        guard let manager, let queryAll else { completion(); return }
        if !initialDescriptionsRequested {
            initialDescriptionsRequested = true
            queryDesc?(manager) {}
        }
        queryAll(manager) { completion() }
    }
    private var initialDescriptionsRequested = false

    // MARK: - 解析

    private static var timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    private static func parse(_ d: NSDictionary) -> Description? {
        guard let pid = (d["processID"] as? NSNumber)?.intValue else { return nil }
        var start: Double?
        if let st = (d["startAbsoluteTime"] as? NSNumber)?.uint64Value, st > 0 {
            let now = mach_continuous_time()
            let deltaNs = (Double(now) - Double(st)) * Double(timebase.numer) / Double(timebase.denom)
            start = Date().timeIntervalSince1970 - deltaNs / 1e9
        }
        return Description(
            pid: pid,
            epid: (d["epid"] as? NSNumber)?.intValue ?? 0,
            processName: d["processName"] as? String ?? "",
            isTCP: (d["provider"] as? String ?? "TCP") == "TCP",
            interfaceIndex: (d["interface"] as? NSNumber)?.intValue ?? 0,
            local: sockaddrString(d["localAddress"]),
            remote: sockaddrString(d["remoteAddress"]),
            start: start)
    }

    /// NSData 里的 sockaddr → "ip:port" / "[ipv6]:port"
    static func sockaddrString(_ v: Any?) -> String {
        if let s = v as? String { return s }
        guard let data = v as? Data, data.count >= 2 else { return "" }
        return data.withUnsafeBytes { raw -> String in
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch Int32(raw[1]) {
            case AF_INET where data.count >= MemoryLayout<sockaddr_in>.size:
                var sin = sockaddr_in()
                memcpy(&sin, raw.baseAddress!, MemoryLayout<sockaddr_in>.size)
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count))
                return "\(String(cString: buf)):\(UInt16(bigEndian: sin.sin_port))"
            case AF_INET6 where data.count >= MemoryLayout<sockaddr_in6>.size:
                var sin6 = sockaddr_in6()
                memcpy(&sin6, raw.baseAddress!, MemoryLayout<sockaddr_in6>.size)
                inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(buf.count))
                return "[\(String(cString: buf))]:\(UInt16(bigEndian: sin6.sin6_port))"
            default:
                return ""
            }
        }
    }
}

/// "1.2.3.4:443" / "[::1]:443" → (主机, 端口)
func splitHostPort(_ s: String) -> (host: String, port: Int) {
    guard !s.isEmpty else { return ("", 0) }
    if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
        let host = String(s[s.index(after: s.startIndex)..<close])
        let rest = s[s.index(after: close)...]          // ":443"
        return (host, Int(rest.dropFirst()) ?? 0)
    }
    guard let colon = s.lastIndex(of: ":") else { return (s, 0) }
    return (String(s[..<colon]), Int(s[s.index(after: colon)...]) ?? 0)
}

func isLoopbackHost(_ h: String) -> Bool {
    h.hasPrefix("127.") || h == "::1" || h == "localhost"
}
