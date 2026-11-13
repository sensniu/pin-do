import Foundation

struct AnalyticsInput: Sendable {
    var items: [TodoItem]
    var projects: [Project]
    var issues: [UUID: Set<String>] = [:]
}

enum AnalyticsRange: Equatable, Sendable {
    case recent(Int)
    case custom(Date, Date)

    func interval(now: Date, calendar: Calendar) throws -> DateInterval {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .recent(let days):
            guard days > 0, days <= 36600,
                  let start = calendar.date(byAdding: .day, value: 1 - days, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: today) else { throw AnalyticsFailure.invalidRange }
            return DateInterval(start: start, end: end)
        case .custom(let first, let last):
            guard first.timeIntervalSince1970.isFinite, last.timeIntervalSince1970.isFinite else { throw AnalyticsFailure.invalidRange }
            let start = calendar.startOfDay(for: first), lastDay = calendar.startOfDay(for: last)
            guard start <= lastDay, lastDay <= today,
                  let end = calendar.date(byAdding: .day, value: 1, to: lastDay),
                  (calendar.dateComponents([.day], from: start, to: end).day ?? .max) <= 36600 else { throw AnalyticsFailure.invalidRange }
            return DateInterval(start: start, end: end)
        }
    }
}

enum AnalyticsProjectMode: String, CaseIterable, Sendable { case active = "当前待办", completed = "本期完成" }
enum AnalyticsProjectKey: Hashable, Sendable {
    case project(UUID), unassigned, pending, other
    var id: String {
        switch self { case .project(let id): id.uuidString; case .unassigned: "unassigned"; case .pending: "pending"; case .other: "other" }
    }
}
enum AnalyticsAge: Int, CaseIterable, Identifiable, Sendable {
    case recent, week, fortnight, month, older, unknown
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .recent: "0–2 天"; case .week: "3–7 天"; case .fortnight: "8–14 天"
        case .month: "15–30 天"; case .older: "31 天及以上"; case .unknown: "创建时间待核对"
        }
    }
    static func classify(_ item: TodoItem, now: Date, calendar: Calendar) -> Self {
        guard item.createdAt <= now, item.createdAt.timeIntervalSince1970.isFinite,
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: item.createdAt), to: calendar.startOfDay(for: now)).day,
              days >= 0 else { return .unknown }
        switch days { case 0...2: return .recent; case 3...7: return .week; case 8...14: return .fortnight; case 15...30: return .month; default: return .older }
    }
}
struct AnalyticsTrendBucket: Identifiable, Sendable {
    var id: Date { interval.start }
    let interval: DateInterval
    var created: [UUID] = []
    var completed: [UUID] = []
}
struct AnalyticsProjectGroup: Identifiable, Sendable {
    var id: String { key.id }
    let key: AnalyticsProjectKey
    var items: [UUID]
    var projectCount = 0
}
struct AnalyticsAgeGroup: Identifiable, Sendable {
    var id: Int { age.id }
    let age: AnalyticsAge
    var items: [UUID]
}
enum AnalyticsDetail: Hashable, Sendable {
    case active, overdue, completed, abandoned, created, upcoming, todayCompleted, attention, lifetimeAll, issues, starIssues
    case record(UUID)
    case createdBucket(Date), completedBucket(Date)
    case project(AnalyticsProjectKey, AnalyticsProjectMode), age(AnalyticsAge)
    case completionDay(Date), lifetime(AnalyticsLifetime), lifetimeIssues
    case importance(Int?, AnalyticsImportanceSlice)
    case statusIssues, deadlineIssues, membershipIssues, timeIssues
}
enum AnalyticsFailure: LocalizedError {
    case invalidRange, inconsistentData, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidRange: "请选择有效的日期范围，结束日期不能晚于今天。"
        case .inconsistentData: "统计数据未通过一致性检查，现有内容已保留。"
        case .unavailable: "本地数据尚未打开，暂时无法生成概览。"
        }
    }
}

