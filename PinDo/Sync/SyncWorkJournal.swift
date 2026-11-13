import Foundation

/// The bytes at a work URL never change. A later operation necessarily uses another URL.
struct SyncWorkFile {
    enum Kind: String { case intent, payload }
    let owner: UUID
    let digest: String
    let kind: Kind
    init(owner: UUID, data: Data, kind: Kind) {
        self.owner = owner; digest = SyncCodec.hash(data); self.kind = kind
    }
    init?(path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "_work" else { return nil }
        let fields = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[3] == "json", let owner = UUID(uuidString: String(fields[0])),
              owner.uuidString.lowercased() == fields[0], let kind = Kind(rawValue: String(fields[2])),
              fields[1].count == 64, fields[1].allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        self.owner = owner; digest = String(fields[1]); self.kind = kind
    }
    var path: String { "_work/" + owner.uuidString.lowercased() + "." + digest + "." + kind.rawValue + ".json" }
    func validate(_ data: Data) throws {
        guard SyncCodec.hash(data) == digest else { throw SyncFailure.configuration("工作文件内容与路径摘要不符，已保留原内容等待修复。") }
    }
}

struct SyncWorkIntent: Codable, Sendable {
    var version = 3
    let libraryID: UUID
    let mutation: SyncMutation
    let digest: String

    init(libraryID: UUID, mutation: SyncMutation) throws {
        self.libraryID = libraryID; self.mutation = mutation
        digest = try SyncCodec.hash(SyncCodec.encode(mutation))
    }
    func validate(library: UUID, owner: UUID) throws {
        guard version == 3, libraryID == library, mutation.writerID == owner, mutation.sequence > 0,
              SyncCurrent.validEntity(mutation.entity), (!mutation.change.writes.isEmpty || !mutation.change.assignments.isEmpty),
              mutation.change.writes.allSatisfy({ $0.entity == mutation.entity }),
              digest == (try SyncCodec.hash(SyncCodec.encode(mutation))) else { throw SyncFailure.invalidData }
        for write in mutation.change.writes { try SyncGraph.validate(write) }
    }
    func encoded() throws -> Data { try SyncCurrent.encoded(self, limit: 16 * 1024 * 1024) }
    func path() throws -> String { SyncWorkFile(owner: mutation.writerID, data: try encoded(), kind: .intent).path }
}

extension SyncCoordinator {
    func publishWork(_ mutation: SyncMutation, dav: any DAVTransport, library: UUID) async throws -> SyncEntityRecord {
        let intent = try SyncWorkIntent(libraryID: library, mutation: mutation)
        let path = try intent.path()
        let target = try await dav.get(SyncCurrent.path(mutation.entity))
        if target.status == 200 {
            let record = try decodeCurrent(target, entity: mutation.entity, library: library)
            if record.receipts[mutation.writerID.uuidString.lowercased(), default: 0] >= mutation.sequence {
                _ = try SyncCurrent.merging(mutation, into: record) // Requires the exact operation, not just its number.
                try await advertiseCurrent([record], dav: dav, library: library)
                try await cleanWork(intent, dav: dav, library: library)
                return record
            }
        } else if target.status != 404 { throw SyncFailure.http(target.status) }
        let current = try await dav.get(path)
        if current.status == 404 {
            try await dav.create(path, data: intent.encoded())
        } else {
            guard let file = SyncWorkFile(path: path) else { throw SyncFailure.invalidData }
            try file.validate(current.data)
            let stored = try decodeWork(current, library: library, owner: mutation.writerID)
            guard stored.mutation.id == intent.mutation.id, stored.digest == intent.digest else { throw SyncFailure.identityCollision }
        }
        return try await finishWork(intent, dav: dav, library: library)
    }

    func decodeWork(_ response: DAVResponse, library: UUID, owner: UUID) throws -> SyncWorkIntent {
        guard response.status == 200 else { throw SyncFailure.http(response.status) }
        guard response.data.count <= 16 * 1024 * 1024 else { throw SyncFailure.invalidData }
        let intent = try SyncCodec.unwrap(SyncWorkIntent.self, response.data)
        try intent.validate(library: library, owner: owner)
        return intent
    }

    /// Every record write, including recovery by another device, uses the same merge and confirmation path.
    func finishWork(_ intent: SyncWorkIntent, dav: any DAVTransport, library: UUID) async throws -> SyncEntityRecord {
        let record = try await publishCurrent(intent.mutation, dav: dav, library: library)
        try await advertiseCurrent([record], dav: dav, library: library)
        try await cleanWork(intent, dav: dav, library: library)
        return record
    }

    func cleanWork(_ intent: SyncWorkIntent, dav: any DAVTransport, library: UUID) async throws {
        let path = try intent.path()
        let current = try await dav.get(path)
        if current.status == 200 {
            let stored = try decodeWork(current, library: library, owner: intent.mutation.writerID)
            if stored.mutation.id != intent.mutation.id || stored.digest != intent.digest { return }
        } else if current.status != 404 { throw SyncFailure.http(current.status) }
        if current.status == 200, try await !dav.deleteWorkFile(path, response: current) { try repository?.noteCleanup(true) }
    }

