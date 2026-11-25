import AppKit
import Security
import SwiftUI

/// 从 GitHub Releases 检查并自动安装新版本（照 TabFlick 的更新器）：
/// 找当前架构的 DMG → 下载并核对字节数 → 挂载 → 核对包里的 App（bundle id、版本号、同一张证书签的）
/// → 退出 → 外部脚本等旧进程真退出后整体换掉 Contents → 重新打开。
///
/// 和 TabFlick 不同的地方：
/// - 不是固定 sleep 2 秒：NetTick 退出前要写库，旧进程还在时打开新的，两个实例会往同一个库里重复记账。
/// - 整个 Contents 换掉，不按子目录逐个拷：脚本编译进已发出去的版本，写死目录清单以后新增内容会漏拷，
///   而且没法远程修（PasteMemo #38）。先拷到旁边再 mv，拷失败了旧版原样留着。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repo = "lifedever/NetTick"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    private static let autoKey = "autoCheckUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"
    private static let interval: TimeInterval = 24 * 3600

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var pendingVersion = ""

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoKey) }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var downloadCancelled = false
    private var progressWindow: NSWindow?
    private var timer: Timer?

    // MARK: 检查

    /// 每小时对一次账，距上次检查满一天才真的查；改开关、睡醒补查都自然覆盖
    func startPeriodicChecks() {
        // swift run 之类不是 .app 的环境没有可替换的包，也没有版本号
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard status != .checking, !isDownloading else { return }
        status = .checking
        Task {
            let result = await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            switch result {
            case .failure(let message):
                log("检查更新失败：\(message)")
                status = .failed(message)
                if userInitiated { presentFailure(message) }
            case .success(let latest):
                guard Self.isNewer(latest.version, than: currentVersion) else {
                    status = .upToDate
                    if userInitiated { presentUpToDate() }
                    return
                }
                log("有新版本 \(latest.version)")
                status = .available(latest.version)
                // 自动检查尊重「跳过这一版」，手动检查总是弹
                if userInitiated || latest.version != UserDefaults.standard.string(forKey: Self.skippedKey) {
                    presentAvailable(latest)
                }
            }
        }
    }

    // MARK: 网络

    private struct Latest {
        let version: String
        /// 当前架构的 DMG；这一版漏传了就是 nil，退回发布页
        let assetURL: URL?
        let assetSize: Int64
    }

    private enum FetchResult {
        case success(Latest)
        case failure(String)
    }

    private func fetchLatest() async -> FetchResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 一个 release 都还没发时返回 404，不算错
            if code == 404 { return .success(Latest(version: "0.0.0", assetURL: nil, assetSize: 0)) }
            guard code == 200 else { return .failure("GitHub 返回 \(code)") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return .failure("发布信息读不出来") }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            // 资产名形如 NetTick-0.2.0-arm64.dmg
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            let asset = (json["assets"] as? [[String: Any]])?.first {
                let name = $0["name"] as? String ?? ""
                return name.contains(arch) && name.hasSuffix(".dmg")
            }
            return .success(Latest(version: version,
                                   assetURL: (asset?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                                   assetSize: (asset?["size"] as? NSNumber)?.int64Value ?? 0))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 逐段比数字：字符串比较会把 0.10.0 判成比 0.9.0 小
    nonisolated static func isNewer(_ remote: String, than current: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: 下载

    private func startDownload(_ latest: Latest) {
        guard let url = latest.assetURL, !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        downloadCancelled = false
        pendingVersion = latest.version
        showProgressWindow()

        let delegate = DownloadDelegate(
            expectedSize: latest.assetSize,
            onProgress: { [weak self] p in Task { @MainActor in self?.downloadProgress = p } },
            onFinish: { [weak self] r in Task { @MainActor in self?.downloadFinished(r, version: latest.version) } }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadSession = session
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadCancelled = true
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        closeProgressWindow()
    }

    private func downloadFinished(_ result: DownloadResult, version: String) {
        isDownloading = false
        downloadTask = nil
        // URLSession 强引用着 delegate，不 invalidate 两个都不会释放
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        closeProgressWindow()
        switch result {
        case .success(let file):
            install(from: file, version: version)
        case .failure(let message):
            guard !downloadCancelled else { return }
            log("下载更新失败：\(message)")
            presentInstallFailure(message)
        }
    }

    // MARK: 安装

    /// 开发用：`--debug-update <dmg 路径> <版本号>` 跳过检查和下载，直接走安装（本机验证替换、重启）
    func debugInstall(dmg: String, version: String) {
        install(from: URL(fileURLWithPath: dmg), version: version)
    }

    private func install(from dmg: URL, version: String) {
        let destApp = Bundle.main.bundlePath
        guard destApp.hasSuffix(".app") else { NSWorkspace.shared.open(dmg); return }
        // 脚本要在 App 里换掉 Contents：没写权限的话退出了才发现换不了，先在这儿拦下
        guard FileManager.default.isWritableFile(atPath: destApp),
              FileManager.default.isWritableFile(atPath: destApp + "/Contents") else {
            presentInstallFailure("没有权限替换 \(destApp)")
            return
        }
        guard let mountPoint = Self.mountDMG(dmg.path) else {
            presentInstallFailure("更新包打不开")
            return
        }
        let sourceApp = mountPoint + "/NetTick.app"
        if let problem = Self.checkPackage(sourceApp, version: version) {
            Self.detachDMG(mountPoint)
            log("更新包没通过核对：\(problem)")
            presentInstallFailure(problem)
            return
        }

        let scriptPath = NSTemporaryDirectory() + "nettick_update.sh"
        do {
            try Self.installerScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            // 路径走参数，不拼进脚本：挂载点带空格（/Volumes/NetTick 0.2.0）
            p.arguments = [scriptPath, String(ProcessInfo.processInfo.processIdentifier), sourceApp, destApp, mountPoint,
                           Self.updateLogPath, dmg.path]
            try p.run()
            log("更新脚本已启动，退出后替换为 \(version)")
            NSApp.terminate(nil)
        } catch {
            Self.detachDMG(mountPoint)
            presentInstallFailure(error.localizedDescription)
        }
    }

    private static var updateLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NetTick/update.log").path
    }

    /// 参数：旧进程 pid、新 App、要替换的 App、挂载点、日志文件、下载的 DMG
    static let installerScript = """
    #!/bin/bash
    PID="$1"; SRC="$2"; DEST="$3"; MOUNT="$4"; LOG="$5"; DMG="$6"
    exec >>"$LOG" 2>&1
    # 先用 diskutil，老系统退回 hdiutil（macOS 27 上 hdiutil detach 已弃用，见 DiskImage）
    unmount_dmg() { diskutil eject "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -quiet 2>/dev/null; }
    echo "$(date '+%F %T') 更新开始：$SRC → $DEST"
    # 等旧进程退出（它要先写库），最多 30 秒；还没退就放弃，不替换正在运行的包
    for _ in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$PID" 2>/dev/null; then
        echo "旧进程 $PID 30 秒没退出，放弃更新"
        unmount_dmg; rm -f "$0"; exit 1
    fi
    rm -rf "$DEST/Contents.new" "$DEST/Contents.old"
    if ditto "$SRC/Contents" "$DEST/Contents.new"; then
        mv "$DEST/Contents" "$DEST/Contents.old" && mv "$DEST/Contents.new" "$DEST/Contents" && rm -rf "$DEST/Contents.old"
        if [ ! -d "$DEST/Contents" ] && [ -d "$DEST/Contents.old" ]; then
            echo "替换失败，还原旧版"; mv "$DEST/Contents.old" "$DEST/Contents"
        fi
    else
        echo "拷贝新版失败，旧版不动"; rm -rf "$DEST/Contents.new"
    fi
    unmount_dmg
    rm -f "$DMG"
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
    echo "$(date '+%F %T') 重新打开"
    open "$DEST"
    rm -f "$0"
    """

    /// 核对挂载出来的包：有 App、bundle id 一样、版本号是要装的那版、和当前这一版同一张证书签的。
    /// 签名换了（比如在没装证书的机器上打的 ad-hoc 包），通知、登录项都会把它当成另一个 App
    private static func checkPackage(_ app: String, version: String) -> String? {
        guard let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") else { return "更新包里没有 NetTick.app" }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { return "更新包不是 NetTick" }
        guard info["CFBundleShortVersionString"] as? String == version else {
            return "更新包的版本号是 \(info["CFBundleShortVersionString"] as? String ?? "空的")，不是 \(version)"
        }
        guard sameSigner(app) else { return "更新包的签名和当前版本不一样" }
        return nil
    }

    private static func sameSigner(_ app: String) -> Bool {
        var me: SecCode?, meStatic: SecStaticCode?, req: SecRequirement?, other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic else { return false }
        // 自己是 ad-hoc 签的（本机没证书时打的包）：指定要求是 cdhash，任何新包都对不上，只能不核对
        var signing: CFDictionary?
        if SecCodeCopySigningInformation(meStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
           (signing as? [String: Any])?[kSecCodeInfoCertificates as String] == nil {
            return true
        }
        guard SecCodeCopyDesignatedRequirement(meStatic, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: app) as CFURL, [], &other) == errSecSuccess, let other
        else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), req) == errSecSuccess
    }

    private static func mountDMG(_ path: String) -> String? { DiskImage.attach(path) }

    private static func detachDMG(_ mountPoint: String) { DiskImage.detach(mountPoint) }

    // MARK: 进度窗口

    private func showProgressWindow() {
        if progressWindow == nil {
            let host = NSHostingController(rootView: DownloadProgressView(updates: self))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled]   // 不给关闭按钮，取消走窗口里的按钮
            w.title = "软件更新"
            w.isReleasedWhenClosed = false
            // 先布局定尺寸再居中，反过来会按近零尺寸居中（PasteMemo #66）
            host.view.layoutSubtreeIfNeeded()
            w.setContentSize(host.view.fittingSize)
            w.center()
            progressWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        progressWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeProgressWindow() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
    }

    // MARK: 弹窗

    /// 弹窗不能在主队列的 block / MainActor 任务里直接 runModal：主队列不可重入，弹窗开着的时候主线程上别的派发全排着，
    /// 菜单栏速率停住、SIGTERM 写库退不了（2026-11-25 实测：每天自动检查弹出来没人点，就一直这样）。
    /// 交给 RunLoop 执行就不占着主队列；只排在 default 模式，前一个弹窗开着时后一个等它关了再出来
    private func runAlert(_ alert: NSAlert, then handle: @escaping @MainActor (NSApplication.ModalResponse) -> Void = { _ in }) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                handle(alert.runModal())
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func presentAvailable(_ latest: Latest) {
        let alert = NSAlert()
        alert.messageText = "有新版本 \(latest.version)"
        if latest.assetURL != nil {
            alert.informativeText = "当前版本 \(currentVersion)，装完自动重启。"
            alert.addButton(withTitle: "下载并安装")
            alert.addButton(withTitle: "稍后")
            alert.addButton(withTitle: "跳过这一版")
            runAlert(alert) { [weak self] r in
                switch r {
                case .alertFirstButtonReturn: self?.startDownload(latest)
                case .alertThirdButtonReturn: UserDefaults.standard.set(latest.version, forKey: Self.skippedKey)
                default: break
                }
            }
        } else {
            alert.informativeText = "当前版本 \(currentVersion)。这一版没有适合这台 Mac 的安装包，去发布页手动下载。"
            alert.addButton(withTitle: "打开发布页")
            alert.addButton(withTitle: "稍后")
            runAlert(alert) { r in
                if r == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesPage) }
            }
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前版本 \(currentVersion)。"
        alert.addButton(withTitle: "好")
        runAlert(alert)
    }

    private func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检查更新失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        runAlert(alert)
    }

    private func presentInstallFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "自动更新失败"
        let end = message.last.map { "。.!！".contains($0) } ?? true
        alert.informativeText = message + (end ? "" : "。") + "\n\n可以去发布页手动下载。"
        alert.addButton(withTitle: "打开发布页")
        alert.addButton(withTitle: "稍后")
        runAlert(alert) { r in
            if r == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesPage) }
        }
    }
}

