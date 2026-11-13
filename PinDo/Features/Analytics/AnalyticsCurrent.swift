import Foundation

struct AnalyticsCurrent: Sendable {
    let upcoming: [UUID]
    let todayCompleted: [UUID]
    /// Complete ordered collection; the preview takes its first five IDs.
    let attention: [UUID]

    static func calculate(items: [TodoItem], issues: [UUID: Set<String>], overdue: [UUID], now: Date, calendar: Calendar) -> Self {
        let active = items.filter { $0.status == .active }
        let horizon = now.addingTimeInterval(86400)
        let upcoming = active.filter {
            guard !issues[$0.id, default: []].contains("deadline"), let due = $0.dueAt, due.timeIntervalSince1970.isFinite else { return false }
            return due >= now && due < horizon
        }
        let today = calendar.startOfDay(for: now)
        let todayCompleted = items.filter {
            guard $0.status == .completed, let date = $0.completedAt, date.timeIntervalSince1970.isFinite else { return false }
            return date >= today && date <= now
        }.sorted { $0.completedAt == $1.completedAt ? $0.id.uuidString < $1.id.uuidString : $0.completedAt! > $1.completedAt! }.map(\.id)
        let overdueIDs = Set(overdue), upcomingIDs = Set(upcoming.map(\.id))
        func stars(_ item: TodoItem) -> Int { issues[item.id, default: []].contains("stars") || !(1...3).contains(item.stars) ? 0 : item.stars }
        func byDeadline(_ a: TodoItem, _ b: TodoItem) -> Bool {
            if a.dueAt != b.dueAt { return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture) }
            if stars(a) != stars(b) { return stars(a) > stars(b) }
            return a.id.uuidString < b.id.uuidString
        }
        let late = active.filter { overdueIDs.contains($0.id) }.sorted(by: byDeadline)
        let soon = upcoming.sorted(by: byDeadline)
        let waiting = active.filter {
            guard !overdueIDs.contains($0.id), !upcomingIDs.contains($0.id), stars($0) == 3 else { return false }
            let age = AnalyticsAge.classify($0, now: now, calendar: calendar)
            return age == .month || age == .older
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        return Self(upcoming: soon.map(\.id), todayCompleted: todayCompleted, attention: (late + soon + waiting).map(\.id))
    }
}

extension AnalyticsResult {
    var created: [UUID] { trend.flatMap(\.created) }
    var lifetimeItems: [UUID] { review.lifetimes.flatMap(\.items) }
    var starIssues: [UUID] { review.importance.first { $0.stars == nil }?.items ?? [] }
    var scopedIssues: [UUID] {
        let membership = scope == .all ? membershipIssues : []
        return Array(Set(statusIssues + deadlineIssues + timeIssues + starIssues + membership)).sorted { $0.uuidString < $1.uuidString }
    }
    var scopeName: String {
        switch scope { case .all: "全部项目"; case .unassigned: "未分配项目"; case .project(let id): projectName(.project(id)) }
    }
    var periodLabel: String { dayLabel(interval.start) + "–" + dayLabel(interval.end.addingTimeInterval(-1)) }

    func compactGroups(_ mode: AnalyticsProjectMode) -> [AnalyticsProjectGroup] {
        let all = groups(mode)
        let projects = all.filter { if case .project = $0.key { true } else { false } }
        guard projects.count > 5 else { return all }
        let rest = Array(projects.dropFirst(5))
        return Array(projects.prefix(5)) + [AnalyticsProjectGroup(key: .other, items: rest.flatMap(\.items), projectCount: rest.count)]
            + all.filter { $0.key == .unassigned || $0.key == .pending }
    }
}
