import Foundation
import UserNotifications

/// 新程序第一次联网时发通知（只通知，不拦截）。开关在设置里，默认开。
@MainActor
final class NewAppNotifier {
    static let shared = NewAppNotifier()
    static let enabledKey = "notifyNewApp"

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// 启动时问一次授权（系统只弹一次，之后在系统设置里改）
    func prepare() {
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { log("通知授权出错：\(error.localizedDescription)") }
            log("通知授权：\(granted)")
        }
    }

    func notify(_ id: AppIdentity) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(id.name) 第一次联网"
        content.body = id.path.isEmpty ? id.name : id.path
        let req = UNNotificationRequest(identifier: "new-app-" + id.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { log("通知发送失败：\(error.localizedDescription)") }
        }
        log("新程序联网：\(id.name)（\(id.key)）")
    }
}
