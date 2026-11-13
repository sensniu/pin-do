import Combine
import Foundation

enum WorkspaceMode: String, CaseIterable { case board = "白板", overview = "概览" }
enum SettingsSection: String, CaseIterable { case general = "通用", appearance = "外观", sync = "同步", data = "数据" }
enum AppPanel: String { case settings, projects, help }

@MainActor
final class AppNavigation: ObservableObject {
    @Published var mode: WorkspaceMode = .board
    @Published var overviewReturnAvailable = false
    @Published private(set) var panel: AppPanel?
    @Published private(set) var section: SettingsSection = .general
    @Published var showSyncIssues = false
    @Published var createProject = false
    @Published var showShortcuts = false
    private var guardOwner: UUID?
    private var leaveGuard: (() -> Bool)?

    func registerGuard(owner: UUID, _ action: @escaping () -> Bool) { guardOwner = owner; leaveGuard = action }
    func removeGuard(owner: UUID) { if owner == guardOwner { leaveGuard = nil; guardOwner = nil } }
    @discardableResult
    func present(_ target: AppPanel?, section requested: SettingsSection? = nil) -> Bool {
        let section = requested ?? self.section
        if panel == target && (target != .settings || self.section == section) { return true }
        guard leaveGuard?() ?? true else { return false }
        if panel != target { leaveGuard = nil; guardOwner = nil }
        self.section = section; panel = target
        return true
    }
}
