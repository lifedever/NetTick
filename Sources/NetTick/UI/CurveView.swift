import Charts
import Combine
import SwiftUI

/// 速率曲线的数据。和窗口同寿命。
/// 最近 1 小时：10 秒一格（内存里），App 重启后前面缺的那段用库里每分钟的数补；24 小时：1 分钟一格（库里）。
@MainActor
final class CurveModel: ObservableObject {
    enum Range: String, CaseIterable { case hour = "1 小时", day = "24 小时" }

    struct Point: Identifiable {
        var t: Date
        var rx: Double   // 字节/秒
        var tx: Double
        var span: TimeInterval = 10   // 这一格多长：内存里的 10 秒格，或库里的 1 分钟格
        var id: Date { t }
    }

    @Published var range: Range = .hour { didSet { if range != oldValue { load(keepSelection: false) } } }
    @Published private(set) var points: [Point] = []
    @Published var selected: Date? { didSet { if selected != oldValue { loadDrill() } } }
    @Published private(set) var drill: [(identity: AppIdentity, rx: Double, tx: Double)] = []
    private(set) var loaded = false

    private unowned let data: MainData
    init(data: MainData) { self.data = data }

    func point(at t: Date?) -> Point? {
        guard let t else { return nil }
        return points.first { $0.t == t }
    }

    func load(keepSelection: Bool) {
        let r = range
        if r == .hour {
            data.buckets { [weak self] buckets in
                guard let self, self.range == r else { return }
                let fine = buckets.map { Point(t: Date(timeIntervalSince1970: TimeInterval($0.start)),
                                               rx: Double($0.iface.rx) / 10, tx: Double($0.iface.tx) / 10) }
                let now = Int(Date().timeIntervalSince1970)
                let fineStart = buckets.first?.start ?? now
                let from = (now - 3600) / 60 * 60
                guard fineStart - from >= 60 else { self.apply(fine, keepSelection); return }
                self.data.query({ db in db.minuteSeries(from: from, to: fineStart / 60 * 60) }) { [weak self] series in
                    guard let self, self.range == r else { return }
                    let coarse = series.keys.sorted().map { ts -> Point in
                        let b = series[ts]!
                        return Point(t: Date(timeIntervalSince1970: TimeInterval(ts)), rx: Double(b.rx) / 60, tx: Double(b.tx) / 60, span: 60)
                    }
                    self.apply(coarse + fine, keepSelection)
                }
            }
        } else {
            let now = Int(Date().timeIntervalSince1970) / 60 * 60
            let from = now - 24 * 3600
            data.query({ db in db.minuteSeries(from: from, to: now + 60) }) { [weak self] series in
                guard let self, self.range == r else { return }
                let pts = stride(from: from, through: now, by: 60).map { ts -> Point in
                    let b = series[ts] ?? Bytes()
                    return Point(t: Date(timeIntervalSince1970: TimeInterval(ts)), rx: Double(b.rx) / 60, tx: Double(b.tx) / 60, span: 60)
                }
                self.apply(pts, keepSelection)
            }
        }
    }

    private func apply(_ pts: [Point], _ keepSelection: Bool) {
        loaded = true
        points = pts
        if keepSelection, let s = selected, pts.contains(where: { $0.t == s }) {
            loadDrill()
            return
        }
        // 默认选最高的那一格
        selected = pts.max { $0.rx + $0.tx < $1.rx + $1.tx }?.t
        loadDrill()
    }

    func loadDrill() {
        guard let p = point(at: selected) else { drill = []; return }
        let start = Int(p.t.timeIntervalSince1970)
        let span = p.span
        if span < 60 {
            data.buckets { [weak self] buckets in
                guard let self, self.selected == p.t else { return }
                guard let b = buckets.first(where: { $0.start == start }) else { self.drill = []; return }
                self.drill = self.data.resolve(b.apps).map { ($0.0, Double($0.1.rx) / span, Double($0.1.tx) / span) }
            }
        } else {
            data.query({ db in db.appsBetween(from: start, to: start + Int(span)) }) { [weak self] rows in
                guard let self else { return }
                self.data.buckets { [weak self] _ in   // 顺手刷新名字表
                    guard let self, self.selected == p.t else { return }
                    self.drill = self.data.resolve(Dictionary(rows.map { ($0.key, $0.bytes) }, uniquingKeysWith: { a, _ in a }))
                        .map { ($0.0, Double($0.1.rx) / span, Double($0.1.tx) / span) }
                }
            }
        }
    }
}

