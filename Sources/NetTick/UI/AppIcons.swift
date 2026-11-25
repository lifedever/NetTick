import AppKit
import SwiftUI

/// App 图标缓存。NSWorkspace.icon 不便宜，列表每次重绘都会取，按 key 缓存一次。
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for id: AppIdentity) -> NSImage {
        if let i = cache[id.key] { return i }
        let image: NSImage
        switch id.kind {
        case .other:
            image = id.key == AppIdentity.unrecordedKey ? unrecordedIcon() : otherIcon()
        case .system:
            image = NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app")
        case .cli:
            // 一律用「可执行文件」图标：按版本号命名的可执行文件（比如 2.1.331）会被当成 .331 文档
            image = NSWorkspace.shared.icon(forFile: "/bin/ls")
        case .app:
            if !id.path.isEmpty, FileManager.default.fileExists(atPath: id.path) {
                image = NSWorkspace.shared.icon(forFile: id.path)
            } else if let b = id.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                image = NSWorkspace.shared.icon(forFile: url.path)   // 路径失效了（App 挪了位置、iPad 应用的临时挂载）
            } else {
                image = NSWorkspace.shared.icon(forFile: "/bin/ls")
            }
        }
        image.size = NSSize(width: 32, height: 32)
        cache[id.key] = image
        return image
    }
}

/// 「其他」的图标：灰色圆角方块 + 三个点
@MainActor
private func otherIcon() -> NSImage {
    NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in
        let box = r.insetBy(dx: 2.5, dy: 2.5)
        NSColor(srgbRed: 0.6, green: 0.62, blue: 0.66, alpha: 1).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        NSColor.white.setFill()
        for i in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: 8.5 + CGFloat(i) * 6, y: 14, width: 4, height: 4)).fill()
        }
        return true
    }
}

struct AppIconView: View {
    var identity: AppIdentity
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: AppIcons.icon(for: identity))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// 「NetTick 没运行时」的图标：和「其他」同样的灰色方块，中间是休眠的 zzz
@MainActor
private func unrecordedIcon() -> NSImage {
    NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in
        let box = r.insetBy(dx: 2.5, dy: 2.5)
        NSColor(srgbRed: 0.6, green: 0.62, blue: 0.66, alpha: 1).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let z = NSImage(systemSymbolName: "zzz", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let s = z.size
            z.draw(in: NSRect(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2, width: s.width, height: s.height))
        }
        return true
    }
}