struct AnalyticsResult: Sendable {
    let now: Date
    let interval: DateInterval
    let weekly: Bool
    let calendar: Calendar
    let scope: BoardScope
    let input: AnalyticsInput
    let lookup: [UUID: TodoItem]
    let active: [UUID]
    let overdue: [UUID]
    let completed: [UUID]
    let abandoned: [UUID]
    let trend: [AnalyticsTrendBucket]
    let activeProjects: [AnalyticsProjectGroup]
    let completedProjects: [AnalyticsProjectGroup]
    let ages: [AnalyticsAgeGroup]
    let review: AnalyticsReview
    let current: AnalyticsCurrent
    let statusIssues: [UUID]
    let deadlineIssues: [UUID]
    let membershipIssues: [UUID]
    let timeIssues: [UUID]
    let nextRefresh: Date

    func projectName(_ key: AnalyticsProjectKey) -> String {
        switch key {
        case .unassigned: return "未分配项目"
        case .pending: return "归属待确认"
        case .other: return "其他项目"
        case .project(let id):
            guard let project = input.projects.first(where: { $0.id == id }) else { return "项目待核对" }
            let matches = input.projects.filter { $0.name == project.name }.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
            let suffix = project.status == .active ? "" : project.status == .archived ? " · 已归档" : " · 已删除"
            let duplicate = matches.count > 1 ? " · \((matches.firstIndex { $0.id == id } ?? 0) + 1)" : ""
            return project.name + duplicate + suffix
        }
    }
    func groupKey(for item: TodoItem) -> AnalyticsProjectKey {
        if input.issues[item.id, default: []].contains("membership") { return .pending }
        return item.projectID.map(AnalyticsProjectKey.project) ?? .unassigned
    }
    func groups(_ mode: AnalyticsProjectMode) -> [AnalyticsProjectGroup] { mode == .active ? activeProjects : completedProjects }
    func dayLabel(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)/\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
    func bucketLabel(_ bucket: AnalyticsTrendBucket) -> String {
        let end = calendar.date(byAdding: .day, value: -1, to: bucket.interval.end) ?? bucket.interval.start
        func label(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let years = calendar.component(.year, from: interval.start) != calendar.component(.year, from: interval.end.addingTimeInterval(-1))
            return (years ? "\(parts.year ?? 0)/" : "") + "\(parts.month ?? 0)/\(parts.day ?? 0)"
        }
        return weekly ? label(bucket.interval.start) + "–" + label(end) : label(bucket.interval.start)
    }
    func ids(for detail: AnalyticsDetail) -> [UUID] {
        switch detail {
        case .active: active; case .overdue: overdue; case .completed: completed; case .abandoned: abandoned
        case .created: created; case .upcoming: current.upcoming; case .todayCompleted: current.todayCompleted; case .attention: current.attention
        case .lifetimeAll: lifetimeItems; case .issues: scopedIssues; case .starIssues: starIssues
        case .record(let id): lookup[id].map { item in
            scope == .all || (!input.issues[id, default: []].contains("membership") && scope.includes(item)) ? [id] : []
        } ?? []
        case .createdBucket(let date): trend.first { $0.id == date }?.created ?? []
        case .completedBucket(let date): trend.first { $0.id == date }?.completed ?? []
        case .project(let key, let mode): (key == .other ? compactGroups(mode) : groups(mode)).first { $0.key == key }?.items ?? []
        case .age(let age): ages.first { $0.age == age }?.items ?? []
        case .completionDay(let date): review.days.first { $0.date == date }?.items ?? []
        case .lifetime(let band): review.lifetimes.first { $0.band == band }?.items ?? []
        case .lifetimeIssues: review.lifetimeIssues
        case .importance(let stars, let slice): review.importance.first { $0.stars == stars }?.ids(slice) ?? []
        case .statusIssues: statusIssues; case .deadlineIssues: deadlineIssues; case .membershipIssues: membershipIssues; case .timeIssues: timeIssues
        }
    }
    func title(for detail: AnalyticsDetail) -> String {
        switch detail {
        case .active: "当前待办"; case .overdue: "当前逾期"; case .completed: "本期完成"; case .abandoned: "本期放弃"
        case .created: "本期新增"; case .upcoming: "24小时内到期"; case .todayCompleted: "今天完成"; case .attention: "需要留意"
        case .lifetimeAll: "创建到完成"; case .issues: "当前范围待确认的事项"; case .starIssues: "星级待确认"
        case .record(let id): lookup[id]?.title ?? "事项已变化"
        case .createdBucket(let date): (trend.first { $0.id == date }.map(bucketLabel) ?? "") + " · 新增"
        case .completedBucket(let date): (trend.first { $0.id == date }.map(bucketLabel) ?? "") + " · 完成"
        case .project(let key, let mode): projectName(key) + " · " + mode.rawValue
        case .age(let age): "待办等待 · " + age.label
        case .completionDay(let date): dayLabel(date) + " · 完成"
        case .lifetime(let band): "创建到完成 · " + band.label
        case .lifetimeIssues: "创建与完成时间待核对"
        case .importance(let stars, let slice): (stars.map { "\($0)星" } ?? "星级待确认") + " · 当前" + slice.rawValue
        case .statusIssues: "状态待确认"; case .deadlineIssues: "截止时间待确认"
        case .membershipIssues: "全部项目 · 归属待确认"; case .timeIssues: "时间待核对"
        }
    }
    func records(for detail: AnalyticsDetail) -> [TodoItem] {
        let items = ids(for: detail).compactMap { lookup[$0] }
        if detail == .attention || detail == .upcoming || detail == .todayCompleted { return items }
        return items.sorted { left, right in
            func date(_ item: TodoItem) -> Date {
                switch detail {
                case .overdue: return item.dueAt ?? .distantFuture
                case .age, .active, .created, .createdBucket, .importance: return item.createdAt
                case .abandoned: return item.abandonedAt ?? .distantPast
                default: return item.completedAt ?? item.createdAt
                }
            }
            if date(left) == date(right) { return left.id.uuidString < right.id.uuidString }
            switch detail { case .overdue, .age, .active, .importance: return date(left) < date(right); default: return date(left) > date(right) }
        }
    }
}

