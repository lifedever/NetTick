import AppKit
import SwiftUI
import UserNotifications

enum AppLinks {
    /// 赞助页（根域名就是赞助页，`/sponsor/` 也跳到这里）
    static let sponsor = URL(string: "https://www.lifedever.com")!
}

// 设置拆成侧栏里的五页（2026-11-25 用户要求：侧栏空着，别一长页往下拉）：通用 / 菜单栏 / 通知 / 数据 / 关于。
// 每页都是系统原生的分组表单（和系统设置一个样子）；关于页居中排，放版本、检查更新、赞助支持。
// 表单别限宽：限了右边留一大块白，连工具栏分隔线都断在那儿（2026-11-24 用户指出）。

// MARK: - 通用

struct GeneralSettingsView: View {
    /// 登录项状态是系统托管的外部状态：用 @State 镜像，进页面和切回 App 时现读（HealthTick #32）
    @State private var loginState = LoginItem.state
    @State private var autoUpdate = UpdateChecker.shared.autoCheck

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { loginState == .enabled }, set: { loginState = LoginItem.set($0) })) {
                    Text("开机时启动")
                    Text(loginState == .requiresApproval ? "要在系统设置 → 通用 → 登录项里允许 NetTick。"
                                                         : "不开的话，NetTick 没运行的时候统计不到。")
                }
                if loginState == .requiresApproval {
                    Button("打开登录项设置") { LoginItem.openSystemSettings() }
                }
                Toggle(isOn: Binding(get: { autoUpdate }, set: { v in
                    autoUpdate = v
                    UpdateChecker.shared.autoCheck = v
                })) {
                    Text("自动检查更新")
                    Text("每天检查一次，有新版本时提示。")
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loginState = LoginItem.state }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginState = LoginItem.state
        }
    }
}

// MARK: - 菜单栏

struct MenuBarSettingsView: View {
    @State private var showArrows = MenuBarStyle.showArrows

