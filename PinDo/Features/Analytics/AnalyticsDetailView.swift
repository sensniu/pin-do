import SwiftUI

@MainActor
final class AnalyticsDetailState: ObservableObject {
    @Published var expanded: UUID?
    @Published var limit = 50
}

struct AnalyticsDetailView: View {
    @ObservedObject var model: AnalyticsModel
    @ObservedObject var environment: AppEnvironment
    let result: AnalyticsResult
    @StateObject private var state = AnalyticsDetailState()
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(result.title(for: model.detail)).font(.headline).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("关闭") { model.closeDetails() }.font(.caption).focused($closeFocused).keyboardShortcut(.cancelAction)
                }
                Text((model.detail == .membershipIssues ? "全部项目" : result.scopeName) + " · " + context)
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(result.ids(for: model.detail).count) 项").font(.callout).monospacedDigit()
                if model.error != nil { Text("显示上次结果，尚未更新。").font(.caption).foregroundStyle(.orange) }
            }.padding(20)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("detail-top")
                        if model.detail == .issues { issueFilters.padding(.bottom, 14) }
                        let records = result.records(for: model.detail)
                        if records.isEmpty { Text("当前条件下没有事项。").font(.callout).foregroundStyle(.secondary).padding(.vertical, 24) }
                        ForEach(Array(records.prefix(state.limit))) { item in
                            VStack(alignment: .leading, spacing: 12) {
                                Button { state.expanded = state.expanded == item.id ? nil : item.id } label: {
                                    AnalyticsRecordSummary(item: item, result: result, showsProject: model.scope == .all || model.detail == .membershipIssues)
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityHint("展开或收起备注与时间")
                                if state.expanded == item.id { metadata(item) }
                                if item.status == .active {
                                    Button("在白板中打开") { environment.editFromOverview(item) }.buttonStyle(.link).font(.caption)
                                }
                            }.padding(.vertical, 14)
                            Divider().opacity(0.5)
                        }
                        if records.count > state.limit {
                            Button("显示更多（还有 \(records.count - state.limit) 项）") { state.limit += 50 }.padding(.top, 12)
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
                .onAppear { reset(); closeFocused = true }
                .onChange(of: model.selectionRevision) { _, _ in reset(); closeFocused = true; scroll.scrollTo("detail-top", anchor: .top) }
            }
        }.background(.background.opacity(0.6))
            .onExitCommand { model.closeDetails() }
    }

    private var context: String {
        switch model.detail {
        case .completed, .created, .abandoned, .createdBucket, .completedBucket, .completionDay, .lifetime, .lifetimeAll, .lifetimeIssues:
            return result.periodLabel
        case .project(_, .completed): return result.periodLabel
        case .record: return "本地当前保存内容"
        default: return "当前状态"
        }
    }
    private func reset() {
        state.limit = 50
        if case .record(let id) = model.detail { state.expanded = id } else { state.expanded = nil }
    }
    private var issueFilters: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("各提示可能涉及同一事项，合计已按事项去重。").font(.caption).foregroundStyle(.secondary)
            if !result.statusIssues.isEmpty { issue("状态", count: result.statusIssues.count, detail: .statusIssues) }
            if !result.deadlineIssues.isEmpty { issue("截止时间", count: result.deadlineIssues.count, detail: .deadlineIssues) }
            if !result.starIssues.isEmpty { issue("星级", count: result.starIssues.count, detail: .starIssues) }
            if !result.timeIssues.isEmpty { issue("时间", count: result.timeIssues.count, detail: .timeIssues) }
            if model.scope == .all && !result.membershipIssues.isEmpty { issue("项目归属", count: result.membershipIssues.count, detail: .membershipIssues) }
            Button("处理同步问题…") { environment.presentSettings(.sync, issues: true) }.buttonStyle(.link).font(.caption)
        }
    }
    private func issue(_ name: String, count: Int, detail: AnalyticsDetail) -> some View {
        Button("\(name) · \(count) 项") { model.select(detail) }.buttonStyle(.link).font(.caption)
    }
    private func metadata(_ item: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if !item.notes.isEmpty { Text(item.notes).textSelection(.enabled) }
            Text("创建：" + timestamp(item.createdAt))
            if result.input.issues[item.id, default: []].contains("deadline") { Text("截止时间待确认").foregroundStyle(.orange) }
            else { Text("截止：" + (item.dueAt.map(timestamp) ?? "无截止时间")) }
            if let date = item.completedAt, item.status == .completed { Text("完成：" + timestamp(date)) }
            if let date = item.abandonedAt, item.status == .abandoned { Text("放弃：" + timestamp(date)) }
            if let duration = result.review.durations[item.id] { Text("创建至完成：" + AnalyticsReview.durationLabel(duration) + "（含等待）") }
            if result.review.lifetimeIssues.contains(item.id) { Text("创建与完成时间待核对，未纳入跨度计算。").foregroundStyle(.orange) }
            if !result.input.issues[item.id, default: []].isEmpty { Text("此事项有待确认内容，显示的候选值不代表最终选择。").foregroundStyle(.orange) }
        }.font(.callout)
    }
    private func timestamp(_ date: Date) -> String {
        date.timeIntervalSince1970.isFinite ? date.formatted(date: .abbreviated, time: .shortened) : "时间待核对"
    }
}

struct AnalyticsRecordSummary: View {
    let item: TodoItem
    let result: AnalyticsResult
    let showsProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(item.status == .completed ? Color.green : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.callout.weight(.medium)).multilineTextAlignment(.leading).lineLimit(2)
                HStack(spacing: 8) {
                    if showsProject { Text(result.projectName(result.groupKey(for: item))).lineLimit(1).layoutPriority(-1) }
                    if item.status == .active {
                        if result.input.issues[item.id, default: []].contains("stars") { Text("星级待确认") }
                        else { Text(String(repeating: "★", count: max(0, min(3, item.stars)))).accessibilityLabel("\(item.stars)星") }
                    }
                    status.lineLimit(1).layoutPriority(1)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var symbol: String {
        switch item.status { case .completed: "checkmark.circle"; case .abandoned: "minus.circle"; case .conflicted: "exclamationmark.circle"; case .active: "circle" }
    }
    @ViewBuilder private var status: some View {
        switch item.status {
        case .active:
            if result.input.issues[item.id, default: []].contains("deadline") { Text("截止时间待确认") }
            else if let due = item.dueAt, due.timeIntervalSince1970.isFinite {
                // SwiftUI updates relative time without re-running the full-history aggregation.
                HStack(spacing: 3) { Text(due < result.now ? "逾期" : "还剩"); Text(due, style: .relative) }
                    .help("截止：" + due.formatted(date: .abbreviated, time: .shortened))
            } else { Text("未设截止时间") }
        case .completed:
            if let date = item.completedAt { Text("完成于 " + date.formatted(date: .abbreviated, time: .shortened)) }
            else { Text("完成时间待核对") }
        case .abandoned:
            if let date = item.abandonedAt { Text("放弃于 " + date.formatted(date: .abbreviated, time: .shortened)) }
            else { Text("放弃时间待核对") }
        case .conflicted: Text("状态待确认")
        }
    }
}
