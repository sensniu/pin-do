import Foundation

enum TodoStatus: String, Codable, Equatable, Sendable {
    case active, completed, abandoned
}

struct TodoItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var notes: String
    var dueAt: Date?
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
        stars: Int = 1, projectID: UUID? = nil, createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.stars = min(3, max(1, stars))
        self.projectID = projectID
        self.status = .active
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

