import Darwin
import Foundation

/// 物理网卡的累计收发字节（菜单栏的实时速率用它）。
///
/// 只算 en* 且类型是以太网（Wi-Fi、有线、USB 网卡都是）：utun 是代理 / VPN 的虚拟网卡，
/// 开着 TUN 模式时 App 的流量会先进 utun 再从 en0 出去，两个都算就是双倍；lo0 是本机回环。
/// 用 NET_RT_IFLIST2 取 64 位计数 —— getifaddrs 给的 if_data 是 32 位，4 GB 就回绕。
enum InterfaceCounters {

    struct Totals {
        var rx: UInt64
        var tx: UInt64
    }

    static func read() -> Totals? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var totals = Totals(rx: 0, tx: 0)
        var offset = 0
        buf.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let base = raw.baseAddress!.advanced(by: offset)
                let hdr = base.loadUnaligned(as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                if msgLen <= 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = base.loadUnaligned(as: if_msghdr2.self)
                    if Int32(h2.ifm_data.ifi_type) == IFT_ETHER, isPhysical(index: Int(h2.ifm_index)) {
                        totals.rx &+= h2.ifm_data.ifi_ibytes
                        totals.tx &+= h2.ifm_data.ifi_obytes
                    }
                }
                offset += msgLen
            }
        }
        return totals
    }

    private static var nameCache: [Int: Bool] = [:]
    private static let lock = NSLock()

    private static func isPhysical(index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let c = nameCache[index] { return c }
        let name = interfaceName(index)
        let ok = name.hasPrefix("en")
        nameCache[index] = ok
        return ok
    }
}

/// 网卡序号 → 名字（en0、utun8…），带缓存
func interfaceName(_ index: Int) -> String {
    InterfaceNameCache.shared.name(index)
}

private final class InterfaceNameCache {
    static let shared = InterfaceNameCache()
    private var cache: [Int: String] = [:]
    private let lock = NSLock()

    func name(_ index: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        if let n = cache[index] { return n }
        var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        let n = if_indextoname(UInt32(index), &buf) != nil ? String(cString: buf) : ""
        if !n.isEmpty { cache[index] = n }   // 拿不到的不缓存：虚拟网卡可能稍后才建出来
        return n
    }
}
