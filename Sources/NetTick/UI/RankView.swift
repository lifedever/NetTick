import Combine
import SwiftUI

/// 时间段
enum Period: Hashable {
    case today, yesterday, last7, last30, all
    case day(String)

    static let presets: [Period] = [.today, .yesterday, .last7, .last30, .all]

    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .last7: return "近 7 天"
        case .last30: return "近 30 天"
        case .all: return "全部"
        case .day(let d): return Self.dayTitle(d)
        }
    }

    /// 含两端的日期范围
    func range(firstDay: String?) -> (from: String, to: String) {
        let today = Day.key()
        switch self {
        case .today: return (today, today)
        case .yesterday: let y = Day.offset(today, -1); return (y, y)
        case .last7: return (Day.offset(today, -6), today)
        case .last30: return (Day.offset(today, -29), today)
        case .all: return (firstDay ?? today, today)
        case .day(let d): return (d, d)
        }
    }

    var isSingleDay: Bool {
        switch self {
        case .today, .yesterday, .day: return true
        default: return false
        }
    }

    static func dayTitle(_ key: String) -> String {
        guard let d = Day.date(key) else { return key }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        let thisYear = Calendar.current.component(.year, from: Date())
        return c.year == thisYear ? "\(c.month!) 月 \(c.day!) 日" : "\(c.year!) 年 \(c.month!) 月 \(c.day!) 日"
    }
}

/// 流量排行的数据。和窗口同寿命，切页回来直接显示上次的内容。
@MainActor
final class RankModel: ObservableObject {
    enum SortKey { case rx, tx, total }

    struct Detail {
        var key: String
        var bars: [(label: String, bytes: Bytes)] = []
        var note: String?
        var procs: [(name: String, bytes: Bytes)] = []
    }

    @Published var period: Period = .today { didSet { if period != oldValue { load() } } }
    @Published private(set) var rows: [AppTotal] = []
    @Published private(set) var firstDay: String?
    @Published var selected: String? { didSet { if selected != oldValue { loadDetail() } } }
    @Published var sort: SortKey = .total
    @Published private(set) var detail: Detail?
    private(set) var loaded = false

    private unowned let data: MainData
    init(data: MainData) { self.data = data }

    var sorted: [AppTotal] {
        rows.sorted {
            switch sort {
            case .rx: return $0.bytes.rx > $1.bytes.rx
            case .tx: return $0.bytes.tx > $1.bytes.tx
            case .total: return $0.bytes.total > $1.bytes.total
            }
        }
    }

    func load() {
        let p = period
        data.query({ db -> (String?, [AppTotal]) in
            let first = db.firstDay()
            let r = p.range(firstDay: first)
            return (first, db.ranking(from: r.from, to: r.to))
        }) { [weak self] first, rows in
            guard let self, p == self.period else { return }
            self.loaded = true
            self.firstDay = first
            self.rows = rows
            if self.selected == nil || !rows.contains(where: { $0.id == self.selected }) {
                self.selected = rows.first?.id
            } else {
                self.loadDetail()
            }
        }
    }

    func loadDetail() {
        guard let key = selected else { detail = nil; return }
        let p = period, first = firstDay
        data.query({ db -> Detail in
            let r = p.range(firstDay: first)
            var d = Detail(key: key)
            d.procs = db.processes(app: key, from: r.from, to: r.to)
            if p.isSingleDay {
                if let day = Day.date(r.from), Date().timeIntervalSince(day) > 3 * 86400 {
                    d.note = "每小时的明细只保留最近 3 天"     // 分钟明细只留 3 天
                } else {
                    d.bars = db.hourly(app: key, day: r.from).enumerated().map { ("\($0.offset)", $0.element) }
                }
            } else {
                let days = db.appDays(app: key, from: r.from, to: r.to)
                var day = r.from
                while day <= r.to && d.bars.count < 400 {
                    d.bars.append((String(day.suffix(2)), days[day] ?? Bytes()))
                    day = Day.offset(day, 1)
                }
            }
            return d
        }) { [weak self] d in
            guard let self, d.key == self.selected else { return }
            self.detail = d
        }
    }
}

