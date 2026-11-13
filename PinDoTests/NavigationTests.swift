import XCTest

final class NavigationTests: XCTestCase {
    @MainActor
    func testAllSettingsEntrancesReuseOnePanelAndRememberSection() {
        let navigation = AppNavigation()
        XCTAssertTrue(navigation.present(.settings,section:.appearance))
        XCTAssertEqual(navigation.panel,.settings); XCTAssertEqual(navigation.section,.appearance)
        XCTAssertTrue(navigation.present(nil)); XCTAssertTrue(navigation.present(.settings))
        XCTAssertEqual(navigation.section,.appearance)
        XCTAssertTrue(navigation.present(.settings,section:.sync)); XCTAssertEqual(navigation.panel,.settings)
    }
    @MainActor
    func testDirtyFormCanCancelSectionSwitchAndClosing() {
        let navigation = AppNavigation(), owner = UUID()
        navigation.present(.settings,section:.appearance)
        navigation.registerGuard(owner:owner) { false }
        XCTAssertFalse(navigation.present(.settings,section:.sync)); XCTAssertEqual(navigation.section,.appearance)
        XCTAssertFalse(navigation.present(nil)); XCTAssertEqual(navigation.panel,.settings)
        XCTAssertFalse(navigation.present(.projects)); XCTAssertEqual(navigation.panel,.settings)
    }
    @MainActor
    func testSectionSwitchKeepsGuardButReplacingPanelClearsIt() {
        let navigation = AppNavigation(), owner = UUID(); var checks = 0
        navigation.present(.settings)
        navigation.registerGuard(owner:owner) { checks += 1; return true }
        navigation.present(.settings,section:.sync); navigation.present(.settings,section:.data)
        XCTAssertEqual(checks,2)
        navigation.present(.projects); XCTAssertEqual(checks,3)
        navigation.present(nil); XCTAssertEqual(checks,3)
    }
    @MainActor
    func testOldDisappearingPanelCannotRemoveNewPanelsGuard() {
        let navigation = AppNavigation(), old = UUID(), next = UUID()
        navigation.present(.settings); navigation.registerGuard(owner:old) { true }
        navigation.present(.projects); navigation.registerGuard(owner:next) { false }
        navigation.removeGuard(owner:old)
        XCTAssertFalse(navigation.present(nil)); XCTAssertEqual(navigation.panel,.projects)
    }
    @MainActor
    func testRepeatedEntranceDoesNotDuplicatePanelOrPrompt() {
        let navigation = AppNavigation(); var checks = 0
        navigation.present(.settings,section:.sync)
        navigation.registerGuard(owner:UUID()) { checks += 1; return false }
        XCTAssertTrue(navigation.present(.settings,section:.sync)); XCTAssertEqual(checks,0)
    }
    @MainActor
    func testRestoreMaintenanceBlocksConnectionChangesAndResumeWithoutDiscardingLocalEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-maintenance-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try TodoRepository(paths:AppPaths(root:root),appVersion:"0.11.0")
        let item = TodoItem(title:"pending local input")
        try store.commit(item,event:TodoEvent(itemID:item.id,kind:.created,occurredAt:.now),clearDraft:true)
        try store.initializeSync()
        var state = try XCTUnwrap(store.syncState()); state.enabled = false
        state.connection = SyncConnection(server:"invalid",directory:"test",username:"test")
        try store.saveSyncState(state)
        let sync = SyncCoordinator(); sync.attach(store)
        let pending = try store.syncState()?.pendingCount
        XCTAssertTrue(sync.beginMaintenance()); XCTAssertFalse(sync.beginMaintenance())
        sync.resume(); XCTAssertFalse(sync.enabled)
        do { try await sync.connect(state.connection!,password:"test-only"); XCTFail("Maintenance allowed a connection") } catch { }
        sync.endMaintenance(); sync.resume(); XCTAssertTrue(sync.enabled)
        sync.pause(); XCTAssertFalse(sync.enabled)
        XCTAssertEqual(try store.syncState()?.pendingCount,pending)
        XCTAssertEqual(try store.storedItem(item.id)?.title,item.title)
    }
}
