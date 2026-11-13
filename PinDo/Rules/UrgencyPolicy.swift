import Foundation

struct Urgency: Equatable, Sendable {
    enum Band: Int, Comparable, Sendable {
        case noDeadline, later, thisWeek, nextThreeDays, nextDay, nextSixHours, overdue

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let band: Band
    let intensity: Double
    var isOverdue: Bool { band == .overdue }
}

/// Prototype thresholds. Product tuning belongs here, never in view/layout code.
struct UrgencyPolicy: Sendable {
    func evaluate(dueAt: Date?, now: Date) -> Urgency {
        guard let dueAt else { return Urgency(band: .noDeadline, intensity: 0) }
        let remaining = dueAt.timeIntervalSince(now)
        guard remaining > 0 else { return Urgency(band: .overdue, intensity: 1) }
        let hour: TimeInterval = 3_600
        let band: Urgency.Band
        switch remaining {
        case ...(6 * hour): band = .nextSixHours
        case ...(24 * hour): band = .nextDay
        case ...(72 * hour): band = .nextThreeDays
        case ...(168 * hour): band = .thisWeek
        default: band = .later
        }
        // Continuous, opaque color strength; the appearance is identical in both modes.
        let nodes: [(Double, Double)] = [(0, 1), (6, 0.82), (24, 0.55), (72, 0.28), (168, 0.08)]
        let hours = remaining / hour
        var intensity = 0.08
        for index in 1..<nodes.count where hours <= nodes[index].0 {
            let a = nodes[index - 1], b = nodes[index]
            intensity = a.1 + (b.1 - a.1) * (hours - a.0) / (b.0 - a.0)
            break
        }
        return Urgency(band: band, intensity: intensity)
    }
}


/// Relative day names use calendar boundaries, including daylight-saving transitions.
enum DeadlineText {
    static func label(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "无截止时间" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 " + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 " + time
        }
        formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMddHHmm" : "yyyyMMddHHmm")
        return formatter.string(from: date)
    }
}


/// Derived display state only. It is never persisted or uploaded as a progress event.
struct SchedulePresentation: Equatable {
    enum Phase: Equatable { case none, deadlineOnly, waiting, available, overdue, pending }
    let phase: Phase
    let range: String
    let fallback: String
    let detail: String
    let fraction: Double?
    init(item: TodoItem, now: Date, pending: Bool = false, calendar: Calendar = .current) {
        guard !pending else {
            phase = .pending; range = "安排待确认"; fallback = range
            detail = "不同设备的时间安排尚未确认，请在同步设置中选择。"; fraction = nil; return
        }
        guard let due = item.dueAt else {
            phase = .none; range = "无截止时间"; fallback = range; detail = range; fraction = nil; return
        }
        let dueLabel = DeadlineText.label(due, now: now, calendar: calendar)
        let overdue = now >= due
        fallback = now == due ? "已到截止" : overdue ? "已逾期" + Self.duration(now.timeIntervalSince(due)) : dueLabel + "截止"
        if let start = item.plannedStartAt {
            phase = overdue ? .overdue : now < start ? .waiting : .available
            let startLabel = DeadlineText.label(start, now: now, calendar: calendar)
            if overdue { range = fallback }
            else if calendar.isDate(start, inSameDayAs: due) {
                let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone; format.dateFormat = "HH:mm"
                range = startLabel + " → " + format.string(from: due)
            } else { range = startLabel + " → " + dueLabel }
            fraction = due > start ? min(1, max(0, now.timeIntervalSince(start) / due.timeIntervalSince(start))) : nil
            detail = "预计开始：" + start.formatted(date: .abbreviated, time: .shortened) + "\n截止：" + due.formatted(date: .abbreviated, time: .shortened)
                + "\n" + (now < start ? "距开始" + Self.duration(start.timeIntervalSince(now)) : overdue ? fallback : "距截止" + Self.duration(due.timeIntervalSince(now)))
                + "\n时间条表示计划时间的消耗，不代表任务完成比例。"
        } else {
            phase = overdue ? .overdue : .deadlineOnly; range = fallback; fraction = nil
            detail = "截止：" + due.formatted(date: .abbreviated, time: .shortened)
        }
    }
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds < 1e12 else { return "很久" }
        let minutes = max(0, Int(ceil(seconds / 60)))
        if minutes < 60 { return "\(minutes)分钟" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)小时" : "\(hours / 24)天\(hours % 24)小时"
    }
}