// MARK: - 下载进度

private struct DownloadProgressView: View {
    @ObservedObject var updates: UpdateChecker
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("正在下载 NetTick \(updates.pendingVersion)…")
                .font(.system(size: 13, weight: .medium))
            ProgressView(value: updates.downloadProgress).frame(width: 280)
            HStack {
                Text("\(Int(updates.downloadProgress * 100))%")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("取消") { updates.cancelDownload() }
            }
            .frame(width: 280)
        }
        .padding(20)
    }
}

private enum DownloadResult {
    case success(URL)
    case failure(String)
}

/// URLSession 的回调不在主线程，单独一个类接住，回主线程只传数据
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let expectedSize: Int64
    private let onProgress: (Double) -> Void
    private let onFinish: (DownloadResult) -> Void
    /// 成功路径回调过了，didCompleteWithError 的 nil 不再回调
    private var finished = false

    init(expectedSize: Int64, onProgress: @escaping (Double) -> Void, onFinish: @escaping (DownloadResult) -> Void) {
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        finished = true
        // HTTP 错误（404 之类）也会走到这里，下下来的是错误页
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 {
            onFinish(.failure("下载地址返回 \(code)"))
            return
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("NetTick-update.dmg")
        try? FileManager.default.removeItem(at: dest)
        // location 是系统临时文件，回调一返回就被删，要先挪走
        do { try FileManager.default.moveItem(at: location, to: dest) } catch {
            onFinish(.failure(error.localizedDescription))
            return
        }
        // 核对字节数：截断的包不能进安装
        if expectedSize > 0,
           let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64,
           size != expectedSize {
            try? FileManager.default.removeItem(at: dest)
            onFinish(.failure("下载不完整（\(size) / \(expectedSize) 字节）"))
            return
        }
        onFinish(.success(dest))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(expectedSize, 1)
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, !finished else { return }
        finished = true
        onFinish(.failure(error.localizedDescription))
    }
}