enum AnalyticsEngine {
    static func calculate(_ input: AnalyticsInput, scope: BoardScope, range: AnalyticsRange, now: Date, calendar original: Calendar) throws -> AnalyticsResult {
        try Task.checkCancellation()
        var calendar = original
        calendar.firstWeekday = 2
        let interval = try range.interval(now: now, calendar: calendar)
        let days = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
        let weekly = days > 31
        var lookup: [UUID: TodoItem] = [:]
        for item in input.items {
            if let existing = lookup[item.id], existing != item { throw AnalyticsFailure.inconsistentData }
            lookup[item.id] = item
        }
        guard Set(input.projects.map(\.id)).count == input.projects.count else { throw AnalyticsFailure.inconsistentData }
        let projectIDs = Set(input.projects.map(\.id))
        guard lookup.values.allSatisfy({ $0.projectID.map(projectIDs.contains) ?? true }) else { throw AnalyticsFailure.inconsistentData }
        let items = lookup.values.filter { item in
            if scope == .all { return true }
            guard !input.issues[item.id, default: []].contains("membership") else { return false }
            return scope.includes(item)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        func valid(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && date <= now }
        func inRange(_ date: Date) -> Bool { valid(date) && date >= interval.start && date < interval.end }
        let activeItems = items.filter { $0.status == .active }
        let active = activeItems.map(\.id)
        let overdue = activeItems.filter {
            !input.issues[$0.id, default: []].contains("deadline") && ($0.dueAt.map { $0.timeIntervalSince1970.isFinite && $0 < now } ?? false)
        }.map(\.id)
        let completedItems = items.filter { $0.status == .completed && ($0.completedAt.map(inRange) ?? false) }
        let completed = completedItems.map(\.id)
        let abandoned = items.filter { $0.status == .abandoned && ($0.abandonedAt.map(inRange) ?? false) }.map(\.id)
        var buckets: [AnalyticsTrendBucket] = []
        var cursor = interval.start
        while cursor < interval.end {
            try Task.checkCancellation()
            let next: Date?
            if weekly { next = calendar.dateInterval(of: .weekOfYear, for: cursor)?.end }
            else { next = calendar.date(byAdding: .day, value: 1, to: cursor) }
            guard let next, next > cursor else { throw AnalyticsFailure.invalidRange }
            let end = min(next, interval.end)
            buckets.append(AnalyticsTrendBucket(interval: DateInterval(start: cursor, end: end)))
            cursor = end
        }
        // Index by calendar bucket for linear aggregation rather than scanning the full history per bar.
        let bucketIndices = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { index, bucket in
            (weekly ? calendar.dateInterval(of: .weekOfYear, for: bucket.interval.start)!.start : bucket.interval.start, index)
        })
        func index(_ date: Date) -> Int? {
            guard inRange(date) else { return nil }
            let start = weekly ? calendar.dateInterval(of: .weekOfYear, for: date)?.start : calendar.startOfDay(for: date)
            return start.flatMap { bucketIndices[$0] }
        }
        for item in items {
            if let index = index(item.createdAt) { buckets[index].created.append(item.id) }
            if item.status == .completed, let date = item.completedAt, let index = index(date) { buckets[index].completed.append(item.id) }
        }
        func key(_ item: TodoItem) -> AnalyticsProjectKey {
            if input.issues[item.id, default: []].contains("membership") { return .pending }
            return item.projectID.map(AnalyticsProjectKey.project) ?? .unassigned
        }
        func groups(_ items: [TodoItem]) -> [AnalyticsProjectGroup] {
            Dictionary(grouping: items, by: key).map { AnalyticsProjectGroup(key: $0.key, items: $0.value.map(\.id)) }.sorted {
                $0.items.count == $1.items.count ? $0.id < $1.id : $0.items.count > $1.items.count
            }
        }
        let ageLookup = Dictionary(grouping: activeItems, by: { AnalyticsAge.classify($0, now: now, calendar: calendar) })
        let ages = AnalyticsAge.allCases.compactMap { age -> AnalyticsAgeGroup? in
            let ids = ageLookup[age, default: []].map(\.id)
            return age == .unknown && ids.isEmpty ? nil : AnalyticsAgeGroup(age: age, items: ids)
        }
        var nextRefresh = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        for item in input.items {
            var dates = [item.createdAt, item.completedAt].compactMap { $0 }
            if item.status == .active, !input.issues[item.id, default: []].contains("deadline"), let due = item.dueAt {
                dates.append(due)
                dates.append(due.addingTimeInterval(-86400))
            }
            for date in dates where date >= now && date.timeIntervalSince1970.isFinite { nextRefresh = min(nextRefresh, date.addingTimeInterval(0.1)) }
        }
        let review = try AnalyticsReview.calculate(completed: completedItems, active: activeItems, issues: input.issues,
                                                  overdue: overdue, interval: interval, now: now, calendar: calendar)
        let timeIssues = items.filter {
            !valid($0.createdAt) || ($0.status == .completed && !($0.completedAt.map(valid) ?? false)) || ($0.status == .abandoned && !($0.abandonedAt.map(valid) ?? false))
        }.map(\.id)
        let current = AnalyticsCurrent.calculate(items: items, issues: input.issues, overdue: overdue, now: now, calendar: calendar)
        return AnalyticsResult(now: now, interval: interval, weekly: weekly, calendar: calendar, scope: scope, input: input, lookup: lookup,
            active: active, overdue: overdue, completed: completed, abandoned: abandoned, trend: buckets,
            activeProjects: groups(activeItems), completedProjects: groups(completedItems), ages: ages, review: review, current: current,
            statusIssues: items.filter { $0.status == .conflicted }.map(\.id),
            deadlineIssues: activeItems.filter { input.issues[$0.id, default: []].contains("deadline") }.map(\.id),
            membershipIssues: lookup.values.filter { input.issues[$0.id, default: []].contains("membership") }.map(\.id).sorted { $0.uuidString < $1.uuidString },
            timeIssues: Array(Set(timeIssues + review.lifetimeIssues)).sorted { $0.uuidString < $1.uuidString }, nextRefresh: nextRefresh)
    }
}
