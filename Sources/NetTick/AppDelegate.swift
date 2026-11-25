import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var collector: Collector!
    private var statusItem: StatusItemController!
    private let liveModel = LiveModel()
    private(set) var recorder: Recorder!
    private var mainWindow: MainWindowController?
    private let notificationRouter = NotificationRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("NetTick 启动 —— 二进制编译于 \(binaryBuildTime())")
        MainMenu.install()

        let db: Database
        do {
            db = try Database(url: Database.defaultURL())
        } catch {
            fatalAlert("数据库打不开", error.localizedDescription)
        }
        let engine = DispatchQueue(label: "com.lifedever.NetTick.engine", qos: .utility)
        let recorder = Recorder(db: db, engine: engine)
        self.recorder = recorder
        recorder.onNewApp = { id in
            DispatchQueue.main.async { NewAppNotifier.shared.notify(id) }
        }

        let collector = Collector(recorder: recorder)
        self.collector = collector

        let popover = PopoverView(model: liveModel,
                                  onOpenMain: { [weak self] in self?.openMain(.rank) },
                                  onOpenSettings: { [weak self] in self?.openMain(.general) },
                                  onQuit: { NSApp.terminate(nil) },
                                  onHeight: { [weak self] h in self?.statusItem?.setPopoverHeight(h) })
        statusItem = StatusItemController(live: liveModel, popoverContent: popover)
        statusItem.onVisibilityChange = { visible in collector.setFastPolling(visible) }

        collector.onLive = { [weak self] live in
            guard let self else { return }
            self.statusItem.update(up: live.tx, down: live.rx)
            self.liveModel.receive(live)
        }
        collector.start()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // 合盖前写一次库，睡着时被强退也丢不了多少
            MainActor.assumeIsolated { self?.flushSoon() }
        }
        // 点更新通知打开「关于」页；要在发任何通知之前设好
        notificationRouter.onOpenUpdate = { [weak self] in self?.openMain(.about) }
        UNUserNotificationCenter.current().delegate = notificationRouter
        NewAppNotifier.shared.prepare()
        UpdateChecker.shared.startPeriodicChecks()
        handleSigterm()
        debugOpen()
    }

    /// 开发用：`--debug-open rank|curve|month|general|menubar|notify|data|about|popover` 直接打开对应界面截图核对（settings = general）
    /// （菜单栏挤满时图标会被藏到刘海后面，点不到）
    private var debugWindow: NSWindow?
    private func debugOpen() {
        let args = CommandLine.arguments
        if args.contains("--debug-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let i = args.firstIndex(of: "--debug-update"), i + 2 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                UpdateChecker.shared.debugInstall(dmg: args[i + 1], version: args[i + 2])
            }
        }
        guard let i = args.firstIndex(of: "--debug-open"), i + 1 < args.count else { return }
        let what = args[i + 1]
        if let page = MainPage(arg: what) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.openMain(page) }
        } else if what == "popover" {
            liveModel.reveal()
            // 开发用：`--debug-tab today|sinceBoot|all` 指定面板下半部分停在哪个标签（截图核对，不用点）
            if let t = args.firstIndex(of: "--debug-tab"), t + 1 < args.count, let tab = TotalsTab(rawValue: args[t + 1]) {
                liveModel.totalsTab = tab
            }
            collector.setFastPolling(true)
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: PopoverMetrics.width, height: PopoverMetrics.initialHeight),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            let view = PopoverView(model: liveModel, onOpenMain: {}, onOpenSettings: {}, onQuit: {},
                                   onHeight: { [weak w] h in w?.setContentSize(NSSize(width: PopoverMetrics.width, height: ceil(h))) })
            let host = NSHostingController(rootView: view)
            host.sizingOptions = []
            w.contentViewController = host
            w.title = "面板预览"
            w.isReleasedWhenClosed = false
            NSApp.setActivationPolicy(.regular)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            debugWindow = w
        }
    }

    private func flushSoon() {
        let c = collector!, r = recorder!
        c.queue.async { r.flush() }
    }

    /// 菜单栏挤满时图标会被藏到刘海后面：再次打开 NetTick（聚焦搜索、启动台、双击）就直接开主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 主窗口已经开着就只拿到前面、不换页。点通知时系统也会发「再次打开」，而且晚于通知的点击回调：
        // 不这样的话，点更新通知刚打开的「关于」页马上被切回排行页（2026-11-25 实测）
        if let w = mainWindow, w.isVisible {
            log("再次打开：主窗口开着，只拿到前面")
            w.bringToFront()
        } else {
            log("再次打开：打开排行页")
            openMain(.rank)
        }
        return false
    }

    /// kill / 关机时进程收到 SIGTERM，不走 applicationWillTerminate：先写库再退
    private var sigterm: DispatchSourceSignal?
    private func handleSigterm() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in
            log("收到 SIGTERM，写库后退出")
            self?.collector?.shutdown()
            exit(0)
        }
        src.resume()
        sigterm = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        collector?.shutdown()
        log("NetTick 退出")
    }

    // MARK: App 菜单

    @objc func showSettings(_ sender: Any?) { openMain(.general) }
    @objc func showAbout(_ sender: Any?) { openMain(.about) }
    /// 结果显示在关于页：有新版本弹更新窗口，没有就在页上写状态
    @objc func checkForUpdates(_ sender: Any?) {
        openMain(.about)
        UpdateChecker.shared.check(userInitiated: true)
    }
    @objc func openSponsor(_ sender: Any?) { NSWorkspace.shared.open(AppLinks.sponsor) }

    func openMain(_ page: MainPage) {
        statusItem.closePopover()
        if mainWindow == nil {
            mainWindow = MainWindowController(recorder: recorder, collector: collector)
        }
        mainWindow?.show(page: page)
    }

    private func fatalAlert(_ title: String, _ message: String) -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "退出")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(1)
    }
}

/// 点系统通知：更新通知打开「关于」页（那里点「更新到 x.y.z」才弹更新窗口）；新程序联网通知只把 App 叫到前面
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    var onOpenUpdate: (() -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        DispatchQueue.main.async {
            log("点了通知：\(id)")
            if id.hasPrefix(UpdateChecker.notificationPrefix) { self.onOpenUpdate?() }
        }
        completionHandler()
    }

    /// 主窗口开着时 App 在前台，系统默认不显示通知，要显式放行
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