    func recoverCloudWork(_ dav: any DAVTransport, library: UUID) async throws {
        _ = try await readCurrentIndex(dav, library: library)
        let owner = try repository!.syncState()!.writerID
        let names = try await dav.children("_work")
        let intents = names.filter { $0.hasSuffix(".intent.json") }.sorted {
            let left = $0.hasPrefix(owner.uuidString.lowercased()), right = $1.hasPrefix(owner.uuidString.lowercased())
            return left == right ? $0 < $1 : left
        }
        // Bound work per round without treating an incomplete scan as permission to delete anything.
        guard intents.count <= 64 else { throw SyncFailure.incompleteListing }
        for name in intents {
            let path = "_work/" + name
            guard let file = SyncWorkFile(path: path), file.kind == .intent else { throw SyncFailure.configuration("工作区包含旧格式或无法识别的工作意图，已保留原文件。") }
            let response = try await dav.get(path)
            if response.status == 404 { continue }
            try file.validate(response.data)
            let intent = try decodeWork(response, library: library, owner: file.owner)
            let record = try await finishWork(intent, dav: dav, library: library)
            // Also clean the exact received bytes, even if a peer used another valid JSON layout.
            _ = try await dav.deleteWorkFile(path, response: response)
            try repository?.stageCurrent([record])
            if file.owner == owner { try repository?.acknowledgeCurrent(intent.mutation) }
        }
        for name in names where name.hasSuffix(".payload.json") {
            let path = "_work/" + name
            guard let file = SyncWorkFile(path: path), file.kind == .payload else { throw SyncFailure.configuration("工作区包含旧格式或无法识别的上传内容，已保留原文件。") }
            let response = try await dav.get(path)
            if response.status == 404 { continue }
            guard response.status == 200 else { throw SyncFailure.http(response.status) }
            try file.validate(response.data)
            if let intent = try? SyncCodec.unwrap(SyncWorkIntent.self, response.data) {
                try intent.validate(library: library, owner: intent.mutation.writerID)
                // The MOVE creating the intent may have been interrupted; the payload itself is recoverable.
                let record = try await finishWork(intent, dav: dav, library: library)
                try repository?.stageCurrent([record])
                if intent.mutation.writerID == owner { try repository?.acknowledgeCurrent(intent.mutation) }
                _ = try await dav.deleteWorkFile(path, response: response)
            } else if let candidate = try? SyncCodec.unwrap(SyncEntityRecord.self, response.data), candidate.version == 3,
                      candidate.libraryID == library, let publication = candidate.publication {
                let key = publication.writerID.uuidString.lowercased()
                let latest = try decodeCurrent(await dav.get(SyncCurrent.path(candidate.entity)), entity: candidate.entity, library: library)
                let confirmed = latest.receipts[key, default: 0]
                guard confirmed >= publication.receipt.sequence else {
                    throw SyncFailure.configuration("工作区存在尚未确认的上传内容，已保留等待恢复。")
                }
                if confirmed == publication.receipt.sequence {
                    guard latest.receiptOperations?[key] == publication.receipt else { throw SyncFailure.identityCollision }
                }
                try await advertiseCurrent([latest], dav: dav, library: library)
                _ = try await dav.deleteWorkFile(path, response: response)
            } else if let root = try? SyncCodec.unwrap(SyncLibrary.self, response.data), [3, 4].contains(root.version) {
                _ = try await dav.deleteWorkFile(path, response: response)
            } else if let index = try? SyncCodec.unwrap(SyncCurrentIndex.self, response.data), index.version == 3, index.libraryID == library, index.records.isEmpty {
                _ = try await dav.deleteWorkFile(path, response: response)
            } else { throw SyncFailure.configuration("工作区包含无法校验的上传内容，已保留原文件。") }
        }
        for name in names where name.contains(".probe-") && name.hasSuffix(".json") {
            let response = try await dav.get("_work/" + name)
            if response.status == 404 { continue }
            guard response.status == 200 else { throw SyncFailure.http(response.status) }
            guard let marker = try? SyncCodec.decode(SyncProbeMarker.self, response.data), marker.kind == "pindo-probe-v3",
                  ["a", "b", "c"].contains(where: { name == marker.owner.uuidString.lowercased() + ".probe-" + $0 + ".json" }) else {
                throw SyncFailure.configuration("工作区探测文件无法验证，已保留原内容等待修复。")
            }
            // Only verified non-business probes use a time window. Clock jumps cannot strand them forever.
            guard abs(marker.createdAt.timeIntervalSinceNow) > 120 else { continue }
            _ = try await dav.deleteProbe("_work/" + name, response: response)
        }
        let remaining = try await dav.children("_work")
        try repository?.noteCleanup(remaining.contains { $0.hasSuffix(".intent.json") || $0.hasSuffix(".payload.json") })
    }
}
