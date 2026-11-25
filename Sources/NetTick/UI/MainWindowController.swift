import AppKit
import SwiftUI

enum MainPage: String, CaseIterable, Identifiable {
    case rank, curve, month
    // 设置拆成五页放侧栏
    case general, menuBar = "menubar", notifications = "notify", data, about

    static let statsPages: [MainPage] = [.rank, .curve, .month]
    static let settingsPages: [MainPage] = [.general, .menuBar, .notifications, .data, .about]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .rank: return "流量排行"
        case .curve: return "速率曲线"
        case .month: return "月报"
        case .general: return "通用"
        case .menuBar: return "菜单栏"
        case .notifications: return "通知"
        case .data: return "数据"
        case .about: return "关于"
        }
    }
    var symbol: String {
        switch self {
        case .rank: return "list.bullet"
        case .curve: return "chart.xyaxis.line"
        case .month: return "calendar"
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .notifications: return "bell.badge"
        case .data: return "externaldrive"
        case .about: return "info.circle"
        }
    }

    /// 开发参数 `--debug-open` 里的名字；`settings` 指通用页
    init?(arg: String) {
        if arg == "settings" { self = .general } else { self.init(rawValue: arg) }
    }
}

@MainActor
final class MainNav: ObservableObject {
    @Published var page: MainPage = .rank
}

/// 主窗口。打开时切成 .regular（有 Dock 图标、能 ⌘Tab），关掉切回 .accessory。
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let nav = MainNav()

    init(recorder: Recorder, collector: Collector) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: MainView.defaultSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "NetTick"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = MainView(nav: nav, data: MainData(recorder: recorder))
        let host = NSHostingController(rootView: root)
        // 窗口最小尺寸跟着 SwiftUI 声明的最小尺寸走（MainView 的 minWidth / minHeight）。
        // 只设 window.minSize 拦不住：用户照样能缩到比内容窄，内容就左右两边一起溢出
        host.sizingOptions = [.minSize]
        // 让 SwiftUI 的 .toolbar / .navigationTitle 落到这个 NSWindow 的原生工具栏上（macOS 14+）
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.setContentSize(MainView.defaultSize)
        window.center()
        window.setFrameAutosaveName("NetTickMain")
        // 存下来的旧尺寸可能比现在的最小尺寸还小（老版本没拦住）：撑到最小尺寸
        let minFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: MainView.minSize))
        if window.frame.width < minFrame.width || window.frame.height < minFrame.height {
            var f = window.frame
            f.size.width = max(f.width, minFrame.width)
            f.size.height = max(f.height, minFrame.height)
            window.setFrame(f, display: false)
        }
    }

    /// 开发用：`--debug-size 宽x高` 把窗口内容区设成指定大小，截图核对各种尺寸下的排版
    func applyDebugSize() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--debug-size"), i + 1 < args.count else { return }
        let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        // 调试尺寸别存进「上次的大小」：不然截一轮图，下次正常打开就是这个尺寸
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
        log("调试尺寸：请求 \(args[i + 1])，实际内容区 \(NSStringFromSize(window.contentLayoutRect.size))")
    }

    func show(page: MainPage) {
        nav.page = page
        NSApp.setActivationPolicy(.regular)
        applyDebugSize()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window.isVisible }

    func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
