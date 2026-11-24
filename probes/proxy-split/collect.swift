// 走代理识别探针 · 采集器
//
// 记下系统看到的每条连接（NetworkStatistics 私有框架），供 analyze.py 离线跑「通用」的走代理 / 直连算法。
// Surge 的请求记录只当标准答案存进 truth.json，算法本身不读它。
//
//   swiftc -O collect.swift -o /tmp/nettick-collect && /tmp/nettick-collect 30   # 跑 30 分钟
//
// 产物在 ~/Library/Logs/NetTick/probe/：flows.json  truth.json  env.json  collect.log
import Foundation
import SystemConfiguration

// MARK: - 输出

let outDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NetTick/probe")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let logURL = outDir.appendingPathComponent("collect.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try! FileHandle(forWritingTo: logURL)
let logQueue = DispatchQueue(label: "log")
func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    logQueue.async { logHandle.write(line.data(using: .utf8)!) }
    FileHandle.standardError.write(line.data(using: .utf8)!)
}
func writeJSON(_ obj: Any, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    let tmp = outDir.appendingPathComponent(name + ".tmp")
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { log("写 \(name) 失败：序列化"); return }
    do {
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    } catch {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }
}

// MARK: - NetworkStatistics

typealias Ref = UnsafeMutableRawPointer
guard let nsHandle = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW) else {
    log("dlopen NetworkStatistics 失败"); exit(1)
}
func sym<T>(_ name: String, _ type: T.Type) -> T {
    guard let p = dlsym(nsHandle, name) else { log("缺符号 \(name)"); exit(1) }
    return unsafeBitCast(p, to: type)
}
// block 参数必须标 @escaping，否则回调触发时崩溃（见记忆 reference-macos-per-app-traffic-api）
typealias CreateFn = @convention(c) (CFAllocator?, DispatchQueue, @escaping @convention(block) (Ref, Ref?) -> Void) -> Ref?
typealias AddFn = @convention(c) (Ref) -> Int32
typealias QueryFn = @convention(c) (Ref, @escaping @convention(block) () -> Void) -> Void
typealias DictBlockFn = @convention(c) (Ref, @escaping @convention(block) (CFDictionary) -> Void) -> Void
typealias VoidBlockFn = @convention(c) (Ref, @escaping @convention(block) () -> Void) -> Void
let nsCreate = sym("NStatManagerCreate", CreateFn.self)
let nsAddTCP = sym("NStatManagerAddAllTCP", AddFn.self)
let nsAddUDP = sym("NStatManagerAddAllUDP", AddFn.self)
let nsQueryAll = sym("NStatManagerQueryAllSources", QueryFn.self)
let nsQueryDesc = sym("NStatManagerQueryAllSourcesDescriptions", QueryFn.self)
let nsSetDesc = sym("NStatSourceSetDescriptionBlock", DictBlockFn.self)
let nsSetCounts = sym("NStatSourceSetCountsBlock", DictBlockFn.self)
let nsSetRemoved = sym("NStatSourceSetRemovedBlock", VoidBlockFn.self)

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
/// mach 绝对时间 → Unix 秒
func wallClock(machTime: UInt64) -> Double {
    let nowMach = mach_continuous_time()   // startAbsoluteTime 计入了睡眠时间，要用 continuous 时钟换算
    let deltaNs = (Double(nowMach) - Double(machTime)) * Double(timebase.numer) / Double(timebase.denom)
    return Date().timeIntervalSince1970 - deltaNs / 1e9
}

func addrString(_ v: Any?) -> String? {
    if let s = v as? String { return s }
    guard let d = v as? Data, d.count >= 2 else { return nil }
    return d.withUnsafeBytes { raw -> String? in
        let family = Int32(raw[1])
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if family == AF_INET, d.count >= MemoryLayout<sockaddr_in>.size {
            var sin = sockaddr_in()
            memcpy(&sin, raw.baseAddress!, MemoryLayout<sockaddr_in>.size)
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count))
            return "\(String(cString: buf)):\(UInt16(bigEndian: sin.sin_port))"
        }
        if family == AF_INET6, d.count >= MemoryLayout<sockaddr_in6>.size {
            var sin6 = sockaddr_in6()
            memcpy(&sin6, raw.baseAddress!, MemoryLayout<sockaddr_in6>.size)
            inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(buf.count))
            return "[\(String(cString: buf))]:\(UInt16(bigEndian: sin6.sin6_port))"
        }
        return nil
    }
}

