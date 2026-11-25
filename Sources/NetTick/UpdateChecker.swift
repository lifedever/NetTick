import AppKit
import Security
import SwiftUI
import UserNotifications

/// 从 GitHub Releases 检查并自动安装新版本（照 TabFlick 的更新器）：
/// 找当前架构的 DMG → 下载并核对字节数 → 挂载 → 核对包里的 App（bundle id、版本号、同一张证书签的）
/// → 退出 → 外部脚本等旧进程真退出后整体换掉 Contents → 重新打开。
///
/// 怎么提醒：自动检查（每天一次）发现新版本只发系统通知，同一版只发一次；点通知打开「关于」页，
/// 那里的「更新到 x.y.z」才弹更新窗口（UpdateDialog：写着更新内容，立即更新，装完自动重启）。
/// 手动检查（关于页按钮、App 菜单）有新版本直接弹更新窗口，没有就在关于页上写状态。
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
    /// 更新通知的 identifier 前缀：点通知时靠它认出是更新通知
    static let notificationPrefix = "update-"

    private static let autoKey = "autoCheckUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let notifiedKey = "notifiedUpdateVersion"
    private static let interval: TimeInterval = 24 * 3600

    struct Release: Equatable {
        let version: String
        /// GitHub Release 的说明（Markdown）
        let notes: String
        /// 当前架构的 DMG；这一版漏传了就是 nil，只能去发布页手动下载
        let assetURL: URL?
        let assetSize: Int64
    }

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// 关于页上的更新窗口（sheet）开没开
    @Published var showDialog = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    /// 下载或安装失败的原因，显示在更新窗口里
    @Published private(set) var installError: String?

    var availableRelease: Release? {
        if case .available(let r) = status { return r }
        return nil
    }

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

    /// userInitiated：关于页的按钮、App 菜单。有新版本直接弹更新窗口；自动检查只发通知
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
            case .success(let release):
                guard Self.isNewer(release.version, than: currentVersion) else {
                    status = .upToDate
                    return
                }
                log("有新版本 \(release.version)")
                status = .available(release)
                if userInitiated {
                    installError = nil
                    showDialog = true
                } else {
                    notify(release)
                }
            }
        }
    }

    // MARK: 通知

    /// 同一版只通知一次：点开以后关于页一直挂着「更新到 x.y.z」，不用天天提醒
    private func notify(_ release: Release) {
        guard UserDefaults.standard.string(forKey: Self.notifiedKey) != release.version else { return }
        let title = "有新版本 \(release.version)"
        let body = "当前版本 \(currentVersion)，点开看这一版改了什么。"
        let id = Self.notificationPrefix + release.version, version = release.version, key = Self.notifiedKey
        // 关掉了「新程序联网通知」的话之前没要过授权，这里要一次（系统只弹一次）。闭包里只带字符串，现场建请求
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { log("更新通知没发：没有通知权限"); return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                if let error {
                    log("更新通知发送失败：\(error.localizedDescription)")
                } else {
                    UserDefaults.standard.set(version, forKey: key)
                    log("已发更新通知：\(version)")
                }
            }
        }
    }

    // MARK: 网络

    private enum FetchResult {
        case success(Release)
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
            if code == 404 { return .success(Release(version: "0.0.0", notes: "", assetURL: nil, assetSize: 0)) }
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
            return .success(Release(version: version,
                                    notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
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

    /// 更新窗口里的「立即更新」
    func installNow() {
        guard let release = availableRelease, release.assetURL != nil, !isDownloading else { return }
        installError = nil
        startDownload(release)
    }

    private func startDownload(_ release: Release) {
        guard let url = release.assetURL else { return }
        isDownloading = true
        downloadProgress = 0
        downloadCancelled = false
        let delegate = DownloadDelegate(
            expectedSize: release.assetSize,
            onProgress: { [weak self] p in Task { @MainActor in self?.downloadProgress = p } },
            onFinish: { [weak self] r in Task { @MainActor in self?.downloadFinished(r, version: release.version) } }
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
    }

    private func downloadFinished(_ result: DownloadResult, version: String) {
        isDownloading = false
        downloadTask = nil
        // URLSession 强引用着 delegate，不 invalidate 两个都不会释放
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        switch result {
        case .success(let file):
            install(from: file, version: version)
        case .failure(let message):
            guard !downloadCancelled else { return }
            fail("下载失败：\(message)")
        }
    }

    private func fail(_ message: String) {
        log("更新失败：\(message)")
        installError = message
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
            fail("没有权限替换 \(destApp)")
            return
        }
        guard let mountPoint = Self.mountDMG(dmg.path) else {
            fail("更新包打不开")
            return
        }
        let sourceApp = mountPoint + "/NetTick.app"
        if let problem = Self.checkPackage(sourceApp, version: version) {
            Self.detachDMG(mountPoint)
            log("更新包没通过核对：\(problem)")
            fail(problem)
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
            // 窗口上挂着更新窗口（sheet）时 NSApp.terminate 不生效，AppKit 直接拒绝退出（2026-11-25 实测：
            // 脚本等满 30 秒放弃）。先收起更新窗口再退；万一还没退，走 SIGTERM（同样先写库再退出）
            showDialog = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                log("退出没生效，改发 SIGTERM")
                kill(getpid(), SIGTERM)
            }
        } catch {
            Self.detachDMG(mountPoint)
            fail(error.localizedDescription)
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
}

// MARK: - 更新窗口

/// 关于页上弹出的更新窗口：版本、更新内容、立即更新。下载进度和失败原因都在这里；装好后 App 自己退出重开
struct UpdateDialog: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let r = updates.availableRelease {
                header(r)
                notes(r)
                footer(r)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(updates.isDownloading)
    }

    private func header(_ r: UpdateChecker.Release) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("NetTick \(r.version)").font(.system(size: 17, weight: .semibold))
                Text("当前版本 \(updates.currentVersion)，更新完自动重启。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func notes(_ r: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("更新内容").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if r.notes.isEmpty {
                        Text("这一版没写更新说明。").foregroundStyle(.secondary)
                    }
                    ForEach(Array(Self.noteLines(r.notes).enumerated()), id: \.offset) { _, line in
                        switch line {
                        case .blank:
                            Spacer().frame(height: 3)
                        case .bullet(let text):
                            // 圆点单独一列：折行时第二行和文字对齐，不顶到最左边
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(text)
                            }
                        case .heading(let text):
                            Text(text).fontWeight(.semibold)
                        case .text(let text):
                            Text(text)
                        }
                    }
                }
                .font(.system(size: 13))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(12)
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tile))
        }
    }

    @ViewBuilder private func footer(_ r: UpdateChecker.Release) -> some View {
        if updates.isDownloading {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: updates.downloadProgress)
                HStack {
                    Text("正在下载 \(Int(updates.downloadProgress * 100))%")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("取消") { updates.cancelDownload() }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let error = updates.installError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if r.assetURL == nil {
                    Text("这一版没有适合这台 Mac 的安装包，去发布页手动下载。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    if updates.installError != nil || r.assetURL == nil {
                        Button("打开发布页") { NSWorkspace.shared.open(UpdateChecker.releasesPage) }
                    }
                    Spacer()
                    Button("稍后") { updates.showDialog = false }
                        .keyboardShortcut(.cancelAction)
                    if r.assetURL != nil {
                        Button(updates.installError == nil ? "立即更新" : "重试") { updates.installNow() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    enum NoteLine {
        case blank, bullet(AttributedString), heading(AttributedString), text(AttributedString)
    }

    /// Release 说明是 Markdown：按行拆成列表项、标题、普通段落；行内的粗体、链接、代码照常显示
    static func noteLines(_ markdown: String) -> [NoteLine] {
        func inline(_ s: String) -> AttributedString {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        }
        var lines = markdown.components(separatedBy: "\n").map { line -> NoteLine in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .blank }
            if t.hasPrefix("- ") || t.hasPrefix("* ") { return .bullet(inline(String(t.dropFirst(2)))) }
            if t.hasPrefix("#") { return .heading(inline(String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces))) }
            return .text(inline(t))
        }
        // 连着的空行只留一个，首尾的空行去掉
        lines = lines.enumerated().filter { i, l in
            if case .blank = l, i > 0, case .blank = lines[i - 1] { return false }
            return true
        }.map(\.element)
        while let f = lines.first, case .blank = f { lines.removeFirst() }
        while let l = lines.last, case .blank = l { lines.removeLast() }
        return lines
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
