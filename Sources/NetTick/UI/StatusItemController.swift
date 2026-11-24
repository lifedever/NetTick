import AppKit
import Combine
import SwiftUI

/// 菜单栏：上下两行速率（上传在上、下载在下），点开是面板。
///
/// 三列对齐：箭头靠左、数字靠右、单位靠左（2026-11-24 用户指出整体右对齐时两行箭头错位）。
/// 宽度固定，数字跳动时不挤动旁边的图标。
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var renderer = RatesRenderer(showArrows: MenuBarStyle.showArrows)
    let live: LiveModel

    init(live: LiveModel, popoverContent: some View) {
        self.live = live
        super.init()
        statusItem.length = renderer.width + 8
        if let button = statusItem.button {
            button.image = renderer.image(up: 0, down: 0)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = live.pinned ? .applicationDefined : .transient
        // 固定 = applicationDefined：点别处、切到别的 App 都不收起，只有再点菜单栏图标才收
        pinObserver = live.$pinned.dropFirst().sink { [weak self] pinned in
            self?.popover.behavior = pinned ? .applicationDefined : .transient
        }
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: popoverContent)
        host.sizingOptions = []      // 尺寸固定，别让 SwiftUI 报的尺寸去改 popover（macOS 15/26 上不可信）
        popover.contentViewController = host
        popover.contentSize = NSSize(width: PopoverMetrics.width, height: PopoverMetrics.initialHeight)

        NotificationCenter.default.addObserver(forName: MenuBarStyle.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyStyle() }
        }

        // 菜单栏挤满时新图标会被藏到刘海后面，用户以为没启动：记一下图标落在哪
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let w = self?.statusItem.button?.window else { log("菜单栏图标：没有窗口"); return }
            let visible = w.occlusionState.contains(.visible)
            log("菜单栏图标：frame \(NSStringFromRect(w.frame))，屏幕 \(w.screen.map { NSStringFromRect($0.frame) } ?? "无")，可见 \(visible)")
        }
    }

    private var lastText = ""
    private var pinObserver: AnyCancellable?
    private var lastRates: (up: Double, down: Double) = (0, 0)

    /// 设置里改了「显示箭头」：换一个画法、改宽度、立刻重画
    private func applyStyle() {
        renderer = RatesRenderer(showArrows: MenuBarStyle.showArrows)
        statusItem.length = renderer.width + 8
        lastText = ""
        update(up: lastRates.up, down: lastRates.down)
    }

    /// 显示的字一样就不换图：每换一次图，系统要给菜单栏重拍一张快照（采样里主线程的大头）
    func update(up: Double, down: Double) {
        lastRates = (up, down)
        let text = Fmt.rate(up) + "|" + Fmt.rate(down)
        guard text != lastText else { return }
        lastText = text
        statusItem.button?.image = renderer.image(up: up, down: down)
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            live.reveal()
            onVisibilityChange?(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        live.isVisible = false
        onVisibilityChange?(false)
    }

    var onVisibilityChange: ((Bool) -> Void)?

    /// 面板高度跟着内容走（SwiftUI 量出来的高度经 PopoverHeightKey 报上来），夹在合理范围里
    func setPopoverHeight(_ h: CGFloat) {
        let height = min(max(ceil(h), 200), 720)
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: PopoverMetrics.width, height: height)
    }
}

/// 菜单栏速率的显示样式（设置页改，菜单栏跟着变）
enum MenuBarStyle {
    static let showArrowsKey = "menuBarShowArrows"
    static let changed = Notification.Name("NetTickMenuBarStyleChanged")

    static var showArrows: Bool {
        get { UserDefaults.standard.object(forKey: showArrowsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: showArrowsKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

enum PopoverMetrics {
    static let width: CGFloat = 340
    static let initialHeight: CGFloat = 480
}

/// 画菜单栏那张两行速率的模板图
@MainActor
final class RatesRenderer {

    private let font: NSFont
    private let showArrows: Bool
    private let arrowWidth: CGFloat
    private let numberWidth: CGFloat
    private let unitWidth: CGFloat
    private let gap1: CGFloat
    private let gap2: CGFloat = 2.5
    let width: CGFloat

    /// - Parameter showArrows: 设置里「显示箭头」；关掉时箭头那一列不占宽度
    init(showArrows: Bool) {
        self.showArrows = showArrows
        font = Self.makeFont()
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func w(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: attrs).width) }
        arrowWidth = showArrows ? max(w("↑"), w("↓")) : 0
        gap1 = showArrows ? 2 : 0
        numberWidth = ["999", "99.9", "9.99"].map(w).max() ?? 20
        unitWidth = ["B/s", "KB/s", "MB/s", "GB/s"].map(w).max() ?? 24
        width = arrowWidth + gap1 + numberWidth + gap2 + unitWidth
    }

    /// macOS 27 上 monospacedDigitSystemFont 偶尔真返回 nil（声明是非空，Swift 不检查），
    /// nil 进了文字属性就闪退（swift-rules #11）。建一次缓存住，拿到 nil 用系统字体顶。
    private static func makeFont() -> NSFont {
        let f = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        if unsafeBitCast(f, to: UnsafeRawPointer?.self) == nil {
            return NSFont.systemFont(ofSize: 9.5, weight: .medium)
        }
        return f
    }

    /// 每次更新先把字画进一张位图：系统给菜单栏拍快照（每个显示器各一份）时只是贴图，
    /// 不再每次重新排版文字（2026-11-24 采样：主线程的大头就是这些快照重绘）。
    func image(up: Double, down: Double) -> NSImage {
        let height = NSStatusBar.system.thickness
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let pw = Int((width * scale).rounded(.up)), ph = Int((height * scale).rounded(.up))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let lineH: CGFloat = 10.5
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let blockY = (height - lineH * 2) / 2 - 1
        func row(_ arrow: String, _ p: (number: String, unit: String), y: CGFloat) {
            if showArrows { (arrow as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: attrs) }
            let n = p.number as NSString
            let nWidth = n.size(withAttributes: attrs).width
            n.draw(at: NSPoint(x: arrowWidth + gap1 + numberWidth - nWidth, y: y), withAttributes: attrs)
            (p.unit + "/s" as NSString).draw(at: NSPoint(x: arrowWidth + gap1 + numberWidth + gap2, y: y), withAttributes: attrs)
        }
        row("↑", Fmt.parts(up), y: blockY + lineH)
        row("↓", Fmt.parts(down), y: blockY)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}