    var body: some View {
        Form {
            Section("显示样式") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 20) {
                        option(arrows: true, title: "带箭头")
                        option(arrows: false, title: "不带箭头")
                        Spacer(minLength: 0)
                    }
                    Text("上面一行是上传，下面一行是下载。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func option(arrows: Bool, title: String) -> some View {
        let selected = showArrows == arrows
        return Button {
            showArrows = arrows
            MenuBarStyle.showArrows = arrows
        } label: {
            VStack(spacing: 8) {
                MenuBarSample(showArrows: arrows)
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5))
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 一小块桌面 + 半透明菜单栏，里面是速率和几个系统图标。速率用菜单栏真正的绘制代码（RatesRenderer）画
private struct MenuBarSample: View {
    var showArrows: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .top) {
            DesktopBackdrop()
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Image(nsImage: MenuBarPreview.image(showArrows: showArrows))
                    .renderingMode(.template)
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("10:55")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(dark ? Color.black.opacity(0.28) : Color.white.opacity(0.42))
        }
        .frame(width: 250, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// 预览图只画一次：RatesRenderer 每建一个就要造一次字体（swift-rules #11，别在重绘里造）
@MainActor
private enum MenuBarPreview {
    private static var cache: [Bool: NSImage] = [:]
    static func image(showArrows: Bool) -> NSImage {
        if let img = cache[showArrows] { return img }
        let img = RatesRenderer(showArrows: showArrows).image(up: 86_400, down: 2_310_000)
        cache[showArrows] = img
        return img
    }
}

/// 预览用的桌面壁纸：和设计稿 mockups 的舞台背景同一套渐变
private struct DesktopBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: scheme == .dark ? [hex(0x1b2440), hex(0x0f1422), hex(0x33283f)]
                                               : [hex(0xb9cdf6), hex(0xdfe3ea), hex(0xf1d2c4)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

// MARK: - 通知

struct NotificationSettingsView: View {
    @State private var enabled = NewAppNotifier.shared.enabled
    /// 系统设置里关掉了 NetTick 的通知：开关开着也收不到，要说出来
    @State private var systemDenied = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { enabled }, set: { v in
                    enabled = v
                    NewAppNotifier.shared.enabled = v
                    if v { NewAppNotifier.shared.prepare() }
                })) {
                    Text("新程序第一次联网时通知")
                    Text("只通知，不拦截。")
                }
                if enabled && systemDenied {
                    LabeledContent {
                        Button("打开通知设置") { openSystemNotificationSettings() }
                    } label: {
                        Text("系统设置里关掉了 NetTick 的通知")
                        Text("打开之前收不到。")
                    }
                }
            }
            Section("预览") {
                NotificationSample()
                    .opacity(enabled ? 1 : 0.45)
                    .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        systemDenied = status == .denied
    }

    private func openSystemNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.lifedever.NetTick"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 一条通知横幅，标题和正文的写法和 NewAppNotifier 发的一样
private struct NotificationSample: View {
    var body: some View {
        ZStack {
            DesktopBackdrop()
            HStack(alignment: .center, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("ollama 第一次联网").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("现在").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("/opt/homebrew/bin/ollama")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 330)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .frame(width: 380, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - 数据

struct DataSettingsView: View {
    let data: MainData

    private struct Summary {
        var firstLaunch: Date?
        var total = Bytes()
        var appCount = 0
        var dbSize: Int64 = 0
    }
    @State private var summary: Summary?

    var body: some View {
        Form {
            Section {
                LabeledContent("开始统计") {
                    Text(summary?.firstLaunch.map(Self.dateTitle) ?? "—")
                }
                LabeledContent("累计流量") {
                    if let s = summary {
                        HStack(spacing: 10) {
                            Text(Fmt.bytes(Double(s.total.total)))
                            Legend(color: Theme.download, text: "↓ \(Fmt.bytes(Double(s.total.rx)))")
                            Legend(color: Theme.upload, text: "↑ \(Fmt.bytes(Double(s.total.tx)))")
                        }
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("记录的 App") {
                    Text(summary.map { "\($0.appCount) 个" } ?? "—")
                }
            }
            Section {
                LabeledContent {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([data.recorder.db.url])
                    }
                } label: {
                    Text("数据库")
                    Text(summary.map { "占用 \(Fmt.bytes(Double($0.dbSize)))" } ?? " ")
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .monospacedDigit()
        .onAppear(perform: load)
    }

    private func load() {
        data.query({ db -> Summary in
            // 全部时间段的排行：各 App + 「其他」，加起来就是网卡的量（和排行页「全部」一致）
            let rows = db.ranking(from: "0000-01-01", to: "9999-12-31")
            var s = Summary()
            s.firstLaunch = db.metaValue("first_launch").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            for r in rows { s.total += r.bytes }
            s.appCount = rows.filter { $0.identity.kind != .other }.count
            s.dbSize = db.fileSize
            return s
        }) { summary = $0 }
    }

    private static func dateTitle(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year!) 年 \(c.month!) 月 \(c.day!) 日"
    }
}

// MARK: - 关于

/// 居中排：图标、名字、版本和更新状态，下面「检查更新」「赞助支持」（按钮组合照 TabFlick 的关于页）
struct AboutView: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 112, height: 112)
            Text("NetTick")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 10)
            Text("菜单栏流量监控")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            HStack(spacing: 6) {
                Text("版本 \(updates.currentVersion)")
                statusView
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.top, 12)
            HStack(spacing: 10) {
                Button("检查更新") { updates.check(userInitiated: true) }
                    .disabled(updates.status == .checking || updates.isDownloading)
                Button { NSWorkspace.shared.open(AppLinks.sponsor) } label: {
                    Label {
                        Text("赞助支持")
                    } icon: {
                        Image(systemName: "heart.fill").foregroundStyle(.pink)
                    }
                }
            }
            .controlSize(.large)
            .padding(.top, 20)
            Spacer()
            Text(Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "© lifedever")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var statusView: some View {
        switch updates.status {
        case .idle:
            EmptyView()
        case .checking:
            Text("·")
            ProgressView().controlSize(.mini)
            Text("正在检查…")
        case .upToDate:
            Text("·")
            Text("已是最新版本")
        case .available(let v):
            Text("·")
            Text("有新版本 \(v)").foregroundStyle(Color.accentColor)
        case .failed(let m):
            Text("·")
            Text("检查失败").help(m)
        }
    }
}
