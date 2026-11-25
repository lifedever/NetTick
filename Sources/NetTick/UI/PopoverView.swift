import SwiftUI

/// 面板用的实时数据。面板关着时不更新，省掉 SwiftUI 每秒的比对。
@MainActor
final class LiveModel: ObservableObject {
    @Published var live = Collector.Live()
    /// 关着时也记下最新一份（不触发界面），打开那一刻先填上：高度一出来就是对的，不会先矮后高
    var latest = Collector.Live()
    var isVisible = false
    /// 面板固定：点别处不收起（记住，下次打开还是固定的）
    @Published var pinned = UserDefaults.standard.bool(forKey: "popoverPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "popoverPinned") }
    }

    /// 「正在用网」的固定 3 行。关着时也跟着更新，打开那一刻就是最新的；
    /// 不用 @Published：开着时每秒 `live = l` 已经会触发重绘，关着时不该触发
    private(set) var slots = ActiveSlots()

    func receive(_ l: Collector.Live) {
        latest = l
        slots.update(l.active, now: Date())
        if isVisible { live = l }
    }

    func reveal() {
        live = latest
        isVisible = true
    }
}

/// 面板内容的实际高度（面板跟着它变高变矮，不留空白）
struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopoverView: View {
    @ObservedObject var model: LiveModel
    var onOpenMain: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    var onHeight: (CGFloat) -> Void = { _ in }

    private var live: Collector.Live { model.live }

    var body: some View {
        VStack(spacing: 0) {
            nowSection
            Divider()
            activeSection
            Divider()
            todaySection
            Divider()
            footer
        }
        .frame(width: PopoverMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: PopoverHeightKey.self, value: g.size.height) })
        .onPreferenceChange(PopoverHeightKey.self) { h in if h > 0 { onHeight(h) } }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 现在

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "现在", trailing: "最近 60 秒")
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    BigRate(arrow: "↑", value: live.tx, color: Theme.upload)
                    BigRate(arrow: "↓", value: live.rx, color: Theme.download)
                }
                Spacer(minLength: 12)
                Sparkline(history: live.history)
                    .frame(width: 120, height: 46)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: 正在用网

    /// 固定 3 行（见 ActiveSlots）：空着、灰着都占位，面板高度不跟着 App 多少跳
    private var activeSection: some View {
        let slots = model.slots
        let rows = slots.ordered
        let rowHeight: CGFloat = 28, rowSpacing: CGFloat = 2
        let listHeight = CGFloat(ActiveSlots.count) * rowHeight + CGFloat(ActiveSlots.count - 1) * rowSpacing
        return VStack(alignment: .leading, spacing: rowSpacing) {
            SectionLabel(title: "正在用网")
            Group {
                if !live.available {
                    Text("按 App 统计用不了：系统组件加载失败，只能看总速率。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(height: rowHeight)
                } else if slots.isEmpty {
                    Text("没有 App 在用网")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(height: rowHeight)
                } else {
                    VStack(spacing: rowSpacing) {
                        ForEach(0..<ActiveSlots.count, id: \.self) { i in
                            if let s = rows[i] {
                                ActiveRow(slot: s).frame(height: rowHeight)
                            } else {
                                Color.clear.frame(height: rowHeight)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: listHeight, maxHeight: listHeight, alignment: .topLeading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: 今天

    private var todaySection: some View {
        let rows = live.today
        let total = rows.reduce(Bytes()) { var b = $0; b += $1.1; return b }
        let top = Array(rows.prefix(5))
        let maxTotal = Double(top.first?.1.total ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: "今天")
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(Fmt.bytes(Double(total.total))).font(.system(size: 20, weight: .semibold))
                Legend(color: Theme.upload, text: "↑ \(Fmt.bytes(Double(total.tx)))")
                Legend(color: Theme.download, text: "↓ \(Fmt.bytes(Double(total.rx)))")
            }
            .padding(.bottom, 6)
            if top.isEmpty {
                Text("还没有数据").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 28)
            }
            ForEach(top, id: \.0.key) { id, b in
                HStack(spacing: 8) {
                    AppIconView(identity: id)
                    Text(id.name).lineLimit(1)
                    Spacer(minLength: 8)
                    SegmentBar(parts: [.init(value: Double(b.tx), color: Theme.upload),
                                       .init(value: Double(b.rx), color: Theme.download)],
                               maxValue: maxTotal, height: 5)
                        .frame(width: 64)
                    Text(Fmt.bytes(Double(b.total))).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 13))
                .frame(height: 28)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 8) {
            Button("打开主窗口", action: onOpenMain)
            Spacer()
            // 文字按钮，和「设置」「退出」一个样子（图标和文字混排不协调）
            Button(model.pinned ? "取消固定" : "固定") { model.pinned.toggle() }
                .buttonStyle(.borderless)
                .foregroundStyle(model.pinned ? Color.accentColor : Color.secondary)
                .help(model.pinned ? "点别处会收起" : "固定后点别处不收起")
            Button("设置", action: onOpenSettings).buttonStyle(.borderless).foregroundStyle(.secondary)
            Button("退出", action: onQuit).buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// 「正在用网」的一行。停了的变灰，速率照实显示
private struct ActiveRow: View {
    var slot: ActiveSlots.Slot
    var body: some View {
        let upMain = slot.tx > slot.rx
        HStack(spacing: 8) {
            AppIconView(identity: slot.identity)
                .opacity(slot.isActive ? 1 : 0.4)
            Text(slot.identity.name).lineLimit(1)
                .foregroundStyle(slot.isActive ? HierarchicalShapeStyle.primary : .secondary)
            Spacer(minLength: 8)
            Text(upMain ? "↑ \(Fmt.rate(slot.tx))" : "↓ \(Fmt.rate(slot.rx))").monospacedDigit()
                .foregroundStyle(slot.isActive ? HierarchicalShapeStyle.primary : .tertiary)
            Text(upMain ? "↓ \(Fmt.rate(slot.rx))" : "↑ \(Fmt.rate(slot.tx))").monospacedDigit()
                .foregroundStyle(slot.isActive ? HierarchicalShapeStyle.secondary : .tertiary)
        }
        .font(.system(size: 13))
    }
}

struct SectionLabel: View {
    var title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)) }
        }
        .foregroundStyle(.secondary)
    }
}

struct Legend: View {
    var color: Color
    var text: String
    var body: some View {
        HStack(spacing: 5) {
            Dot(color: color)
            Text(text).monospacedDigit()
        }
    }
}

private struct BigRate: View {
    var arrow: String
    var value: Double
    var color: Color
    var body: some View {
        HStack(spacing: 6) {
            Dot(color: color)
            Text("\(arrow) \(Fmt.rate(value))")
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// 60 秒迷你曲线：下载、上传两条线 + 淡底
private struct Sparkline: View {
    var history: [Bytes]
    var body: some View {
        Canvas { ctx, size in
            guard history.count > 1 else { return }
            let maxV = max(1, history.map { Double(max($0.rx, $0.tx)) }.max() ?? 1) * 1.1
            func path(_ value: (Bytes) -> UInt64, closed: Bool) -> Path {
                var p = Path()
                let n = 60
                let offset = n - history.count
                for (i, b) in history.enumerated() {
                    let x = CGFloat(i + offset) / CGFloat(n - 1) * size.width
                    let y = size.height - CGFloat(Double(value(b)) / maxV) * size.height
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
                if closed {
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.addLine(to: CGPoint(x: CGFloat(offset) / CGFloat(n - 1) * size.width, y: size.height))
                    p.closeSubpath()
                }
                return p
            }
            ctx.fill(path({ $0.rx }, closed: true), with: .color(Theme.download.opacity(0.12)))
            ctx.fill(path({ $0.tx }, closed: true), with: .color(Theme.upload.opacity(0.12)))
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            ctx.stroke(path({ $0.rx }, closed: false), with: .color(Theme.download), style: style)
            ctx.stroke(path({ $0.tx }, closed: false), with: .color(Theme.upload), style: style)
        }
        .accessibilityLabel("最近 60 秒的上传、下载速率")
    }
}
