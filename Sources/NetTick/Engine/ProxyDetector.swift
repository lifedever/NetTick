import Foundation
import SystemConfiguration

/// 认出代理软件（通用规则，不对接任何一家的接口）：
/// 1. 系统代理设置里指向本机的端口 —— 谁在那个端口上接连接，谁就是代理软件；
/// 2. 已连接的 VPN / 网络扩展服务（`scutil --nc list`）的 bundle id —— Surge、Shadowrocket、Tailscale 这类。
///
/// 代理软件自己的连接不进 App 排行：App 的流量已经在 App 那头算过一次（经虚拟网卡或本机代理端口），
/// 代理软件转发出去的那份再算就是双倍。
final class ProxyDetector {

    struct Snapshot {
        var ports: Set<Int> = []
        var vpnBundleIDs: [String] = []
    }

    /// 只在采集队列上读
    private(set) var snapshot = Snapshot()

    /// 在后台队列算好，交给 apply 回到采集队列赋值
    static func probe() -> Snapshot {
        var s = Snapshot()
        if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            for (enable, host, port) in [("HTTPEnable", "HTTPProxy", "HTTPPort"),
                                         ("HTTPSEnable", "HTTPSProxy", "HTTPSPort"),
                                         ("SOCKSEnable", "SOCKSProxy", "SOCKSPort")] {
                guard (proxies[enable] as? NSNumber)?.boolValue == true,
                      let h = proxies[host] as? String, isLoopbackHost(h),
                      let p = (proxies[port] as? NSNumber)?.intValue else { continue }
                s.ports.insert(p)
            }
        }
        s.vpnBundleIDs = connectedVPNBundleIDs()
        return s
    }

    func apply(_ s: Snapshot) {
        snapshot = s
    }

    func isProxyApp(_ identity: AppIdentity, exePath: String) -> Bool {
        guard !snapshot.vpnBundleIDs.isEmpty else { return false }
        for id in snapshot.vpnBundleIDs {
            if let b = identity.bundleID, b.hasPrefix(id) { return true }
            // 网络扩展在 /Library/SystemExtensions/<UUID>/<bundle id>.systemextension 里，路径里就带着 bundle id
            if exePath.contains("/" + id) { return true }
        }
        return false
    }

    /// `scutil --nc list` 里状态是 Connected 的服务 → [VPN:bundle.id]
    private static func connectedVPNBundleIDs() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = ["--nc", "list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        var ids: [String] = []
        for line in text.split(separator: "\n") where line.contains("(Connected)") {
            guard let open = line.range(of: "[VPN:"), let close = line[open.upperBound...].firstIndex(of: "]") else { continue }
            ids.append(String(line[open.upperBound..<close]))
        }
        return ids
    }
}
