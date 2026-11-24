import AppKit
import SwiftUI

/// 图表色板（dataviz 校验过：下载 / 上传 / 走代理三色两两可分；走代理的青绿在浅色上对比度 2.74，出现时一律配文字）
enum Theme {
    static let download = dynamic(light: 0x2a78d6, dark: 0x3987e5)
    static let upload = dynamic(light: 0xeb6834, dark: 0xd95926)
    static let proxy = dynamic(light: 0x1baf7a, dark: 0x199e70)
    static let direct = dynamic(light: 0xe1e0d9, dark: 0x3a3a38)
    static let grid = dynamic(light: 0xecebe6, dark: 0x2e2e2c)
    static let tile = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.035)
    })

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

/// 小圆点图例
struct Dot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// 分段条：按值的比例分成几段，段间 2pt 空隙，两端圆角
struct SegmentBar: View {
    struct Part { var value: Double; var color: Color }
    var parts: [Part]
    /// 非 nil 时按「和 maxValue 的比例」画长度，剩下的留空（排行里比的是和第一名的差距）
    var maxValue: Double? = nil
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let total = parts.reduce(0) { $0 + $1.value }
            let scale = maxValue.map { $0 > 0 ? total / $0 : 0 } ?? 1
            let visible = parts.filter { $0.value > 0 }
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            let usable = max(0, geo.size.width * scale - gaps)
            HStack(spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, p in
                    Capsule().fill(p.color)
                        .frame(width: total > 0 ? max(2, usable * p.value / total) : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
    }
}
