import CryptoKit
import Foundation
import SwiftData

struct StoredValue: Codable, Sendable {
    let key: String
    let bucket: String
    let payload: Data
}

struct StoreArchive: Codable, Sendable {
    var formatVersion: Int = 1
    let appVersion: String
    let createdAt: Date
    let records: [StoredValue]

    func validate() throws {
        guard formatVersion == 1 else { throw StoreFailure.unsupportedVersion }
        guard Set(records.map(\.key)).count == records.count else { throw StoreFailure.invalidBackup }
        let decoder = JSONDecoder()
        var itemIDs = Set<UUID>()
        var events: [TodoEvent] = []
        var drafts = 0
        for record in records {
            if record.bucket.hasPrefix("todo-") {
                let item = try decoder.decode(TodoItem.self, from: record.payload)
                try Self.validate(item)
                guard record.key == "todo:\(item.id.uuidString)", record.bucket == "todo-\(item.status.rawValue)" else { throw StoreFailure.invalidBackup }
                itemIDs.insert(item.id)
            } else if record.bucket == "event" {
                let event = try decoder.decode(TodoEvent.self, from: record.payload)
                guard record.key == "event:\(event.id.uuidString)" else { throw StoreFailure.invalidBackup }
                events.append(event)
            } else if record.bucket == "draft" {
                let draft = try decoder.decode(NoteDraft.self, from: record.payload)
                guard record.key == "editor-draft", (1...3).contains(draft.stars) else { throw StoreFailure.invalidBackup }
                drafts += 1
            } else {
                throw StoreFailure.invalidBackup
            }
        }
        guard drafts <= 1, events.allSatisfy({ itemIDs.contains($0.itemID) }) else { throw StoreFailure.invalidBackup }
        let completionIDs = Set(events.filter { $0.kind == .completed }.map(\.id))
        for event in events where event.kind == .completionUndone {
            guard let related = event.relatedCompletionID, completionIDs.contains(related) else { throw StoreFailure.invalidBackup }
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
            guard item.completedAt != nil, item.abandonedAt == nil else { throw StoreFailure.invalidItem }
        case .abandoned:
            guard item.abandonedAt != nil, item.completedAt == nil else { throw StoreFailure.invalidItem }
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
        try archive.validate()
        return archive
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
        let data = try BackupCodec.encode(StoreArchive(appVersion: appVersion, createdAt: .now, records: records))
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: .now)
        let name = String(format: "daily-%04d-%02d-%02d.pindobackup", parts.year!, parts.month!, parts.day!)
        // Atomic replacement refreshes today's backup rather than accumulating files per edit.
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        let daily = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("daily-") && $0.pathExtension == "pindobackup" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for expired in daily.dropFirst(7) { try FileManager.default.removeItem(at: expired) }
    }
}

