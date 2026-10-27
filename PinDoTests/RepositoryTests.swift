import XCTest

final class RepositoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    func testItemsHistoryAndDraftSurviveReopening() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        var repository: TodoRepository? = try TodoRepository(paths: paths, appVersion: "0.1.0")
        var item = TodoItem(title: "saved", notes: "完整备注", dueAt: .now.addingTimeInterval(60), stars: 3)
        try repository!.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: .now), clearDraft: true)
        item.title = "updated"
        try repository!.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: .now), clearDraft: true)
        item.status = .completed
        item.completedAt = .now
        let completion = TodoEvent(itemID: item.id, kind: .completed, occurredAt: .now)
        try repository!.commit(item, event: completion, clearDraft: false)
        item.status = .active
        item.completedAt = nil
        try repository!.commit(item, event: TodoEvent(itemID: item.id, kind: .completionUndone, occurredAt: .now, relatedCompletionID: completion.id), clearDraft: false)
        var draft = NoteDraft(item: item, now: .now)
        draft.notes = "还未提交的草稿"
        try repository!.saveDraft(draft)
        repository = nil

        repository = try TodoRepository(paths: paths, appVersion: "0.1.0")
        XCTAssertEqual(try repository!.loadActiveItems(), [item])
        XCTAssertEqual(try repository!.loadDraft(), draft)
        XCTAssertEqual(try repository!.archive().records.filter { $0.bucket == "event" }.count, 4)
        repository = nil
    }

    @MainActor
    func testCompletedAndAbandonedAreRetainedSeparately() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var repository: TodoRepository? = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.1.0")
        var completed = TodoItem(title: "done")
        var abandoned = TodoItem(title: "cancelled")
        for item in [completed, abandoned] {
            try repository!.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: .now), clearDraft: true)
        }
        completed.status = .completed
        completed.completedAt = .now
        abandoned.status = .abandoned
        abandoned.abandonedAt = .now
        try repository!.commit(completed, event: TodoEvent(itemID: completed.id, kind: .completed, occurredAt: .now), clearDraft: false)
        try repository!.commit(abandoned, event: TodoEvent(itemID: abandoned.id, kind: .abandoned, occurredAt: .now), clearDraft: true)
        repository = nil
        repository = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.1.0")
        XCTAssertTrue(try repository!.loadActiveItems().isEmpty)
        let records = try repository!.archive().records
        XCTAssertEqual(records.filter { $0.bucket == "todo-completed" }.count, 1)
        XCTAssertEqual(records.filter { $0.bucket == "todo-abandoned" }.count, 1)
        repository = nil
    }

    @MainActor
    func testFailedEventEncodingRollsBackItemMutation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.1.0")
        let original = TodoItem(title: "original")
        try repository.commit(original, event: TodoEvent(itemID: original.id, kind: .created, occurredAt: .now), clearDraft: true)
        var modified = original
        modified.title = "must not save"
        let invalid = TodoEvent(itemID: original.id, kind: .edited, occurredAt: Date(timeIntervalSince1970: .nan))
        XCTAssertThrowsError(try repository.commit(modified, event: invalid, clearDraft: false))
        XCTAssertEqual(try repository.loadActiveItems(), [original])
        XCTAssertEqual(try repository.archive().records.filter { $0.bucket == "event" }.count, 1)
    }

    @MainActor
    func testUpgradeKeepsIDsHistoryAndCreatesBoundedSafetyCopies() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let item = TodoItem(title: "upgrade-safe")
        var repository: TodoRepository? = try TodoRepository(paths: paths, appVersion: "0.1.0")
        try repository!.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: .now), clearDraft: true)
        repository = nil
        for version in ["0.1.1", "0.1.2", "0.1.3", "0.1.4"] {
            repository = try TodoRepository(paths: paths, appVersion: version)
            XCTAssertEqual(try repository!.loadActiveItems(), [item])
            XCTAssertEqual(try repository!.archive().records.filter { $0.bucket == "event" }.count, 1)
            repository = nil
        }
        let backups = try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("before-upgrade-") }
        XCTAssertEqual(backups.count, 3)
        for copy in backups {
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("PinDo.store").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("StoreInfo.json").path))
            let manifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: copy.appendingPathComponent("StoreInfo.json")))
            let recovered = try TodoRepository(paths: AppPaths(root: copy), appVersion: manifest.lastAppVersion)
            XCTAssertEqual(try recovered.loadActiveItems(), [item])
            XCTAssertEqual(try recovered.archive().records.filter { $0.bucket == "event" }.count, 1)
        }
        XCTAssertThrowsError(try TodoRepository(paths: paths, appVersion: "0.1.0"))
    }

    @MainActor
    func testFutureFormatAndMissingManifestNeverCreateEmptyReplacement() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        var repository: TodoRepository? = try TodoRepository(paths: paths, appVersion: "0.1.0")
        let item = TodoItem(title: "protected")
        try repository!.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: .now), clearDraft: true)
        repository = nil
        let manifestData = try Data(contentsOf: paths.manifest)
        var manifest = try JSONDecoder().decode(StoreManifest.self, from: manifestData)
        manifest.formatVersion = 99
        try JSONEncoder().encode(manifest).write(to: paths.manifest, options: .atomic)
        XCTAssertThrowsError(try TodoRepository(paths: paths, appVersion: "0.1.0"))
        try FileManager.default.removeItem(at: paths.manifest)
        XCTAssertThrowsError(try TodoRepository(paths: paths, appVersion: "0.1.0"))
        try manifestData.write(to: paths.manifest, options: .atomic)
        repository = try TodoRepository(paths: paths, appVersion: "0.1.0")
        XCTAssertEqual(try repository!.loadActiveItems(), [item])
        repository = nil
    }

    @MainActor
    func testSecondWriterIsRejected() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let repository = try TodoRepository(paths: paths, appVersion: "0.1.0")
        XCTAssertThrowsError(try TodoRepository(paths: paths, appVersion: "0.1.0"))
        XCTAssertTrue(try repository.loadActiveItems().isEmpty)
    }

    @MainActor
    func testBackupRestoreAndChecksumProtection() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.1.0")
        let original = TodoItem(title: "original")
        try repository.commit(original, event: TodoEvent(itemID: original.id, kind: .created, occurredAt: .now), clearDraft: true)
        let encoded = try BackupCodec.encode(repository.archive())
        let archive = try BackupCodec.decode(encoded)
        var changed = original
        changed.title = "changed"
        try repository.commit(changed, event: TodoEvent(itemID: original.id, kind: .edited, occurredAt: .now), clearDraft: false)
        try repository.restore(archive)
        XCTAssertEqual(try repository.loadActiveItems(), [original])
        let safety = try BackupCodec.decode(Data(contentsOf: repository.paths.backups.appendingPathComponent("before-restore.pindobackup")))
        let prior = try JSONDecoder().decode(TodoItem.self, from: safety.records.first { $0.bucket == "todo-active" }!.payload)
        XCTAssertEqual(prior.title, "changed")
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json["checksum"] = "invalid"
        let corrupted = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try BackupCodec.decode(corrupted))
        XCTAssertEqual(try repository.loadActiveItems(), [original])
    }

    @MainActor
    func testAutomaticBackupUsesLatestValuesAndRotatesSevenDays() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.1.0")
        var item = TodoItem(title: "first")
        try repository.commit(item, event: TodoEvent(itemID: item.id, kind: .created, occurredAt: .now), clearDraft: true)
        try await repository.createAutomaticBackupNow()
        item.title = "latest"
        try repository.commit(item, event: TodoEvent(itemID: item.id, kind: .edited, occurredAt: .now), clearDraft: false)
        let seed = try BackupCodec.encode(repository.archive())
        for day in 1...10 {
            try seed.write(to: repository.paths.backups.appendingPathComponent(String(format: "daily-2020-01-%02d.pindobackup", day)))
        }
        try await repository.createAutomaticBackupNow()
        let backups = try FileManager.default.contentsOfDirectory(at: repository.paths.backups, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("daily-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        XCTAssertEqual(backups.count, 7)
        let latest = try BackupCodec.decode(Data(contentsOf: backups[0]))
        let stored = try JSONDecoder().decode(TodoItem.self, from: latest.records.first { $0.bucket == "todo-active" }!.payload)
        XCTAssertEqual(stored.title, "latest")
    }
}