struct RankView: View {
    @ObservedObject var model: RankModel
    @State private var pickingDate = false
    @State private var pickedDate = Date()
    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var isCustomDay: Bool { if case .day = model.period { return true }; return false }

    var body: some View {
        VStack(spacing: 14) {
            tiles
            HStack(alignment: .top, spacing: 16) {
                table
                if let sel = model.rows.first(where: { $0.id == model.selected }) {
                    AppDetail(app: sel, period: model.period, detail: model.detail?.key == sel.id ? model.detail : nil)
                        .frame(width: 250)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("时间段", selection: Binding(get: { Period.presets.contains(model.period) ? model.period : nil },
                                                  set: { if let p = $0 { model.period = p } })) {
                    ForEach(Period.presets, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                Button {
                    pickingDate.toggle()
                } label: {
                    Label(isCustomDay ? model.period.title : "选日期", systemImage: "calendar")
                        .labelStyle(.titleAndIcon)
                }
                .popover(isPresented: $pickingDate, arrowEdge: .bottom) {
                    DatePicker("", selection: $pickedDate, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                        .onChange(of: pickedDate) { _, d in
                            model.period = .day(Day.key(d))
                            pickingDate = false
                        }
                }
            }
        }
        .onAppear { model.load() }
        .onReceive(refresh) { _ in if model.period == .today { model.load() } }
    }

    // MARK: 合计

    private var tiles: some View {
        let total = model.rows.reduce(Bytes()) { var b = $0; b += $1.bytes; return b }
        return HStack(spacing: 10) {
            StatTile(label: "合计", value: Fmt.bytes(Double(total.total)), dot: nil)
            StatTile(label: "下载", value: Fmt.bytes(Double(total.rx)), dot: Theme.download)
            StatTile(label: "上传", value: Fmt.bytes(Double(total.tx)), dot: Theme.upload)
        }
    }

    // MARK: 表

    private var table: some View {
        let list = model.sorted
        let maxTotal = Double(model.rows.map(\.bytes.total).max() ?? 0)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("App").frame(maxWidth: .infinity, alignment: .leading)
                header("下载", .rx).frame(width: 80, alignment: .trailing)
                header("上传", .tx).frame(width: 80, alignment: .trailing)
                header("合计", .total).frame(width: 170, alignment: .trailing)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            Divider()
            if list.isEmpty && model.loaded {
                Text(model.period == .today ? "还没有数据。开着 NetTick，过一会儿这里就有了。" : "这段时间没有数据")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { row in
                        RankRow(row: row, maxTotal: maxTotal, selected: row.id == model.selected)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selected = row.id }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func header(_ title: String, _ key: RankModel.SortKey) -> some View {
        Button { model.sort = key } label: {
            Text(model.sort == key ? "\(title) ↓" : title)
        }
        .buttonStyle(.plain)
    }
}

private struct RankRow: View {
    let row: AppTotal
    let maxTotal: Double
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                AppIconView(identity: row.identity, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.identity.name).lineLimit(1)
                    if let sub = subtitle {
                        Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.bytes(Double(row.bytes.rx))).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(Fmt.bytes(Double(row.bytes.tx))).monospacedDigit().frame(width: 80, alignment: .trailing)
            HStack(spacing: 8) {
                SegmentBar(parts: [.init(value: Double(row.bytes.rx), color: Theme.download),
                                   .init(value: Double(row.bytes.tx), color: Theme.upload)],
                           maxValue: maxTotal, height: 5)
                Text(Fmt.bytes(Double(row.bytes.total))).monospacedDigit().frame(width: 62, alignment: .trailing)
            }
            .frame(width: 170)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
        .overlay(alignment: .bottom) { if !selected { Divider().opacity(0.6) } }
    }

    private var subtitle: String? {
        switch row.identity.kind {
        case .system: return "\(row.processCount) 个进程"
        case .other: return "系统进程、代理和 VPN 的开销"
        case .cli: return "命令行程序"
        case .app: return row.processCount > 1 ? "\(row.processCount) 个进程" : nil
        }
    }
}

struct StatTile: View {
    var label: String
    var value: String
    var dot: Color?
    var detail: String? = nil
    var hero = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let dot { Dot(color: dot) }
                Text(label)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            Text(value).font(.system(size: hero ? 28 : 20, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.tile))
    }
}

/// 右侧明细：选中 App 在这段时间里的分布和进程（数据由 RankModel 载入）
private struct AppDetail: View {
    let app: AppTotal
    let period: Period
    let detail: RankModel.Detail?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIconView(identity: app.identity, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.identity.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(period.title) · \(Fmt.bytes(Double(app.bytes.total)))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(period.isSingleDay ? "每小时" : "每天").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let note = detail?.note {
                    Text(note).font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 60)
                } else {
                    MiniBars(bars: detail?.bars ?? []).frame(height: 90)
                }
            }
            if app.identity.kind == .other {
                Text("网卡的量减去各 App 记到的量。主要是以系统账户运行的进程（比如系统更新），以及代理、VPN 加密多出来的那部分；看不到具体是哪个进程。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("进程").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(detail?.procs ?? [], id: \.name) { p in
                            HStack {
                                Text(p.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(Fmt.bytes(Double(p.bytes.total))).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            .frame(height: 22)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.tile))
    }
}

/// 明细里的小柱状图：下载在下、上传在上，中间 2pt 缝
struct MiniBars: View {
    var bars: [(label: String, bytes: Bytes)]
    var body: some View {
        GeometryReader { geo in
            let maxV = Double(bars.map(\.bytes.total).max() ?? 0)
            let n = max(1, bars.count)
            let step = geo.size.width / CGFloat(n)
            let bw = min(14, max(2, step - 2))
            let chartH = geo.size.height - 14
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5).offset(y: -14)
                ForEach(Array(bars.enumerated()), id: \.offset) { i, b in
                    let hd = maxV > 0 ? CGFloat(Double(b.bytes.rx) / maxV) * chartH : 0
                    let hu = maxV > 0 ? CGFloat(Double(b.bytes.tx) / maxV) * chartH : 0
                    VStack(spacing: hu >= 1 && hd >= 1 ? 1.5 : 0) {
                        if hu >= 1 { UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2).fill(Theme.upload).frame(height: hu) }
                        if hd >= 1 {
                            UnevenRoundedRectangle(topLeadingRadius: hu >= 1 ? 0 : 2, topTrailingRadius: hu >= 1 ? 0 : 2)
                                .fill(Theme.download).frame(height: hd)
                        }
                    }
                    .frame(width: bw)
                    .offset(x: CGFloat(i) * step + (step - bw) / 2, y: -14)
                    .help("\(b.label)：下载 \(Fmt.bytes(Double(b.bytes.rx)))，上传 \(Fmt.bytes(Double(b.bytes.tx)))")
                }
                // 数据还没回来时 bars 是空的：刻度按实际个数取，别按 max(1, …) 取（2026-11-24 越界崩溃）
                ForEach(labelIndexes(bars.count), id: \.self) { i in
                    Text(bars.count == 24 ? "\(i)时" : bars[i].label)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .offset(x: CGFloat(i) * step, y: 0)
                }
            }
        }
    }

    private func labelIndexes(_ n: Int) -> [Int] {
        guard n > 0 else { return [] }
        if n == 24 { return [0, 6, 12, 18] }
        let stride = max(1, n / 5)
        return Array(Swift.stride(from: 0, to: n, by: stride))
    }
}
