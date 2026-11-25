import SwiftUI

/// 主窗口要的数据入口：查询都经 Recorder 走 dbQueue，结果回主线程。
/// 各页的数据模型挂在这里，和窗口同寿命：切页时直接显示上次的内容、后台再刷新，不会先空一下再出来。
@MainActor
final class MainData: ObservableObject {
    let recorder: Recorder
    /// key → 名字、图标路径。每次取内存数据时顺手刷新
    private(set) var identities: [String: AppIdentity] = [:]

    lazy var rank = RankModel(data: self)
    lazy var curve = CurveModel(data: self)
    lazy var month = MonthModel(data: self)

    init(recorder: Recorder) { self.recorder = recorder }

    func query<T>(_ work: @escaping (Database) -> T, completion: @escaping (T) -> Void) {
        recorder.query(work, completion: completion)
    }

    /// 最近 1 小时的 10 秒格（采集队列上的内存数据）
    func buckets(_ completion: @escaping ([Recorder.Bucket]) -> Void) {
        let r = recorder
        r.engine.async {
            let b = r.buckets, ids = r.identities
            DispatchQueue.main.async {
                self.identities = ids
                completion(b)
            }
        }
    }

    /// 按量倒序；不认识的 key 用 key 本身当名字
    func resolve(_ apps: [String: Bytes]) -> [(AppIdentity, Bytes)] {
        apps.map { k, b in
            (identities[k] ?? AppIdentity(key: k, name: k, kind: .cli, bundleID: nil, path: ""), b)
        }
        .sorted { $0.1.total > $1.1.total }
    }
}

/// 系统原生的侧边栏 + 工具栏（macOS 26 起侧边栏是浮起来的玻璃）。别再自己画侧边栏和标题行。
struct MainView: View {
    @ObservedObject var nav: MainNav
    let data: MainData

    /// 侧栏宽度：拖完记下来，下次打开用这个宽度（NavigationSplitView 自己不存）。
    /// 只在建视图时读一次当 ideal，拖的过程中不回写 ideal，免得和拖拽打架
    @State private var sidebarIdeal = MainView.savedSidebarWidth
    /// 最宽就是默认的 210：窗口最窄 920 时内容区要 710，侧栏再宽排行表的 App 名就截成「cla…」（侧栏 240 实测）。
    /// 想放宽上限，窗口最小宽度得跟着加（minSize 是按默认侧栏 + 内容区算的）
    static let sidebarRange: ClosedRange<CGFloat> = 170...defaultSidebarWidth
    private static let sidebarKey = "sidebarWidth"
    /// 第一次打开的侧栏宽度（配合默认窗口 920×640）
    static let defaultSidebarWidth: CGFloat = 210
    private static var savedSidebarWidth: CGFloat {
        let w = CGFloat(UserDefaults.standard.double(forKey: sidebarKey))
        return sidebarRange.contains(w) ? w : defaultSidebarWidth
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.page }, set: { if let p = $0 { nav.page = p } })) {
                Section {
                    ForEach(MainPage.statsPages) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                Section("设置") {
                    ForEach(MainPage.settingsPages) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
            }
            // 收起侧栏时宽度是 0，不在范围里，不记
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                if Self.sidebarRange.contains(w) { UserDefaults.standard.set(Double(w), forKey: Self.sidebarKey) }
            }
            // 列宽必须是侧栏内容最外层的修饰：包在 onGeometryChange 里面时整个不生效，侧栏缩到 144（2026-11-25 实测）
            .navigationSplitViewColumnWidth(min: Self.sidebarRange.lowerBound, ideal: sidebarIdeal,
                                            max: Self.sidebarRange.upperBound)
        } detail: {
            Group {
                switch nav.page {
                case .rank: RankView(model: data.rank)
                case .curve: CurveView(model: data.curve)
                case .month: MonthView(model: data.month)
                case .general: GeneralSettingsView()
                case .menuBar: MenuBarSettingsView()
                case .notifications: NotificationSettingsView()
                case .data: DataSettingsView(data: data)
                case .about: AboutView()
                }
            }
            .navigationTitle(nav.page.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
    }

    /// 侧栏 210 时右边内容区要的宽度：排行页表格约 450 + 明细 220 + 边距（900 宽、侧栏 210 实测 App 名截得没法看）。
    /// 只用来算窗口最小宽度，**别加到内容区的 minWidth 上**：和侧栏上限 240 冲突，窗口最窄时一拖侧栏，
    /// 侧栏列表整体左移、图标被切掉（复现：记的侧栏 240 + 窗口 920）
    static let detailMinWidth: CGFloat = 710
    /// 整个窗口内容区的最小尺寸 = 默认侧栏 + 内容区要的宽度，也就是默认大小；
    /// 高度 640 是月报页撑的（三个数字卡 + 图表最低 200 + 前几名 App）。
    static let minSize = NSSize(width: defaultSidebarWidth + detailMinWidth, height: 640)
    /// 第一次打开的大小（之后按上次调过的大小，见 MainWindowController 的 autosave）
    static let defaultSize = NSSize(width: 920, height: 640)
}
