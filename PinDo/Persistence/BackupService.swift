import CryptoKit
import Foundation
import SwiftData
import Darwin

struct StoredValue: Codable, Sendable {
    let key: String
    let bucket: String
    let payload: Data
}

struct StoreArchive: Codable, Sendable {
    var formatVersion: Int = 2
    let appVersion: String
    let createdAt: Date
    let records: [StoredValue]

    func upgraded() throws -> StoreArchive {
        if formatVersion == 1 { return try LegacyDataMigration.convert(self) }
        try validate()
        return self
    }

    func validate() throws {
        if formatVersion == 1 { _ = try LegacyDataMigration.convert(self); return }
        guard [2, 3].contains(formatVersion) else { throw StoreFailure.unsupportedVersion }
        guard Set(records.map(\.key)).count == records.count else { throw StoreFailure.invalidBackup }
        let decoder = JSONDecoder()
        var items: [UUID: TodoItem] = [:], projects: [UUID: Project] = [:]
        var events: [TodoEvent] = []
        var draft: NoteDraft?
        var metadata = 0
        var syncRecords = 0
        var syncProjection: (items: [TodoItem], projects: [Project], events: [TodoEvent])?
        for record in records {
            switch record.bucket {
            case "todo-active", "todo-completed", "todo-abandoned", "todo-conflicted":
                let item = try decoder.decode(TodoItem.self, from: record.payload)
                try Self.validate(item)
                guard record.key == "todo:\(item.id.uuidString)", record.bucket == "todo-\(item.status.rawValue)" else { throw StoreFailure.invalidBackup }
                items[item.id] = item
            case "project":
                let project = try decoder.decode(Project.self, from: record.payload)
                try Self.validate(project)
                guard record.key == "project:\(project.id.uuidString)" else { throw StoreFailure.invalidBackup }
                projects[project.id] = project
            case "event":
                let event = try decoder.decode(TodoEvent.self, from: record.payload)
                guard record.key == "event:\(event.id.uuidString)", event.occurredAt.timeIntervalSince1970.isFinite else { throw StoreFailure.invalidBackup }
                events.append(event)
            case "draft":
                guard record.key == "editor-draft", draft == nil else { throw StoreFailure.invalidBackup }
                draft = try decoder.decode(NoteDraft.self, from: record.payload)
            case "sync-state":
                guard formatVersion == 3, record.key == "sync-state" else { throw StoreFailure.invalidBackup }
                let state = try JSONDecoder().decode(SyncState.self, from: record.payload)
                guard state.version == 1 else { throw StoreFailure.unsupportedVersion }
                syncProjection = try SyncGraph(state.changes).projection()
                syncRecords += 1
            case "storage-meta":
                guard record.key == "storage-meta", try decoder.decode(StoreMetadata.self, from: record.payload).formatVersion == formatVersion else { throw StoreFailure.unsupportedVersion }
                metadata += 1
            default: throw StoreFailure.invalidBackup
            }
        }
        guard metadata == 1, syncRecords == (formatVersion == 3 ? 1 : 0) else { throw StoreFailure.invalidBackup }
        for item in items.values {
            if let id = item.projectID {
                guard let project = projects[id], item.status != .active || project.status == .active else { throw StoreFailure.invalidBackup }
            }
            for assignment in item.projectAssignments {
                guard (assignment.changedAt?.timeIntervalSince1970.isFinite ?? true),
                      assignment.previousProjectID.map({ projects[$0] != nil }) ?? true,
                      assignment.projectID.map({ projects[$0] != nil }) ?? true else { throw StoreFailure.invalidBackup }
            }
        }
        if let draft {
            guard (1...3).contains(draft.stars), draft.dueAt.timeIntervalSince1970.isFinite,
                  draft.projectID.map({ formatVersion == 3 ? projects[$0] != nil : projects[$0]?.status == .active }) ?? true,
                  draft.isNew || items[draft.id] != nil else { throw StoreFailure.invalidBackup }
        }
        if let projection = syncProjection {
            func encodedItems(_ values: [TodoItem]) throws -> Data { try SyncCodec.encode(values.sorted { $0.id.uuidString < $1.id.uuidString }) }
            func encodedProjects(_ values: [Project]) throws -> Data { try SyncCodec.encode(values.sorted { $0.id.uuidString < $1.id.uuidString }) }
            func encodedEvents(_ values: [TodoEvent]) throws -> Data { try SyncCodec.encode(values.sorted { $0.id.uuidString < $1.id.uuidString }) }
            guard try encodedItems(Array(items.values)) == encodedItems(projection.items),
                  try encodedProjects(Array(projects.values)) == encodedProjects(projection.projects),
                  try encodedEvents(events) == encodedEvents(projection.events) else { throw StoreFailure.invalidBackup }
        }
        guard events.allSatisfy({ items[$0.itemID] != nil }) else { throw StoreFailure.invalidBackup }
        let completed = Dictionary(uniqueKeysWithValues: events.filter { $0.kind == .completed }.map { ($0.id, $0.itemID) })
        for event in events where event.kind == .completionUndone {
            guard let related = event.relatedCompletionID, completed[related] == event.itemID else { throw StoreFailure.invalidBackup }
        }
    }

