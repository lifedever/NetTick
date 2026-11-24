import AppKit
import SwiftUI

/// 设置：系统原生的分组表单（和系统设置一个样子）
struct SettingsView: View {
    let data: MainData

    /// 登录项状态是系统托管的外部状态：用 @State 镜像，进页面和切回 App 时现读（HealthTick #32）
    @State private var loginState = LoginItem.state
    @State private var notifyNewApp = NewAppNotifier.shared.enabled
    @State private var showArrows = MenuBarStyle.showArrows
    @State private var firstLaunch: Date?
    @State private var dbSize: Int64 = 0

    var body: some View {
        Form {
            Section("通用") {
                Toggle(isOn: Binding(get: { loginState == .enabled }, set: { loginState = LoginItem.set($0) })) {
                    Text("开机时启动")
                    Text(loginDetail)
                }
                if loginState == .requiresApproval {
                    Button("打开登录项设置") { LoginItem.openSystemSettings() }
                }
            }
            Section("菜单栏") {
                Toggle(isOn: Binding(get: { showArrows }, set: { v in
                    showArrows = v
                    MenuBarStyle.showArrows = v
                })) {
                    Text("显示箭头")
                    Text(showArrows ? "↑ 上传，↓ 下载。" : "上面一行是上传，下面一行是下载。")
                }
            }
            Section("提醒") {
                Toggle(isOn: Binding(get: { notifyNewApp }, set: { v in
                    notifyNewApp = v
                    NewAppNotifier.shared.enabled = v
                    if v { NewAppNotifier.shared.prepare() }
                })) {
                    Text("新程序第一次联网时通知")
                    Text("只通知，不拦截。")
                }
            }
            Section("数据") {
                LabeledContent {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([data.recorder.db.url])
                    }
                } label: {
                    Text(firstLaunch.map { "从 \(Self.dateTitle($0)) 开始统计" } ?? "开始统计")
                    Text("占用 \(Fmt.bytes(Double(dbSize)))")
                }
            }
        }
        .formStyle(.grouped)
        // 别限宽：限了右边留一大块白，连工具栏分隔线都断在那儿（2026-11-24 用户指出）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginState = LoginItem.state
        }
    }

    private var loginDetail: String {
        switch loginState {
        case .requiresApproval: return "要在系统设置 → 通用 → 登录项里允许 NetTick。"
        default: return "不开的话，NetTick 没运行的时候统计不到。"
        }
    }

    private func load() {
        loginState = LoginItem.state
        notifyNewApp = NewAppNotifier.shared.enabled
        data.query({ db -> (Double?, Int64) in
            (db.metaValue("first_launch").flatMap(Double.init), db.fileSize)
        }) { first, size in
            firstLaunch = first.map { Date(timeIntervalSince1970: $0) }
            dbSize = size
        }
    }

    private static func dateTitle(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year!) 年 \(c.month!) 月 \(c.day!) 日"
    }
}
