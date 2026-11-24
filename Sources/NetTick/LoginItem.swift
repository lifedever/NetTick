import ServiceManagement

/// 「开机时启动」（照 TabFlick）。状态是系统托管的，随时可能在系统设置里被改掉：
/// 界面用 @State 镜像，每次进设置页、切回 App 时现读（HealthTick #32 的教训）。
enum LoginItem {
    enum State { case enabled, disabled, requiresApproval }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    /// 打开或关闭，返回操作后的真实状态（不是期望状态）
    @discardableResult
    static func set(_ on: Bool) -> State {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("登录项切换失败：\(error.localizedDescription)")
        }
        return state
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
