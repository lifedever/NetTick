import SwiftUI

/// 主窗口要的数据入口：查询都经 Recorder 走 dbQueue，结果回主线程。
/// 各页的数据模型挂在这里，和窗口同寿命：切页时直接显示上次的内容、后台再刷新，不会先空一下再出来（2026-11-24 用户反馈切页闪）。
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

    var body: some View {
        NavigationSplitView {
            List(MainPage.allCases, selection: Binding(get: { nav.page }, set: { if let p = $0 { nav.page = p } })) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch nav.page {
                case .rank: RankView(model: data.rank)
                case .curve: CurveView(model: data.curve)
                case .month: MonthView(model: data.month)
                case .settings: SettingsView(data: data)
                }
            }
            .navigationTitle(nav.page.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
    }

    /// 整个窗口内容区的最小尺寸：侧边栏 200 + 排行页（表格最窄约 480 + 明细 250 + 边距）
    static let minSize = NSSize(width: 1000, height: 640)
}
