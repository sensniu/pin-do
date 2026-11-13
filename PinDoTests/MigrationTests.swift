import Foundation
import SwiftData
import XCTest

final class MigrationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pindo-migration-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    // Literal v0.1 JSON fields and reference-date encoding, independent of current model encoders.
    private func legacyRecords(historyOnly: Bool = false) throws -> [StoredValue] {
        let states = historyOnly ? ["completed", "abandoned"] : ["active", "completed", "abandoned"]
        var records: [StoredValue] = []
        let time = Date(timeIntervalSince1970: 1_750_000_000)
        for (index, status) in states.enumerated() {
            let id = UUID()
            var json: [String: Any] = ["id": id.uuidString, "title": "legacy-\(status)", "notes": "old note", "stars": 2,
                "status": status, "createdAt": time.timeIntervalSinceReferenceDate, "updatedAt": time.timeIntervalSinceReferenceDate]
            if index == 0 { json["category"] = ["id": "work", "name": "工作", "red": 0.25, "green": 0.46, "blue": 0.83] }
            else if index == 1 { json["category"] = ["id": "personal", "name": "生活", "red": 0.23, "green": 0.57, "blue": 0.42] }
            if status == "completed" { json["completedAt"] = time.timeIntervalSinceReferenceDate }
            if status == "abandoned" { json["abandonedAt"] = time.timeIntervalSinceReferenceDate }
            records.append(StoredValue(key: "todo:\(id.uuidString)", bucket: "todo-\(status)", payload: try JSONSerialization.data(withJSONObject: json)))
            let event = TodoEvent(itemID: id, kind: .created, occurredAt: time)
            records.append(StoredValue(key: "event:\(event.id.uuidString)", bucket: "event", payload: try JSONEncoder().encode(event)))
            if status == "active" {
                let draft: [String: Any] = ["id": id.uuidString, "isNew": false, "title": "unfinished title", "notes": "unsaved note",
                    "hasDeadline": false, "dueAt": time.timeIntervalSinceReferenceDate, "stars": 3, "categoryID": "work"]
                records.append(StoredValue(key: "editor-draft", bucket: "draft", payload: try JSONSerialization.data(withJSONObject: draft)))
            }
        }
        return records
    }
    @MainActor private func writeLegacy(_ records: [StoredValue], root: URL) throws {
        let schema = Schema(versionedSchema: StoreSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: AppPaths(root: root).store, cloudKitDatabase: .none)])
        let context = ModelContext(container); context.autosaveEnabled = false
        for row in records { context.insert(StoreRecord(key: row.key, bucket: row.bucket, payload: row.payload)) }
        try context.save()
        let manifest: [String: Any] = ["formatVersion": 1, "storeID": UUID().uuidString, "createdAt": Date.now.timeIntervalSinceReferenceDate, "lastAppVersion": "0.1.0"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: AppPaths(root: root).manifest)
    }
    @MainActor func testRealLegacyStoreMigratesAllStatesDraftAndReopensWithSameIDs() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let records = try legacyRecords(); try writeLegacy(records, root: root)
        let expectedIDs = Set(records.filter { $0.bucket.hasPrefix("todo-") }.map(\.key))
        var store: TodoRepository? = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        let output = try store!.archive()
        XCTAssertEqual(Set(output.records.filter { $0.bucket.hasPrefix("todo-") }.map(\.key)), expectedIDs)
        XCTAssertTrue(output.records.filter { $0.bucket == "event" }.isEmpty) // Final states/times remain; creation/edit trails do not.
        let ids = Set(try store!.loadProjects().map(\.id))
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(try store!.loadDraft()?.notes, "unsaved note")
        XCTAssertEqual(try store!.loadDraft()?.projectID, LegacyDataMigration.projectID(for: "work"))
        store = nil
        store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        XCTAssertEqual(Set(try store!.loadProjects().map(\.id)), ids)
        XCTAssertEqual(try store!.archive().records.count, output.records.count)
        let backups = try FileManager.default.contentsOfDirectory(at: AppPaths(root: root).backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.filter { $0.lastPathComponent.hasPrefix("before-upgrade-") }.count, 1)
        store = nil
        // The retained pre-upgrade file really decodes with the frozen legacy DTO.
        let snapshot = backups.first { $0.lastPathComponent.hasPrefix("before-upgrade-") }!
        let schema = Schema(versionedSchema: StoreSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: snapshot.appendingPathComponent("PinDo.store"), cloudKitDatabase: .none)])
        let rows = try ModelContext(container).fetch(FetchDescriptor<StoreRecord>()).filter { $0.bucket.hasPrefix("todo-") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(try rows.map { try JSONDecoder().decode(LegacyDataMigration.Item.self, from: $0.payload) }.contains { $0.category?.id == "work" })
    }
    @MainActor func testHistoryOnlyAndLegacyBackupImportKeepAssociations() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let records = try legacyRecords(historyOnly: true)
        var old = StoreArchive(appVersion: "0.1.0", createdAt: .now, records: records); old.formatVersion = 1
        let first = try BackupCodec.decode(BackupCodec.encode(old)), second = try old.upgraded()
        let ids = Set(first.records.filter { $0.bucket == "project" }.map(\.key))
        XCTAssertEqual(ids, Set(second.records.filter { $0.bucket == "project" }.map(\.key)))
        let store = try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0")
        try store.restore(first)
        XCTAssertTrue(try store.loadActiveItems().isEmpty)
        XCTAssertEqual(try store.loadProjects().count, 2)
        XCTAssertEqual(try store.archive().records.filter { $0.bucket.hasPrefix("todo-") }.count, 2)
        try store.archive().validate()
    }
    @MainActor func testInterruptedMigrationBeforeAndAfterCommitResumes() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try writeLegacy(legacyRecords(), root: root)
        let paths = AppPaths(root: root), snapshot = paths.backups.appendingPathComponent("before-upgrade-interrupted", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try DatabaseSnapshot.copy(from: paths.store, to: snapshot.appendingPathComponent("PinDo.store"))
        try FileManager.default.copyItem(at: paths.manifest, to: snapshot.appendingPathComponent("StoreInfo.json"))
        var manifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: paths.manifest))
        manifest.formatVersion = 2; manifest.lastAppVersion = "0.2.0"; manifest.migrationPending = true; manifest.upgradeSnapshot = snapshot.lastPathComponent
        try JSONEncoder().encode(manifest).write(to: paths.manifest)
        var store: TodoRepository? = try TodoRepository(paths: paths, appVersion: "0.2.0")
        let ids = Set(try store!.loadProjects().map(\.id)); store = nil
        // Simulate the DB having committed while final manifest replacement was interrupted.
        try JSONEncoder().encode(manifest).write(to: paths.manifest)
        store = try TodoRepository(paths: paths, appVersion: "0.2.0")
        XCTAssertEqual(Set(try store!.loadProjects().map(\.id)), ids)
        XCTAssertNil(try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: paths.manifest)).migrationPending)
        XCTAssertEqual(try store!.loadDraft()?.notes, "unsaved note")
    }
    @MainActor func testOrphanDataAndInvalidBackupNeverCreateEmptyReplacement() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("orphan".utf8).write(to: root.appendingPathComponent("PinDo.store-wal"))
        XCTAssertThrowsError(try TodoRepository(paths: AppPaths(root: root), appVersion: "0.2.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths(root: root).store.path))
        var broken = StoreArchive(appVersion: "0.1.0", createdAt: .now, records: [StoredValue(key: "bad", bucket: "unknown", payload: Data())])
        broken.formatVersion = 1
        XCTAssertThrowsError(try broken.upgraded())
    }
}
