import Charts
import SwiftUI

/// 月报的数据。和窗口同寿命。
@MainActor
final class MonthModel: ObservableObject {
    struct DayBar: Identifiable {
        var day: Int
        var dir: String     // 下载 / 上传
        var bytes: Double
        var id: String { "\(day)-\(dir)" }
    }

    @Published var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))! {
        didSet { if month != oldValue { load() } }
    }
    @Published private(set) var total = Bytes()
    @Published private(set) var lastSame = Bytes()
    @Published private(set) var bars: [DayBar] = []
    @Published private(set) var daysInMonth = 30
    @Published private(set) var top: [AppTotal] = []

    private unowned let data: MainData
    init(data: MainData) { self.data = data }

    var isCurrentMonth: Bool { Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month) }

    var title: String {
        let c = Calendar.current.dateComponents([.year, .month], from: month)
        return "\(c.year!) 年 \(c.month!) 月"
    }

    func shift(_ n: Int) {
        if let m = Calendar.current.date(byAdding: .month, value: n, to: month) { month = m }
    }

    func load() {
        let cal = Calendar.current
        let start = month, current = isCurrentMonth
        let days = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let from = Day.key(start)
        let to = Day.key(cal.date(byAdding: .day, value: days - 1, to: start)!)
        // 和上月比：当月看到今天为止，就比上月 1 号到同一天；往月比整个上月
        let lastStart = cal.date(byAdding: .month, value: -1, to: start)!
        let lastDays = cal.range(of: .day, in: .month, for: lastStart)?.count ?? 30
        let todayDay = cal.component(.day, from: Date())
        let lastTo = Day.key(cal.date(byAdding: .day, value: (current ? min(todayDay, lastDays) : lastDays) - 1, to: lastStart)!)
        let lastFrom = Day.key(lastStart)
        data.query({ db -> ([String: Bytes], [String: Bytes], [AppTotal]) in
            (db.dayTotals(from: from, to: to), db.dayTotals(from: lastFrom, to: lastTo), db.ranking(from: from, to: to))
        }) { [weak self] cur, last, ranking in
            guard let self, self.month == start else { return }
            self.daysInMonth = days
            self.total = cur.values.reduce(Bytes()) { var b = $0; b += $1; return b }
            self.lastSame = last.values.reduce(Bytes()) { var b = $0; b += $1; return b }
            self.bars = cur.flatMap { key, b -> [DayBar] in
                guard let d = Int(key.suffix(2)) else { return [] }
                return [DayBar(day: d, dir: "下载", bytes: Double(b.rx)), DayBar(day: d, dir: "上传", bytes: Double(b.tx))]
            }.sorted { ($0.day, $0.dir) < ($1.day, $1.dir) }
            self.top = ranking
        }
    }
}

/// 月报：本月合计、和上月同期比、每天的量、用得最多的 App
struct MonthView: View {
    @ObservedObject var model: MonthModel

    var body: some View {
        VStack(spacing: 14) {
            tiles
            chartCard
            topCard
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    Button { model.shift(-1) } label: { Label("上个月", systemImage: "chevron.left") }
                    Button { model.shift(1) } label: { Label("下个月", systemImage: "chevron.right") }
                        .disabled(model.isCurrentMonth)
                }
            }
        }
        .navigationSubtitle(model.title)
        .onAppear { model.load() }
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            StatTile(label: model.isCurrentMonth ? "本月合计" : "当月合计", value: Fmt.bytes(Double(model.total.total)), dot: nil,
                     detail: compareText, hero: true)
            StatTile(label: "下载", value: Fmt.bytes(Double(model.total.rx)), dot: Theme.download)
            StatTile(label: "上传", value: Fmt.bytes(Double(model.total.tx)), dot: Theme.upload)
        }
    }

    private var compareText: String {
        let current = model.isCurrentMonth
        guard model.lastSame.total > 0 else { return current ? "上月同期没有数据" : "上月没有数据" }
        let diff = (Double(model.total.total) - Double(model.lastSame.total)) / Double(model.lastSame.total)
        let what = current ? "上月同期" : "上月"
        return diff >= 0 ? "比\(what)多 \(Fmt.percent(diff))" : "比\(what)少 \(Fmt.percent(-diff))"
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text("每天").font(.system(size: 12, weight: .semibold))
                Legend(color: Theme.download, text: "下载")
                Legend(color: Theme.upload, text: "上传")
            }
            .font(.system(size: 12))
            Chart(model.bars) { b in
                BarMark(x: .value("日", b.day), y: .value("流量", b.bytes), width: .fixed(14))
                    .foregroundStyle(by: .value("方向", b.dir))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale(["下载": Theme.download, "上传": Theme.upload])
            .chartLegend(.hidden)
            .chartXScale(domain: 0...(model.daysInMonth + 1))
            .chartXAxis {
                AxisMarks(values: [1, 5, 10, 15, 20, 25, model.daysInMonth].filter { $0 <= model.daysInMonth }) { v in
                    AxisValueLabel { if let d = v.as(Int.self) { Text("\(d)日") } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(d == 0 ? "0" : Fmt.bytes(d)) } }
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)   // 跟着窗口高度长
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var topCard: some View {
        let maxV = Double(model.top.first?.bytes.total ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            Text("用得最多的 App").font(.system(size: 12, weight: .semibold))
            if model.top.isEmpty {
                Text("这个月还没有数据").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 28)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], alignment: .leading, spacing: 0) {
                ForEach(model.top.prefix(10)) { a in
                    HStack(spacing: 8) {
                        AppIconView(identity: a.identity)
                        Text(a.identity.name).lineLimit(1)
                        Spacer(minLength: 8)
                        SegmentBar(parts: [.init(value: Double(a.bytes.rx), color: Theme.download),
                                           .init(value: Double(a.bytes.tx), color: Theme.upload)],
                                   maxValue: maxV, height: 5)
                            .frame(width: 110)
                        Text(Fmt.bytes(Double(a.bytes.total))).monospacedDigit().frame(width: 66, alignment: .trailing)
                    }
                    .font(.system(size: 13))
                    .frame(height: 30)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.tile))
    }
}
