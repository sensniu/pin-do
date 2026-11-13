import Foundation

struct AnalyticsCompletionDay: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    var items: [UUID] = []
}

enum AnalyticsLifetime: Int, CaseIterable, Identifiable, Sendable {
    case day, threeDays, week, fortnight, month, older
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .day: "不足1天"; case .threeDays: "1–3天"; case .week: "3–7天"
        case .fortnight: "7–14天"; case .month: "14–30天"; case .older: "30天及以上"
        }
    }
    static func classify(seconds: TimeInterval) -> Self {
        switch seconds / 86400 {
        case ..<1: .day; case ..<3: .threeDays; case ..<7: .week
        case ..<14: .fortnight; case ..<30: .month; default: .older
        }
    }
}

struct AnalyticsLifetimeGroup: Identifiable, Sendable {
    var id: Int { band.id }
    let band: AnalyticsLifetime
    var items: [UUID]
}

enum AnalyticsImportanceSlice: String, CaseIterable, Hashable, Sendable {
    case all = "全部", overdue = "已逾期", pending = "截止待确认", remaining = "其余待办", longWaiting = "等待15天及以上"
}

struct AnalyticsImportanceGroup: Identifiable, Sendable {
    var id: Int { stars ?? 0 }
    let stars: Int?
    let items: [UUID]
    let overdue: [UUID]
    let pending: [UUID]
    let remaining: [UUID]
    let longWaiting: [UUID]
    var label: String { stars.map { String(repeating: "★", count: $0) } ?? "星级待确认" }
    func ids(_ slice: AnalyticsImportanceSlice) -> [UUID] {
        switch slice {
        case .all: items; case .overdue: overdue; case .pending: pending
        case .remaining: remaining; case .longWaiting: longWaiting
        }
    }
}

/// Derived from the same scoped snapshot and captured instant as the first-round metrics.
/// This value is memory-only; it never adds records to the store or sync payload.
struct AnalyticsReview: Sendable {
    let days: [AnalyticsCompletionDay]
    let heatmapThresholds: [Int]
    let lifetimes: [AnalyticsLifetimeGroup]
    let durations: [UUID: TimeInterval]
    let lifetimeIssues: [UUID]
    let medianLifetime: TimeInterval?
    let importance: [AnalyticsImportanceGroup]

    static func calculate(completed: [TodoItem], active: [TodoItem], issues: [UUID: Set<String>],
                          overdue: [UUID], interval: DateInterval, now: Date, calendar: Calendar) throws -> Self {
        var days: [AnalyticsCompletionDay] = []
        var cursor = interval.start
        while cursor < interval.end {
            try Task.checkCancellation()
            days.append(AnalyticsCompletionDay(date: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { throw AnalyticsFailure.invalidRange }
            cursor = next
        }
        let dayIndices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.date, $0.offset) })
        var durations: [UUID: TimeInterval] = [:], invalid: [UUID] = []
        for item in completed {
            guard let end = item.completedAt else { continue }
            if let index = dayIndices[calendar.startOfDay(for: end)] { days[index].items.append(item.id) }
            let elapsed = end.timeIntervalSince(item.createdAt)
            guard item.createdAt.timeIntervalSince1970.isFinite, elapsed.isFinite, elapsed >= 0 else { invalid.append(item.id); continue }
            durations[item.id] = elapsed
        }
        let byBand = Dictionary(grouping: completed.filter { durations[$0.id] != nil }, by: { AnalyticsLifetime.classify(seconds: durations[$0.id]!) })
        let lifetimes = AnalyticsLifetime.allCases.map { AnalyticsLifetimeGroup(band: $0, items: byBand[$0, default: []].map(\.id)) }
        let sorted = durations.values.sorted(), middle = sorted.count / 2
        let median: TimeInterval? = sorted.isEmpty ? nil : sorted.count.isMultiple(of: 2)
            ? sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) / 2 : sorted[middle]
        let overdueIDs = Set(overdue)
        let byStars = Dictionary(grouping: active) { item in
            issues[item.id, default: []].contains("stars") || !(1...3).contains(item.stars) ? 0 : item.stars
        }
        let importance = [3, 2, 1, 0].compactMap { stars -> AnalyticsImportanceGroup? in
            let items = byStars[stars, default: []]
            if stars == 0 && items.isEmpty { return nil }
            let pending = items.filter { issues[$0.id, default: []].contains("deadline") || $0.dueAt.map { !$0.timeIntervalSince1970.isFinite } == true }.map(\.id)
            let pendingIDs = Set(pending)
            let old = items.filter {
                let age = AnalyticsAge.classify($0, now: now, calendar: calendar)
                return age == .month || age == .older
            }.map(\.id)
            return AnalyticsImportanceGroup(stars: stars == 0 ? nil : stars, items: items.map(\.id),
                overdue: items.filter { overdueIDs.contains($0.id) }.map(\.id), pending: pending,
                remaining: items.filter { !overdueIDs.contains($0.id) && !pendingIDs.contains($0.id) }.map(\.id), longWaiting: old)
        }
        // Fixed levels retain the same meaning across dates and project scopes. Last band is 7+.
        let thresholds = [1, 3, 6, Int.max]
        return Self(days: days, heatmapThresholds: thresholds, lifetimes: lifetimes, durations: durations, lifetimeIssues: invalid,
                    medianLifetime: median, importance: importance)
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds == 0 { return "0分钟" }
        if seconds < 60 { return "不足1分钟" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟" }
        let value = seconds < 86400 ? seconds / 3600 : seconds / 86400
        return value.formatted(.number.precision(.fractionLength(0...1))) + (seconds < 86400 ? "小时" : "天")
    }
}
