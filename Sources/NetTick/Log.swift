import Foundation

/// 日志同时写 stderr 和 ~/Library/Logs/NetTick/nettick.log。文件每次启动截断，读到的永远是本次运行。
let kLogPath: String = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NetTick", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("nettick.log").path
}()

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
private let logHandle: FileHandle? = {
    FileManager.default.createFile(atPath: kLogPath, contents: nil)
    return FileHandle(forWritingAtPath: kLogPath)
}()
private let logQueue = DispatchQueue(label: "com.lifedever.NetTick.log")

func log(_ message: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(message)\n"
    logQueue.async {
        FileHandle.standardError.write(line.data(using: .utf8)!)
        logHandle?.write(line.data(using: .utf8)!)
    }
}

/// 当前二进制的编译时间，写进日志第一行，排查「改了没生效」时先看它。
func binaryBuildTime() -> String {
    let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return "未知" }
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f.string(from: date)
}
