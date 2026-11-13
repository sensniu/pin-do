import Foundation
import CryptoKit

/// Platform-independent wire encoding. Hash the original bytes, never a re-encoding.
enum SyncCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            guard date.timeIntervalSince1970.isFinite else { throw SyncFailure.invalidData }
            var container = encoder.singleValueContainer()
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(format.string(from: date))
        }
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = format.date(from: text), text.hasSuffix("Z") else { throw SyncFailure.invalidData }
            return date
        }
        return try decoder.decode(type, from: data)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func wrap<T: Encodable>(_ value: T) throws -> Data {
        let bytes = try encode(value)
        return try encode(Envelope(version: 1, checksum: hash(bytes), payload: bytes))
    }
    static func unwrap<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let envelope = try decode(Envelope.self, data)
        guard envelope.version == 1, hash(envelope.payload) == envelope.checksum else { throw SyncFailure.invalidData }
        return try decode(type, envelope.payload)
    }
    private struct Envelope: Codable { let version: Int; let checksum: String; let payload: Data }
}

enum SyncFailure: LocalizedError {
    case invalidData, missingDependency, identityCollision, unsupported, incompleteListing, unsafeServer, wrongLibrary
    case http(Int), throttled(TimeInterval), configuration(String)
    case serverCapability(stage: String, detail: String, status: Int?)
    var errorDescription: String? {
        switch self {
        case .invalidData: "同步数据校验失败，本地内容已保留。"
        case .missingDependency: "同步数据尚不完整，等待其他设备的关联变更。"
        case .identityCollision: "检测到重复身份或同一版本内容不同，已停止覆盖。"
        case .unsupported: "此同步数据需要更新版本，已暂停同步。"
        case .incompleteListing: "服务器目录结果可能不完整，已停止同步，避免遗漏数据。"
        case .unsafeServer: "服务器未通过条件写入校验，无法安全开启同步。"
        case .serverCapability(let stage, let detail, let status):
            "WebDAV 兼容性检查未通过（\(stage)\(status.map { "，HTTP \($0)" } ?? "")）：\(detail) 本地内容已保留。"
        case .wrongLibrary: "目录对应的同步库已变化，请检查配置。本地数据已保留。"
        case .throttled: "服务器要求稍后重试，待发送内容已保留。"
        case .http(let status): "WebDAV 请求失败（HTTP \(status)），本地内容和待同步变更已保留。"
        case .configuration(let message): message
        }
    }
}

struct SyncWrite: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    let entity: String
    let field: String
    let parents: [UUID]
    let value: Data
    var modifiedAt: Date? = nil
    var key: String { entity + "/" + field }
}
struct SyncChange: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    let writerID: UUID
    let date: Date
    var writes: [SyncWrite]
    var events: [TodoEvent] = []
    var assignments: [SyncAssignment] = []
    var endedEdits: [UUID]? = nil
}
struct SyncAssignment: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let itemID: UUID
    let value: ProjectAssignment
}
struct SyncLife: Codable, Equatable, Sendable {
    let status: String
    let date: Date?
    var generation: SyncGeneration? = nil
    var retired: [String: Int]? = nil
    var transition: SyncGeneration? = nil
    var observed: [String: Int]? = nil
}
struct SyncGeneration: Codable, Equatable, Sendable {
    let writer: UUID
    let counter: Int
}
struct SyncMembership: Codable, Equatable, Sendable {
    let projectID: UUID?
    let generation: UUID?
    var generationDot: SyncGeneration? = nil
}
struct SyncIdentity: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date? = nil
}
struct SyncCursor: Codable, Equatable, Sendable {
    var sequence: Int = 0
    var checksum: String = ""
}
struct SyncPacket: Codable, Sendable {
    var version = 1
    let libraryID: UUID
    let writerID: UUID
    let sequence: Int
    let previous: String
    let changes: [SyncChange]
}
struct SyncLibrary: Codable, Sendable { var version = 3; let id: UUID }
struct SyncHead: Codable, Sendable {
    var version = 1
    let libraryID: UUID
    let writerID: UUID
    let cursor: SyncCursor
}
struct SyncConflict: Identifiable, Sendable {
    let entity: String
    let field: String
    let candidates: [SyncWrite]
    var id: String { entity + "/" + field }
    var fieldLabel: String {
        ["title": "标题", "notes": "备注", "deadline": "截止时间", "stars": "重要程度", "membership": "项目归属", "lifecycle": "状态", "name": "项目名称", "color": "项目颜色", "identity": "来源身份"][field] ?? field
    }
}
struct SyncState: Codable, Sendable {
    var version = 1
    var writerID = UUID()
    var libraryID: UUID?
    var proposedLibraryID: UUID?
    var connection: SyncConnection?
    var remoteCreationMode: DAVCreationMode?
    var remoteSafetyVersion: Int?
    var enabled = false
    var changes: [SyncChange] = []
    var published: Set<UUID> = []
    var outboxIDs: Set<UUID> = []
    var cursors: [String: SyncCursor] = [:]
    var received: [String: SyncCursor] = [:]
    var inbox: [SyncChange] = []
    var outgoing = SyncCursor()
    var pending: Data?
    var lastSuccess: Date?
    var current: CurrentSyncState?
    var pendingCount: Int { current.map { Set($0.outbox.keys).union($0.flights.keys).count } ?? outboxIDs.count }
}

