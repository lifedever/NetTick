import Foundation

/// 挂载 / 卸载 DMG（自动更新用）。
///
/// macOS 27 上 `hdiutil attach -nobrowse` 和 `hdiutil detach` 都报「已弃用，改用 diskutil」（2026-11-25 发 0.2.0 时看到）。
/// 更新器编进已经发出去的版本，哪个命令哪天被删了就更新不了、也没法远程修，所以两个都试：
/// 先用新的 `diskutil image attach` / `diskutil eject`，老系统（14、15 还没有 `diskutil image`）退回 hdiutil。
enum DiskImage {
    typealias Command = (tool: String, args: [String])

    static func attachCommands(_ path: String) -> [Command] {
        [("/usr/sbin/diskutil", ["image", "attach", "--nobrowse", "--readOnly", path]),
         ("/usr/bin/hdiutil", ["attach", path, "-nobrowse", "-noverify", "-readonly"])]
    }

    static func detachCommands(_ mountPoint: String) -> [Command] {
        [("/usr/sbin/diskutil", ["eject", mountPoint]),
         ("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])]
    }

    /// 返回挂载点（/Volumes/…）；几个命令都不行返回 nil
    static func attach(_ path: String, commands: [Command]? = nil) -> String? {
        for c in commands ?? attachCommands(path) {
            guard let (status, out) = run(c), status == 0 else { continue }
            // 两个命令的输出都是「设备 \t 类型 \t 挂载点」一行一个分区，挂载点那一行带 /Volumes/
            if let line = out.components(separatedBy: "\n").first(where: { $0.contains("/Volumes/") }),
               let r = line.range(of: "/Volumes/") {
                return String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    @discardableResult
    static func detach(_ mountPoint: String, commands: [Command]? = nil) -> Bool {
        for c in commands ?? detachCommands(mountPoint) {
            if let (status, _) = run(c), status == 0 { return true }
        }
        return false
    }

    /// 弃用警告走 stderr，丢掉；只读 stdout
    private static func run(_ c: Command) -> (Int32, String)? {
        guard FileManager.default.isExecutableFile(atPath: c.tool) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.tool)
        p.arguments = c.args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }
}
