import Foundation

enum PrototypeData {
    static func items(now: Date) -> [TodoItem] {
        let hour: TimeInterval = 3_600
        return [
            TodoItem(title: "完成方案的最后一轮修改", notes: "梳理关键结论，再检查一次交付清单。", dueAt: now.addingTimeInterval(3 * hour), stars: 3, category: .work),
            TodoItem(title: "整理本周的工作记录", notes: "记下做成的事，也留意还没有推进的部分。", dueAt: now.addingTimeInterval(18 * hour), stars: 2, category: .work),
            TodoItem(title: "读完正在看的那一章", notes: "摘录一个值得继续想的问题。", dueAt: now.addingTimeInterval(48 * hour), category: .learning),
            TodoItem(title: "预约年度体检", notes: "确认时间，避开下周的会议。", dueAt: now.addingTimeInterval(96 * hour), stars: 2, category: .personal),
            TodoItem(title: "给家里添一盆绿植", notes: "找一种适合窗边、容易照顾的植物。", category: .personal),
            TodoItem(title: "一个暂时不用着急的想法", notes: "把想法放在这里。\n有空时再慢慢补充。\n先做一个小实验。\n展开后可以看到这第四行内容。", stars: 2),
            TodoItem(title: "回复上周的合作邮件", notes: "确认下一步安排。", dueAt: now.addingTimeInterval(-5 * hour), stars: 2, category: .work),
            TodoItem(title: "归还借来的书", notes: "路过图书馆时顺便完成。", dueAt: now.addingTimeInterval(-28 * hour), category: .personal)
        ]
    }
}