func ifName(_ index: Int) -> String {
    var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
    return if_indextoname(UInt32(index), &buf) != nil ? String(cString: buf) : "if\(index)"
}

// MARK: - 进程信息

var procCache: [Int: [String: Any]] = [:]
func processInfo(_ pid: Int) -> [String: Any] {
    if let c = procCache[pid] { return c }
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
    let path = n > 0 ? String(cString: buf) : ""
    var info: [String: Any] = ["path": path]
    // 最近的 bundle（任何带 Contents/Info.plist 的目录）和最外层的 .app
    var url = URL(fileURLWithPath: path)
    var nearestBundleID: String?
    var outerApp: String?
    while url.path != "/" && !path.isEmpty {
        url.deleteLastPathComponent()
        let plist = url.appendingPathComponent("Contents/Info.plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            if nearestBundleID == nil,
               let d = NSDictionary(contentsOf: plist), let id = d["CFBundleIdentifier"] as? String {
                nearestBundleID = id
            }
            if url.pathExtension == "app" { outerApp = url.path }
        }
    }
    if let b = nearestBundleID { info["bundleID"] = b }
    if let a = outerApp { info["app"] = a }
    procCache[pid] = info
    return info
}

// MARK: - 连接记录

final class Flow {
    let id: Int
    var desc: [String: Any] = [:]
    var rx = 0, tx = 0
    var firstSeen = Date().timeIntervalSince1970
    var removedAt: Double?
    var series: [[Double]] = []   // [t, rx, tx]，只在变化时记
    init(id: Int) { self.id = id }
}
let q = DispatchQueue(label: "nstat")
var flows: [Int: Flow] = [:]
var nextID = 1
var descSampleLogged = false

let mgr = nsCreate(kCFAllocatorDefault, q) { src, _ in
    let flow = Flow(id: nextID); nextID += 1
    flows[flow.id] = flow
    nsSetDesc(src) { cf in
        let d = cf as NSDictionary
        if !descSampleLogged {
            descSampleLogged = true
            let types = d.map { "\($0.key)=\(type(of: $0.value))" }.sorted().joined(separator: " ")
            log("description 样例字段类型：\(types)")
        }
        var out: [String: Any] = [:]
        for key in ["processID", "epid", "processName", "provider", "TCPState", "uniqueProcessID", "ifWiFi"] {
            if let v = d[key] { out[key] = "\(v)" }
        }
        if let pid = d["processID"] as? Int { out["pid"] = pid; out["proc"] = processInfo(pid) }
        if let epid = d["epid"] as? Int { out["epid"] = epid; if epid > 0 { out["eproc"] = processInfo(epid) } }
        if let i = d["interface"] as? Int { out["ifIndex"] = i; out["ifName"] = ifName(i) }
        out["local"] = addrString(d["localAddress"]) ?? ""
        out["remote"] = addrString(d["remoteAddress"]) ?? ""
        if let st = d["startAbsoluteTime"] as? UInt64 { out["start"] = wallClock(machTime: st) }
        else if let st = d["startAbsoluteTime"] as? NSNumber { out["start"] = wallClock(machTime: st.uint64Value) }
        flow.desc = out
    }
    nsSetCounts(src) { cf in
        let d = cf as NSDictionary
        let rx = (d["rxBytes"] as? Int) ?? flow.rx
        let tx = (d["txBytes"] as? Int) ?? flow.tx
        if rx != flow.rx || tx != flow.tx {
            flow.rx = rx; flow.tx = tx
            if flow.series.count < 4000 { flow.series.append([Date().timeIntervalSince1970, Double(rx), Double(tx)]) }
        }
    }
    nsSetRemoved(src) {
        flow.removedAt = Date().timeIntervalSince1970
    }
}
guard let mgr else { log("NStatManagerCreate 返回空"); exit(1) }
log("addTCP=\(nsAddTCP(mgr)) addUDP=\(nsAddUDP(mgr))")

// MARK: - 标准答案（Surge），只存不用