    static func validate(_ project: Project) throws {
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [project.red, project.green, project.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              project.createdAt.timeIntervalSince1970.isFinite, project.updatedAt.timeIntervalSince1970.isFinite else { throw StoreFailure.invalidProject }
        switch project.status {
        case .active: guard project.archivedAt == nil, project.deletedAt == nil else { throw StoreFailure.invalidProject }
        case .archived: guard project.archivedAt != nil, project.deletedAt == nil else { throw StoreFailure.invalidProject }
        case .deleted: guard project.deletedAt != nil else { throw StoreFailure.invalidProject }
        }
    }

    static func validate(_ item: TodoItem) throws {
        guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...3).contains(item.stars), item.createdAt.timeIntervalSince1970.isFinite,
              item.updatedAt.timeIntervalSince1970.isFinite,
              item.dueAt?.timeIntervalSince1970.isFinite ?? true else { throw StoreFailure.invalidItem }
        switch item.status {
        case .active:
            guard item.completedAt == nil, item.abandonedAt == nil else { throw StoreFailure.invalidItem }
        case .completed:
            guard item.completedAt?.timeIntervalSince1970.isFinite == true, item.abandonedAt == nil else { throw StoreFailure.invalidItem }
        case .conflicted:
            guard item.completedAt == nil, item.abandonedAt == nil else { throw StoreFailure.invalidItem }
        case .abandoned:
            guard item.abandonedAt?.timeIntervalSince1970.isFinite == true, item.completedAt == nil else { throw StoreFailure.invalidItem }
        }
    }
}

enum BackupCodec {
    private struct Envelope: Codable {
        let formatVersion: Int
        let checksum: String
        let payload: Data
    }

    static func encode(_ archive: StoreArchive) throws -> Data {
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(archive)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return try encoder.encode(Envelope(formatVersion: 1, checksum: checksum, payload: payload))
    }

    static func decode(_ data: Data) throws -> StoreArchive {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.formatVersion == 1 else { throw StoreFailure.unsupportedVersion }
        let checksum = SHA256.hash(data: envelope.payload).map { String(format: "%02x", $0) }.joined()
        guard checksum == envelope.checksum else { throw StoreFailure.invalidBackup }
        let archive = try JSONDecoder().decode(StoreArchive.self, from: envelope.payload)
        return try archive.upgraded()
    }
}