/// Protocol v3 stores latest business state and bounded, recoverable in-flight work.
struct CurrentSyncState: Codable, Sendable {
    var protocolVersion: Int? = 3
    var counters: [String: Int] = [:]
    var outbox: [String: SyncMutation] = [:]
    var flights: [String: SyncMutation] = [:]
    var seen: [String: Int] = [:]
    var acknowledged: [String: Int] = [:]
    var indexWatermarks: [String: Int] = [:]
    var inbox: [String: SyncEntityRecord] = [:]
    var indexEstablished = false
    var cleanupPending: Bool? = false
    mutating func enqueue(_ change: SyncChange, writer: UUID) throws {
        let entities = Set(change.writes.map(\.entity)).union(change.events.map { SyncGraph.entity("todo", $0.itemID) })
            .union(change.assignments.map { SyncGraph.entity("todo", $0.itemID) })
        for entity in entities {
            guard SyncCurrent.validEntity(entity), counters[entity, default: 0] < Int.max else { throw SyncFailure.invalidData }
            let item = UUID(uuidString: String(entity.split(separator: ":").last!))!
            var part = change
            part.writes = try change.writes.filter { $0.entity == entity }.map { write in
                var value = write; value.modifiedAt = try SyncCurrent.timestamp(write, in: change); return value
            }
            part.events = change.events.filter { $0.itemID == item && [.completed, .abandoned].contains($0.kind) }
            part.assignments = change.assignments.filter { $0.itemID == item }
            counters[entity, default: 0] += 1
            let merged = try SyncCurrent.coalescing(part, into: outbox[entity]?.change)
            outbox[entity] = SyncMutation(entity: entity, writerID: writer, sequence: counters[entity]!, change: merged)
        }
    }
}
struct SyncMutation: Codable, Sendable {
    var id = UUID()
    let entity: String
    let writerID: UUID
    var sequence: Int
    var change: SyncChange
}
extension SyncMutation {
    enum CodingKeys: String, CodingKey { case id, entity, writerID, sequence, change }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        entity = try values.decode(String.self, forKey: .entity)
        writerID = try values.decode(UUID.self, forKey: .writerID)
        sequence = try values.decode(Int.self, forKey: .sequence)
        change = try values.decode(SyncChange.self, forKey: .change)
    }
}
struct SyncEntityRecord: Codable, Sendable {
    var version = 3
    let libraryID: UUID
    let entity: String
    var revision: Int = 0
    var change: SyncChange
    // One acknowledgement per writer, independent of the number of edits/sync rounds.
    var receipts: [String: Int] = [:]
    var receiptOperations: [String: SyncReceipt]? = [:]
    var publication: SyncPublication?
}
struct SyncPublication: Codable, Sendable {
    let writerID: UUID
    let receipt: SyncReceipt
}
struct SyncReceipt: Codable, Equatable, Sendable {
    let sequence: Int
    let operationID: UUID
    let digest: String
}
struct SyncCurrentIndex: Codable, Sendable {
    var version = 3
    let libraryID: UUID
    var records: [String: Int] = [:]
}

enum SyncCurrent {
    static let maxRecordBytes = 8 * 1024 * 1024
    static let maxIndexBytes = 4 * 1024 * 1024
    static func validEntity(_ entity: String) -> Bool {
        let parts = entity.split(separator: ":")
        return parts.count == 2 && ["todo", "project"].contains(String(parts[0])) &&
            UUID(uuidString: String(parts[1]))?.uuidString.lowercased() == String(parts[1])
    }
    static func path(_ entity: String) throws -> String {
        guard validEntity(entity) else { throw SyncFailure.invalidData }
        return "records/" + entity.replacingOccurrences(of: ":", with: "-") + ".json"
    }
    static func encoded<T: Encodable>(_ value: T, limit: Int) throws -> Data {
        let bytes = try SyncCodec.wrap(value)
        guard bytes.count <= limit else {
            throw SyncFailure.configuration("单条同步记录或索引超过体积上限，本地完整内容与待发修改已保留。")
        }
        return bytes
    }
}
