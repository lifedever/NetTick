import Darwin
import Foundation

/// 物理网卡的累计收发字节（菜单栏的实时速率、开机以来的总量都用它）。计数从开机起累计，休眠唤醒不清零。
///
/// 只算 en* 且类型是以太网（Wi-Fi、有线、USB 网卡都是）：utun 是代理 / VPN 的虚拟网卡，
/// 开着 TUN 模式时 App 的流量会先进 utun 再从 en0 出去，两个都算就是双倍；lo0 是本机回环。
///
/// 用 IFMIB（net.link.generic.ifdata.<序号>.general）逐个网卡读 if_data64。
/// 别用 NET_RT_IFLIST2：if_msghdr2 里虽然也是 if_data64，实测（2026-11-25，macOS 27）给 App 的值被截成 32 位，
/// 每 4 GB 回绕（en0 实际 38.4 GB，读到 4.06 GB，正好是除以 2³² 的余数）；IFMIB 和 netstat -ib 一致。
/// getifaddrs 给的 if_data 本来就是 32 位。
enum InterfaceCounters {

    struct Totals {
        var rx: UInt64
        var tx: UInt64
    }

    static func read() -> Totals? {
        guard let list = if_nameindex() else { return nil }
        defer { if_freenameindex(list) }
        var totals = Totals(rx: 0, tx: 0)
        var any = false
        var p = list
        while p.pointee.if_index != 0 {
            if let cname = p.pointee.if_name, String(cString: cname).hasPrefix("en"),
               let d = ifData(index: Int32(p.pointee.if_index)), Int32(d.ifi_type) == IFT_ETHER {
                totals.rx &+= d.ifi_ibytes
                totals.tx &+= d.ifi_obytes
                any = true
            }
            p = p.advanced(by: 1)
        }
        return any ? totals : nil
    }

    private static func ifData(index: Int32) -> if_data64? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
        var data = ifmibdata()
        var len = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, 6, &data, &len, nil, 0) == 0 else { return nil }
        return data.ifmd_data
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
