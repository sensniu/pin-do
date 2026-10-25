import Darwin
import Foundation
import SwiftData

@MainActor
protocol TodoPersisting: AnyObject {
    func commit(_ item: TodoItem, event: TodoEvent, clearDraft: Bool) throws
    func saveDraft(_ draft: NoteDraft?) throws
}

@MainActor
final class TodoRepository: TodoPersisting {
    let paths: AppPaths
    private let container: ModelContainer
    private let context: ModelContext
    private let backupService: Task<BackupService, Never>
    private let lockDescriptor: Int32
    private let appVersion: String
    private var backupTask: Task<Void, Never>?
    var onBackupFailure: ((String) -> Void)?

    init(paths: AppPaths, appVersion: String) throws {
        self.paths = paths
        self.appVersion = appVersion
        let files = FileManager.default
        try files.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(paths.root.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw StoreFailure.inconsistentStore }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw StoreFailure.alreadyOpen
        }
        do {
            let storeExists = files.fileExists(atPath: paths.store.path)
            let manifestExists = files.fileExists(atPath: paths.manifest.path)
            guard storeExists == manifestExists else { throw StoreFailure.inconsistentStore }
            var manifest: StoreManifest
            if manifestExists {
                manifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: paths.manifest))
                guard manifest.formatVersion == 1 else { throw StoreFailure.unsupportedVersion }
                guard appVersion.compare(manifest.lastAppVersion, options: .numeric) != .orderedAscending else {
                    throw StoreFailure.unsupportedVersion
                }
                if manifest.lastAppVersion != appVersion {
                    try Self.backupClosedStore(paths: paths)
                }
            } else {
                manifest = StoreManifest(storeID: UUID(), createdAt: .now, lastAppVersion: appVersion)
            }
            let schema = Schema(versionedSchema: StoreSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: paths.store, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, migrationPlan: StoreMigrationPlan.self, configurations: [configuration])
            self.container = container
            self.context = ModelContext(container)
            self.context.autosaveEnabled = false
            self.backupService = Task.detached(priority: .utility) { BackupService(container: container) }
            manifest.lastAppVersion = appVersion
            try JSONEncoder().encode(manifest).write(to: paths.manifest, options: .atomic)
            self.lockDescriptor = descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit {
        backupTask?.cancel()
        close(lockDescriptor)
    }

    func loadActiveItems() throws -> [TodoItem] {
        try records(in: "todo-active").map { record in
            let item = try JSONDecoder().decode(TodoItem.self, from: record.payload)
            try StoreArchive.validate(item)
            guard record.key == "todo:\(item.id.uuidString)", item.status == .active else { throw StoreFailure.inconsistentStore }
            return item
        }
    }

    func loadDraft() throws -> NoteDraft? {
        guard let row = try record(key: "editor-draft") else { return nil }
        let draft = try JSONDecoder().decode(NoteDraft.self, from: row.payload)
        guard (1...3).contains(draft.stars) else { throw StoreFailure.inconsistentStore }
        return draft
    }

    func commit(_ item: TodoItem, event: TodoEvent, clearDraft: Bool) throws {
        try StoreArchive.validate(item)
        guard event.itemID == item.id else { throw StoreFailure.invalidItem }
        do {
            let key = "todo:\(item.id.uuidString)"
            let existing = try record(key: key)
            if event.kind == .created {
                guard existing == nil else { throw StoreFailure.staleItem }
            } else {
                guard let existing else { throw StoreFailure.staleItem }
                let prior = try JSONDecoder().decode(TodoItem.self, from: existing.payload)
                let required: TodoStatus = event.kind == .completionUndone ? .completed : .active
                guard prior.status == required else { throw StoreFailure.staleItem }
            }
            guard try record(key: "event:\(event.id.uuidString)") == nil else { throw StoreFailure.staleItem }
            let payload = try JSONEncoder().encode(item)
            if let existing {
                existing.payload = payload
                existing.bucket = "todo-\(item.status.rawValue)"
            } else {
                context.insert(StoreRecord(key: key, bucket: "todo-\(item.status.rawValue)", payload: payload))
            }
            context.insert(StoreRecord(key: "event:\(event.id.uuidString)", bucket: "event", payload: try JSONEncoder().encode(event)))
            if clearDraft, let draft = try record(key: "editor-draft") { context.delete(draft) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        scheduleBackup()
    }

    func saveDraft(_ draft: NoteDraft?) throws {
        do {
            let row = try record(key: "editor-draft")
            if let draft {
                let payload = try JSONEncoder().encode(draft)
                if let row { row.payload = payload }
                else { context.insert(StoreRecord(key: "editor-draft", bucket: "draft", payload: payload)) }
            } else if let row { context.delete(row) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func archive() throws -> StoreArchive {
        let records = try context.fetch(FetchDescriptor<StoreRecord>()).map {
            StoredValue(key: $0.key, bucket: $0.bucket, payload: $0.payload)
        }
        let archive = StoreArchive(appVersion: appVersion, createdAt: .now, records: records)
        try archive.validate()
        return archive
    }

    func restore(_ archive: StoreArchive) throws {
        try archive.validate()
        // A verified pre-restore logical backup must succeed before changing any record.
        let before = try BackupCodec.encode(self.archive())
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try before.write(to: paths.backups.appendingPathComponent("before-restore.pindobackup"), options: .atomic)
        do {
            for row in try context.fetch(FetchDescriptor<StoreRecord>()) { context.delete(row) }
            for record in archive.records {
                context.insert(StoreRecord(key: record.key, bucket: record.bucket, payload: record.payload))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        scheduleBackup()
    }

    func createAutomaticBackupNow() async throws {
        backupTask?.cancel()
        let worker = await backupService.value
        try await worker.writeAutomaticBackup(to: paths.backups, appVersion: appVersion)
    }

    private func records(in bucket: String) throws -> [StoreRecord] {
        let predicate = Predicate<StoreRecord> { row in
            PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: row, keyPath: \StoreRecord.bucket),
                rhs: PredicateExpressions.build_Arg(bucket)
            )
        }
        return try context.fetch(FetchDescriptor(predicate: predicate))
    }

    private func record(key: String) throws -> StoreRecord? {
        let predicate = Predicate<StoreRecord> { row in
            PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: row, keyPath: \StoreRecord.key),
                rhs: PredicateExpressions.build_Arg(key)
            )
        }
        let matches = try context.fetch(FetchDescriptor(predicate: predicate))
        guard matches.count <= 1 else { throw StoreFailure.inconsistentStore }
        return matches.first
    }

    private func scheduleBackup() {
        backupTask?.cancel()
        let factory = backupService
        let directory = paths.backups
        let version = appVersion
        backupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                let worker = await factory.value
                try Task.checkCancellation()
                try await worker.writeAutomaticBackup(to: directory, appVersion: version)
            } catch is CancellationError {
                return
            } catch {
                self?.onBackupFailure?(error.localizedDescription)
            }
        }
    }

    private static func backupClosedStore(paths: AppPaths) throws {
        let files = FileManager.default
        let directory = paths.backups.appendingPathComponent("before-upgrade-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try DatabaseSnapshot.copy(from: paths.store, to: directory.appendingPathComponent("PinDo.store"))
            try files.copyItem(at: paths.manifest, to: directory.appendingPathComponent("StoreInfo.json"))
            let previous = try files.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("before-upgrade-") }
                .sorted {
                    let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return left > right
                }
            for expired in previous.dropFirst(3) { try files.removeItem(at: expired) }
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }
}

