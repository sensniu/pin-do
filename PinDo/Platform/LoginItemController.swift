import AppKit
import Carbon
import Combine
import ServiceManagement

extension ApplicationLaunchPolicy {
    static func isLoginEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication &&
            (event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem ||
             event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true)
    }
}

enum LoginItemStatus: Equatable {
    case off, enabled, requiresApproval, unavailable
}

@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

struct SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .off
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus = .off
    @Published private(set) var error: String?
    let canConfigure: Bool
    private let service: any LoginItemService

    init(service: any LoginItemService = SystemLoginItemService(), canConfigure: Bool) {
        self.service = service; self.canConfigure = canConfigure
        // Reading status never registers a login item. New installations default to off.
        refresh()
    }
    func refresh() { status = canConfigure ? service.status : .off }
    func setEnabled(_ enabled: Bool) {
        guard canConfigure else { error = "请先将正式版拖入“应用程序”，再设置开机自启。"; return }
        error = nil
        do {
            if enabled && status != .enabled && status != .requiresApproval { try service.register() }
            if !enabled && status != .off { try service.unregister() }
        } catch { self.error = "开机自启设置未完成：\(error.localizedDescription)" }
        refresh() // Report the system's actual status, including approval pending or failure.
    }
    var label: String {
        switch status {
        case .off: "开机自启"
        case .enabled: "开机自启（后台运行）"
        case .requiresApproval: "开机自启（等待系统允许）"
        case .unavailable: "开机自启（暂不可用）"
        }
    }
}