/// A storage-confined background executor, equivalent to the public ModelActor expansion.
actor BackupService: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    init(container: ModelContainer) {
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    func writeAutomaticBackup(to directory: URL, appVersion: String) throws {
        try Task.checkCancellation()
        // A fresh reader avoids reusing objects cached before another context's last commit.
        let snapshotContext = ModelContext(modelContainer)
        snapshotContext.autosaveEnabled = false
        let records = try snapshotContext.fetch(FetchDescriptor<StoreRecord>()).map {
            StoredValue(key: $0.key, bucket: $0.bucket, payload: $0.payload)
        }
        var archive = StoreArchive(appVersion: appVersion, createdAt: .now, records: records)
        archive.formatVersion = records.contains { $0.bucket == "sync-state" } ? 3 : 2
        let data = try BackupCodec.encode(archive)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("recovery.latest.pindobackup")
        try StorageMaintenance.atomicWrite(data, to: destination)
        let verified = try Data(contentsOf: destination)
        guard verified == data else { throw StoreFailure.invalidBackup }
        _ = try BackupCodec.decode(verified)
        try StorageMaintenance.removeReplacedBackups(in: directory)
    }
}

enum StorageMaintenance {
    /// One reserved pending name per destination, so a process crash cannot accumulate random temp files.
    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let pending = destination.appendingPathExtension("pending")
        var descriptor = Darwin.open(pending.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        Darwin.close(descriptor); descriptor = -1
        guard try Data(contentsOf: pending) == data else { throw StoreFailure.inconsistentStore }
        guard Darwin.rename(pending.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let parent = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY)
        if parent >= 0 { _ = Darwin.fsync(parent); Darwin.close(parent) }
    }

    static func recoverManifest(_ destination: URL) throws {
        let files = FileManager.default, pending = destination.appendingPathExtension("pending")
        guard files.fileExists(atPath: pending.path) else { return }
        guard try pending.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw StoreFailure.inconsistentStore }
        let staged = try? JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: pending))
        if files.fileExists(atPath: destination.path) {
            let current = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: destination))
            if let staged {
                guard staged.storeID == current.storeID else { throw StoreFailure.inconsistentStore }
                if staged.lastAppVersion.compare(current.lastAppVersion, options: .numeric) != .orderedAscending && staged.formatVersion >= current.formatVersion {
                    guard Darwin.rename(pending.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    return
                }
            }
            try files.removeItem(at: pending) // The valid final manifest is authoritative over an incomplete marker.
        } else {
            guard staged != nil else { throw StoreFailure.inconsistentStore }
            guard Darwin.rename(pending.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }
    /// Called only after the replacement recovery archive has been read and fully validated.
    static func removeReplacedBackups(in directory: URL) throws {
        let files = FileManager.default, root = directory.deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(StoreManifest.self, from: Data(contentsOf: root.appendingPathComponent("StoreInfo.json")))
        guard manifest.migrationPending != true, manifest.upgradeSnapshot == nil else { return }
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) {
            let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard info.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            let daily = name.range(of: "^daily-[0-9]{4}-[0-9]{2}-[0-9]{2}\\.pindobackup$", options: .regularExpression) != nil
            if info.isRegularFile == true && (daily || ["before-sync.pindobackup", "before-restore.pindobackup", "before-sync.pindobackup.pending", "before-restore.pindobackup.pending"].contains(name)) {
                try files.removeItem(at: url)
            } else if info.isDirectory == true, name.hasPrefix("before-upgrade-"), UUID(uuidString: String(name.dropFirst("before-upgrade-".count))) != nil {
                let children = try files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])
                if children.isEmpty { try files.removeItem(at: url); continue }
                guard Set(children.map(\.lastPathComponent)).isSubset(of: ["PinDo.store", "PinDo.store-wal", "PinDo.store-shm", "PinDo.store-journal", "StoreInfo.json"]),
                      try children.allSatisfy({ try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true }) else { continue }
                guard let bytes = try? Data(contentsOf: url.appendingPathComponent("StoreInfo.json")), let previous = try? JSONDecoder().decode(StoreManifest.self, from: bytes) else { continue }
                guard previous.storeID == manifest.storeID else { continue }
                try files.removeItem(at: url)
            }
        }
    }
}

