import Foundation

enum PrototypeData {
    static let projects = [
        Project(id: UUID(uuidString: "DD176B9E-8FAA-4051-88BD-30D861CEAB01")!, name: "工作"),
        Project(id: UUID(uuidString: "DD176B9E-8FAA-4051-88BD-30D861CEAB02")!, name: "生活", color: 1),
        Project(id: UUID(uuidString: "DD176B9E-8FAA-4051-88BD-30D861CEAB03")!, name: "学习", color: 2)
    ]
    static func items(now: Date) -> [TodoItem] {
        let hour: TimeInterval = 3_600
        return [
            TodoItem(title: "完成方案的最后一轮修改", notes: "梳理关键结论，再检查一次交付清单。", dueAt: now.addingTimeInterval(3 * hour), stars: 3, projectID: projects[0].id),
            TodoItem(title: "整理本周的工作记录", notes: "记下做成的事，也留意还没有推进的部分。", dueAt: now.addingTimeInterval(18 * hour), stars: 2, projectID: projects[0].id),
            TodoItem(title: "读完正在看的那一章", notes: "摘录一个值得继续想的问题。", dueAt: now.addingTimeInterval(48 * hour), projectID: projects[2].id),
            TodoItem(title: "预约年度体检", notes: "确认时间，避开下周的会议。", dueAt: now.addingTimeInterval(96 * hour), stars: 2, projectID: projects[1].id),
            TodoItem(title: "给家里添一盆绿植", notes: "找一种适合窗边、容易照顾的植物。", projectID: projects[1].id),
            TodoItem(title: "一个暂时不用着急的想法", notes: "把想法放在这里。\n有空时再慢慢补充。\n先做一个小实验。\n展开后可以看到这第四行内容。", stars: 2),
            TodoItem(title: "回复上周的合作邮件", notes: "确认下一步安排。", dueAt: now.addingTimeInterval(-5 * hour), stars: 2, projectID: projects[0].id),
            TodoItem(title: "归还借来的书", notes: "路过图书馆时顺便完成。", dueAt: now.addingTimeInterval(-28 * hour), projectID: projects[1].id)
        ]
    }
}