let surgeCLI = ["/usr/local/bin/surge-cli", "/opt/homebrew/bin/surge-cli", "/Applications/Surge.app/Contents/Applications/surge-cli"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }
var truth: [Int: [String: Any]] = [:]
let truthQueue = DispatchQueue(label: "truth")
func runCLI(_ args: [String]) -> Data? {
    guard let cli = surgeCLI else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}
func pollTruth() {
    for kind in ["recent", "active"] {
        guard let data = runCLI(["dump", kind, "--raw"]),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let list = obj.values.compactMap { $0 as? [[String: Any]] }.first { $0.first?["id"] != nil } ?? []
        for r in list {
            guard let id = r["id"] as? Int else { continue }
            var keep: [String: Any] = [:]
            for k in ["id", "pid", "processPath", "remoteHost", "remoteAddress", "sourceAddress", "sourcePort",
                      "interface", "policyName", "rule", "takeoverMode", "inBytes", "outBytes", "completed",
                      "startDate", "completedDate", "method", "failed", "rejected"] {
                if let v = r[k], !(v is NSNull) { keep[k] = v }
            }
            truth[id] = keep   // 后来的覆盖先前的：字节数只增不减
        }
    }
}

// MARK: - 环境（代理设置、隧道、默认路由）

@Sendable func shell(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}
func snapshotEnv() -> [String: Any] {
    var env: [String: Any] = [:]
    if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
        env["systemProxies"] = proxies.mapValues { "\($0)" }
    }
    env["vpnServices"] = shell("/usr/sbin/scutil", ["--nc", "list"])
    env["defaultRoute"] = shell("/sbin/route", ["-n", "get", "default"])
    env["ifconfig"] = shell("/sbin/ifconfig", ["-l"])
    return env
}

// MARK: - 落盘

func dump(final: Bool) {
    q.sync {
        let arr: [[String: Any]] = flows.values.sorted { $0.id < $1.id }.map { f in
            var o = f.desc
            o["id"] = f.id; o["rx"] = f.rx; o["tx"] = f.tx; o["firstSeen"] = f.firstSeen
            if let r = f.removedAt { o["removedAt"] = r }
            o["series"] = f.series
            return o
        }
        writeJSON(arr, "flows.json")
    }
    truthQueue.sync { writeJSON(Array(truth.values), "truth.json") }
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    var child = rusage(); getrusage(RUSAGE_CHILDREN, &child)
    let selfCPU = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    let childCPU = Double(child.ru_utime.tv_sec) + Double(child.ru_utime.tv_usec) / 1e6 + Double(child.ru_stime.tv_sec) + Double(child.ru_stime.tv_usec) / 1e6
    let elapsed = Date().timeIntervalSince(startedAt)
    log(String(format: "%@ 连接 %d 条，答案 %d 条；本进程 CPU %.2fs / %.0fs（%.2f%%），surge-cli 子进程 CPU %.2fs，RSS %.1f MB",
               final ? "结束" : "进度", flows.count, truth.count, selfCPU, elapsed, selfCPU / max(elapsed, 1) * 100,
               childCPU, Double(usage.ru_maxrss) / 1_048_576))
}

// MARK: - 主循环

let minutes = Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30
let startedAt = Date()
writeJSON(snapshotEnv(), "env.json")
log("开始采集 \(minutes) 分钟；surge-cli：\(surgeCLI ?? "没找到，不记答案")")

let tick = DispatchSource.makeTimerSource(queue: q)
tick.schedule(deadline: .now(), repeating: 2.0)
tick.setEventHandler { nsQueryDesc(mgr) {}; nsQueryAll(mgr) {} }
tick.resume()

let truthTimer = DispatchSource.makeTimerSource(queue: truthQueue)
truthTimer.schedule(deadline: .now(), repeating: 3.0)
truthTimer.setEventHandler { pollTruth() }
truthTimer.resume()

let saver = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
saver.schedule(deadline: .now() + 300, repeating: 300)
saver.setEventHandler { dump(final: false) }
saver.resume()

DispatchQueue.global().asyncAfter(deadline: .now() + minutes * 60) {
    var env = snapshotEnv(); env["endedAt"] = Date().timeIntervalSince1970; env["startedAt"] = startedAt.timeIntervalSince1970
    writeJSON(env, "env.json")
    dump(final: true)
    logQueue.sync {}
    exit(0)
}
dispatchMain()
