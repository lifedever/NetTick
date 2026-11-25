import AppKit
import Darwin

/// 一条连接算到哪个「App」头上。
struct AppIdentity: Hashable {
    enum Kind: Int {
        case app = 0        // 有 .app 的普通程序（Helper 进程都并到外层 App）
        case cli = 1        // 命令行程序
        case system = 2     // 系统服务（/System、/usr/libexec…），排行里合成一行
        case other = 3      // 网卡合计里分不到具体 App 的部分（见 Queries.otherBytes）
    }
    /// 存库用的键：App 用 bundle id，命令行用 "cli:名字"，系统服务统一 "system"
    var key: String
    var name: String
    var kind: Kind
    var bundleID: String?
    /// 取图标用：App 是 .app 的路径，命令行是可执行文件路径
    var path: String

    static let systemKey = "system"
    static let otherKey = "other"

    /// 「其他」：物理网卡的量减去所有 App 记到的量。统计接口只给当前用户的连接，root 和其他系统账户的进程
    /// （系统更新之类）看不到；代理、VPN 的加密开销也只出现在网卡上。都归到这一行，各行加起来等于网卡的量。
    static let other = AppIdentity(key: otherKey, name: "其他", kind: .other, bundleID: nil, path: "")
}

/// pid → AppIdentity。只在采集队列上调用。
final class AppResolver {

    private struct Entry {
        var identity: AppIdentity
        var exePath: String
        var lastUsed: Date
    }
    private var cache: [Int: Entry] = [:]
    private var lastSweep = Date()

    /// - Parameters:
    ///   - pid: 连接所属进程
    ///   - epid: 「代谁发的」进程（nsurlsessiond 替 App 下载时是那个 App）
    ///   - processName: 系统给的进程名，进程已退出、拿不到路径时用它
    func resolve(pid: Int, epid: Int, processName: String) -> (AppIdentity, String) {
        sweep()
        let own = lookup(pid: pid, processName: processName)
        // 代发的流量算到委托方头上，但只在委托方是一个真正的 App 时（避免算到 launchd 之类）
        if epid > 0, epid != pid {
            let delegate = lookup(pid: epid, processName: "")
            if delegate.identity.kind == .app, own.identity.kind != .app {
                return (delegate.identity, displayProcessName(own))
            }
        }
        return (own.identity, displayProcessName(own))
    }

    /// 进程的可执行文件路径（拿不到为空）
    func executablePath(pid: Int) -> String {
        lookup(pid: pid, processName: "").exePath
    }

    private func displayProcessName(_ e: Entry) -> String {
        let n = (e.exePath as NSString).lastPathComponent
        return n.isEmpty ? e.identity.name : n
    }

    private func lookup(pid: Int, processName: String) -> Entry {
        if var e = cache[pid] {
            e.lastUsed = Date()
            cache[pid] = e
            return e
        }
        let path = Self.pidPath(pid)
        let identity = Self.identify(path: path, fallbackName: processName)
        let e = Entry(identity: identity, exePath: path, lastUsed: Date())
        // 路径拿不到（进程已退出）就不缓存，pid 很快会被复用
        if !path.isEmpty { cache[pid] = e }
        return e
    }

    /// 十分钟没用到的 pid 丢掉，防 pid 复用后认错人
    private func sweep() {
        guard Date().timeIntervalSince(lastSweep) > 60 else { return }
        lastSweep = Date()
        let cutoff = Date().addingTimeInterval(-600)
        cache = cache.filter { $0.value.lastUsed > cutoff }
    }

    static func pidPath(_ pid: Int) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    // MARK: - 归类规则

    /// 用户会当成「一个 App」的 .app 都在这些目录下；系统私有框架里的 .app 是后台组件
    private static let userAppRoots = ["/Applications/", "/System/Applications/", "/System/Library/CoreServices/Applications/",
                                       NSHomeDirectory() + "/Applications/"]
    private static let systemRoots = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/", "/sbin/"]

    static func identify(path: String, fallbackName: String) -> AppIdentity {
        guard !path.isEmpty else {
            let name = fallbackName.isEmpty ? "未知进程" : fallbackName
            return AppIdentity(key: "cli:" + name, name: name, kind: .cli, bundleID: nil, path: "")
        }
        // 最外层的 .app
        var outerApp: String?
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { outerApp = url.path }
        }
        if var app = outerApp {
            let underUserRoot = userAppRoots.contains { app.hasPrefix($0) }
            let underSystem = systemRoots.contains { app.hasPrefix($0) }
            if underUserRoot || !underSystem {
                let bundleID = Bundle(path: app)?.bundleIdentifier
                // iPad 应用在 Mac 上跑时路径是临时挂载（…/Wrapper/xxx.app），重启就没了：换成装在 /Applications 的那一份
                if app.contains("/Wrapper/"), let id = bundleID,
                   let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    app = installed.path
                }
                let name = FileManager.default.displayName(atPath: app)
                    .replacingOccurrences(of: ".app", with: "")
                return AppIdentity(key: bundleID ?? app, name: name, kind: .app, bundleID: bundleID, path: app)
            }
        }
        if systemRoots.contains(where: { path.hasPrefix($0) }) {
            return AppIdentity(key: AppIdentity.systemKey, name: "系统服务", kind: .system, bundleID: nil, path: "")
        }
        let name = cliName(path)
        return AppIdentity(key: "cli:" + name, name: name, kind: .cli, bundleID: nil, path: path)
    }

    /// 命令行程序的名字。可执行文件按版本号命名的（比如装在 …/<名字>/versions/2.1.331），
    /// 往上找第一个不像版本号、也不是 versions / bin 的目录名。
    static func cliName(_ path: String) -> String {
        var comps = (path as NSString).pathComponents
        guard let exe = comps.popLast() else { return path }
        guard looksLikeVersion(exe) else { return exe }
        while let dir = comps.popLast() {
            let lower = dir.lowercased()
            if looksLikeVersion(dir) || ["versions", "version", "bin", "current", "/"].contains(lower) { continue }
            return dir
        }
        return exe
    }

    static func looksLikeVersion(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber).count
        return digits > 0 && s.contains(".") && s.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter && $0.isLowercase }
            && s.first?.isNumber == true
    }
}
