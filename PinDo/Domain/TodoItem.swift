import Foundation

enum TodoStatus: String, Codable, Equatable, Sendable {
    case active, completed, abandoned, conflicted
}

struct TodoItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var notes: String
    var dueAt: Date?
    var plannedStartAt: Date? = nil
    var completionSchedule: CompletionSchedule? = nil
    var stars: Int
    var projectID: UUID?
    var projectAssignments: [ProjectAssignment] = []
    var status: TodoStatus
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var abandonedAt: Date?

    init(
        id: UUID = UUID(), title: String, notes: String = "", dueAt: Date? = nil,
        stars: Int = 1, projectID: UUID? = nil, createdAt: Date = .now, plannedStartAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.plannedStartAt = plannedStartAt
        self.stars = min(3, max(1, stars))
        self.projectID = projectID
        self.status = .active
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}


/// A single atomic schedule: concurrent edits never splice unrelated endpoints.
struct TodoSchedule: Codable, Equatable, Sendable {
    var startAt: Date?
    var dueAt: Date?
    var isValid: Bool {
        guard dueAt?.timeIntervalSince1970.isFinite ?? true,
              startAt?.timeIntervalSince1970.isFinite ?? true else { return false }
        guard let startAt else { return true }
        guard let dueAt else { return false }
        return startAt <= dueAt
    }
    static func decodeSync(_ data: Data) throws -> Self {
        // v3 deadline fields were a nullable ISO date; retain exact compatibility.
        if let legacy = try? SyncCodec.decode(Date?.self, data) { return Self(startAt: nil, dueAt: legacy) }
        if data == Data("null".utf8) { return Self(startAt: nil, dueAt: nil) }
        let value = try SyncCodec.decode(Self.self, data)
        guard value.startAt != nil, value.isValid else { throw SyncFailure.invalidData }
        return value
    }
    func encodeSync() throws -> Data {
        guard isValid else { throw SyncFailure.invalidData }
        return try startAt == nil ? SyncCodec.encode(dueAt) : SyncCodec.encode(self)
    }
}

/// The context of the currently effective completion, never an accumulating edit history.
struct CompletionSchedule: Codable, Equatable, Sendable {
    let startAt: Date?
    let dueAt: Date?
    var schedule: TodoSchedule { TodoSchedule(startAt: startAt, dueAt: dueAt) }
}

extension TodoItem {
    var schedule: TodoSchedule { TodoSchedule(startAt: plannedStartAt, dueAt: dueAt) }
}