/// 点曲线上任意一处，下面列出那一格里在用网的 App。
struct CurveView: View {
    @ObservedObject var model: CurveModel
    @State private var hover: Date?
    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            chartCard
            drillCard
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("范围", selection: $model.range) {
                    ForEach(CurveModel.Range.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .onAppear { model.load(keepSelection: true) }
        .onReceive(refresh) { _ in model.load(keepSelection: true) }
        .onChange(of: model.points.count) { _, _ in
            // 开发用：`--debug-hover` 把悬停固定在最右一格，截图核对提示框会不会出界
            if CommandLine.arguments.contains("--debug-hover") { hover = model.points.last?.t }
        }
    }

    // MARK: 曲线

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Legend(color: Theme.download, text: "下载")
                Legend(color: Theme.upload, text: "上传")
                Spacer()
                Text("点曲线看那一刻是谁在用网").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            if model.points.isEmpty {
                Text(model.loaded ? "还没有数据" : "").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            } else {
                // 跟着窗口高度长：窗口拉高时下面不留一大块白
                chart.frame(minHeight: 260, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var chart: some View {
        let points = model.points
        let sel = model.point(at: model.selected)
        let hov = model.point(at: hover)
        return Chart {
            ForEach(points) { p in
                AreaMark(x: .value("时间", p.t), y: .value("速率", p.rx), series: .value("方向", "下载"))
                    .foregroundStyle(Theme.download.opacity(0.1))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("时间", p.t), y: .value("速率", p.rx), series: .value("方向", "下载"))
                    .foregroundStyle(Theme.download)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("时间", p.t), y: .value("速率", p.tx), series: .value("方向", "上传"))
                    .foregroundStyle(Theme.upload.opacity(0.1))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("时间", p.t), y: .value("速率", p.tx), series: .value("方向", "上传"))
                    .foregroundStyle(Theme.upload)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let sel {
                RuleMark(x: .value("时间", sel.t)).foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("时间", sel.t), y: .value("速率", sel.rx)).foregroundStyle(Theme.download).symbolSize(50)
                PointMark(x: .value("时间", sel.t), y: .value("速率", sel.tx)).foregroundStyle(Theme.upload).symbolSize(50)
            }
            if let hov, hov.t != sel?.t {
                // 提示框放在竖线旁边、贴着图表顶，横竖都限制在图表里（靠右边时往左挪）。
                // 放在竖线正上方会冒出图表、被窗口裁掉
                RuleMark(x: .value("时间", hov.t)).foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .trailing, alignment: .top, spacing: 8,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(hov)
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Theme.grid)
                AxisValueLabel { if let d = v.as(Double.self) { Text(d == 0 ? "0" : Fmt.rate(d)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc): hover = nearest(proxy, geo, loc)
                        case .ended: hover = nil
                        }
                    }
                    .onTapGesture { loc in
                        if let t = nearest(proxy, geo, loc) { model.selected = t }
                    }
            }
        }
    }

    private func tooltip(_ p: CurveModel.Point) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(timeLabel(p.t, p.span)).font(.system(size: 12, weight: .semibold))
            Legend(color: Theme.download, text: "↓ \(Fmt.rate(p.rx))")
            Legend(color: Theme.upload, text: "↑ \(Fmt.rate(p.tx))")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial).shadow(radius: 4, y: 2))
    }

    private func nearest(_ proxy: ChartProxy, _ geo: GeometryProxy, _ loc: CGPoint) -> Date? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = loc.x - geo[plot].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return model.points.min { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }?.t
    }

    // MARK: 那一刻的 App

    private var drillCard: some View {
        let sel = model.point(at: model.selected)
        return VStack(alignment: .leading, spacing: 6) {
            if let sel {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(timeLabel(sel.t, sel.span)) – \(timeLabel(sel.t.addingTimeInterval(sel.span), sel.span))")
                        .font(.system(size: 12, weight: .semibold))
                    Text("↓ \(Fmt.rate(sel.rx))　↑ \(Fmt.rate(sel.tx))").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if model.drill.isEmpty {
                    Text("这一刻没有 App 在用网").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 28)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], alignment: .leading, spacing: 0) {
                        ForEach(model.drill.prefix(8), id: \.identity.key) { r in
                            HStack(spacing: 8) {
                                AppIconView(identity: r.identity)
                                Text(r.identity.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(r.rx >= 1 ? "↓ \(Fmt.rate(r.rx))" : "—").monospacedDigit().frame(width: 96, alignment: .trailing)
                                Text(r.tx >= 1 ? "↑ \(Fmt.rate(r.tx))" : "—").monospacedDigit().frame(width: 96, alignment: .trailing)
                            }
                            .font(.system(size: 13))
                            .frame(height: 28)
                        }
                    }
                }
            } else {
                Text("点上面的曲线，这里列出那一刻在用网的 App").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 28)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.tile))
    }

    private func timeLabel(_ d: Date, _ span: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = span < 60 ? "HH:mm:ss" : "HH:mm"
        return f.string(from: d)
    }
}
