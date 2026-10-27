import Foundation

enum ProjectStatus: String, Codable, Sendable { case active, archived, deleted }

struct Project: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let red: Double
    let green: Double
    let blue: Double
    var status: ProjectStatus = .active
    let createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var deletedAt: Date?

    init(id: UUID = UUID(), name: String, color: Int = 0, now: Date = .now) {
        let palette = [(0.25, 0.46, 0.83), (0.23, 0.57, 0.42), (0.75, 0.48, 0.15), (0.67, 0.35, 0.65), (0.15, 0.58, 0.65)]
        let rgb = palette[abs(color % palette.count)]
        self.id = id; self.name = name; red = rgb.0; green = rgb.1; blue = rgb.2
        createdAt = now; updatedAt = now
    }

    init(legacy: TodoCategory, id: UUID, now: Date) {
        self.id = id; name = legacy.name; red = legacy.red; green = legacy.green; blue = legacy.blue
        createdAt = now; updatedAt = now
    }
}

enum BoardScope: Hashable, Sendable {
    case all, unassigned, project(UUID)
    func includes(_ item: TodoItem) -> Bool {
        switch self {
        case .all: true
        case .unassigned: item.projectID == nil
        case .project(let id): item.projectID == id
        }
    }
    var projectID: UUID? { if case .project(let id) = self { id } else { nil } }
}

struct BoardData: Sendable {
    var projects: [Project]
    var items: [TodoItem]
}

enum UnfinishedProjectAction: Sendable { case transferToUnassigned, abandon }

struct ProjectAssignment: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case manual, archived, deleted, completionRestored }
    let previousProjectID: UUID?
    let projectID: UUID?
    let changedAt: Date
    let reason: Reason
}
