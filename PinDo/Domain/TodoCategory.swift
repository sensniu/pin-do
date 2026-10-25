import Foundation

struct TodoCategory: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let red: Double
    let green: Double
    let blue: Double

    static let work = TodoCategory(id: "work", name: "工作", red: 0.25, green: 0.46, blue: 0.83)
    static let personal = TodoCategory(id: "personal", name: "生活", red: 0.23, green: 0.57, blue: 0.42)
    static let learning = TodoCategory(id: "learning", name: "学习", red: 0.75, green: 0.48, blue: 0.15)
    static let examples = [work, personal, learning]
}

