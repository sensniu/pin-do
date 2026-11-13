import SwiftUI

struct AnalyticsView: View {
    @ObservedObject var model: AnalyticsModel
    @ObservedObject var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @FocusState private var contextFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let docked = geometry.size.width >= 1100
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        contextBar
                        Divider().opacity(0.5)
                        ScrollViewReader { reader in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    if let error = model.error { failure(error) }
                                    if let result = model.result {
                                        if model.page == .summary { currentPage(result) }
                                        else { reviewPage(result) }
                                        sourceNote(result)
                                    } else if model.loading {
                                        ProgressView("正在整理事项…").frame(maxWidth: .infinity, minHeight: 260)
                                    }
                                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).id("analytics-page-top")
                            }.onChange(of: model.page) { _, _ in reader.scrollTo("analytics-page-top", anchor: .top) }
                        }
                    }
                    .disabled(!docked && model.inspectorOpen)
                    .accessibilityHidden(!docked && model.inspectorOpen)
                    if docked && model.inspectorOpen {
                        Divider()
                        inspector.frame(width: 380)
                    }
                }
                if !docked && model.inspectorOpen {
                    Color.black.opacity(scheme == .dark ? 0.3 : 0.08)
                        .contentShape(Rectangle()).onTapGesture { model.closeDetails() }
                    inspector.frame(width: min(440, max(320, geometry.size.width - 40)))
                        .background(WorkspaceStyle.canvas(scheme)).shadow(color: .black.opacity(0.12), radius: 16, x: -4)
                }
            }
        }
        .onExitCommand { if model.inspectorOpen { model.closeDetails() } }
        .onChange(of: model.inspectorOpen) { _, open in if !open { contextFocused = true } }
    }

    private var contextBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("概览页面", selection: $model.page) {
                    ForEach(AnalyticsModel.Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 138).focused($contextFocused)
                Picker("项目", selection: $model.scope) {
                    Text("全部项目").tag(BoardScope.all)
                    Text("未分配项目").tag(BoardScope.unassigned)
                    ForEach(model.projects.isEmpty ? (environment.board?.projects ?? []) : model.projects) { project in
                        Text(projectLabel(project)).tag(BoardScope.project(project.id))
                    }
                }.labelsHidden().frame(maxWidth: 250)
                Spacer(minLength: 0)
                if model.loading { ProgressView().controlSize(.small).accessibilityLabel("正在更新分析") }
            }
            if model.page == .review {
                HStack(spacing: 12) {
                    Picker("时间", selection: $model.preset) {
                        ForEach(AnalyticsModel.Preset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 180)
                    if model.preset != .custom, let result = model.result {
                        Text(result.periodLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.preset == .custom {
                    HStack {
                        DatePicker("从", selection: $model.customStart, in: ...Date.now, displayedComponents: .date)
                        DatePicker("至", selection: $model.customEnd, in: ...Date.now, displayedComponents: .date)
                    }.datePickerStyle(.field).font(.callout)
                }
            }
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

    @ViewBuilder private var inspector: some View {
        if let result = model.result {
            AnalyticsDetailView(model: model, environment: environment, result: result)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("事项明细").font(.headline); Spacer(); Button("关闭") { model.closeDetails() }.keyboardShortcut(.cancelAction) }
                Text(model.error ?? "正在更新当前范围…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }.padding(20)
        }
    }

    @ViewBuilder private func currentPage(_ result: AnalyticsResult) -> some View {
        HStack(spacing: 12) {
            metric("待办总数", value: result.active.count.formatted(), caption: "当前仍未完成", detail: .active)
            metric("已逾期", value: result.overdue.count.formatted(), caption: "已超过明确截止时间", detail: .overdue, tint: urgencyColor(overdue: true))
            metric("24小时内到期", value: result.current.upcoming.count.formatted(), caption: "未来24小时，含现在", detail: .upcoming, tint: urgencyColor(overdue: false))
        }
        HStack {
            Button { model.select(.todayCompleted) } label: {
                Label(result.current.todayCompleted.isEmpty ? "今天暂无完成记录" : "今天已完成 \(result.current.todayCompleted.count) 项", systemImage: "checkmark.circle")
            }.buttonStyle(.plain).font(.callout).foregroundStyle(result.current.todayCompleted.isEmpty ? Color.secondary : .green)
            Spacer()
            if !result.deadlineIssues.isEmpty {
                Button("\(result.deadlineIssues.count)项截止时间待确认") { model.select(.deadlineIssues) }.buttonStyle(.link).font(.caption)
            }
        }
        warnings(result)
        preview(result, detail: .attention, title: "需要留意", empty: "当前没有匹配的逾期、临近到期或长期等待的3星事项。")
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待办构成").font(.headline)
                Spacer()
                Picker("查看待办构成", selection: $model.composition) {
                    if model.scope == .all { Text("按项目").tag(AnalyticsModel.Composition.projects) }
                    Text("按星级").tag(AnalyticsModel.Composition.importance)
                    Text("按等待时间").tag(AnalyticsModel.Composition.waiting)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            }
            switch model.composition {
            case .projects:
                if model.scope == .all { AnalyticsDistributionView(result: result, model: model, kind: .projects(.active)) }
                else { importance(result) }
            case .importance: importance(result)
            case .waiting: AnalyticsDistributionView(result: result, model: model, kind: .waiting)
            }
        }
    }

    @ViewBuilder private func reviewPage(_ result: AnalyticsResult) -> some View {
        HStack(spacing: 12) {
            metric("这段时间完成", value: result.completed.count.formatted(), caption: "按完成日期统计", detail: .completed, tint: .green)
            metric("这段时间新增", value: result.created.count.formatted(), caption: "按创建日期统计", detail: .created)
            metric("创建到完成", value: result.review.medianLifetime.map(AnalyticsReview.durationLabel) ?? "—", caption: "中位数 · 含等待 · \(result.review.durations.count)项", detail: .lifetimeAll,
                   info: "将本期完成事项从创建到完成的实际跨度排序，取中间值（偶数取中间两项平均）。包含等待，不代表工时；无法计算的记录单独保留。")
        }
        warnings(result)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("时间分布").font(.headline)
                Spacer()
                Picker("时间展示方式", selection: $model.timeline) {
                    ForEach(AnalyticsModel.Timeline.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            if model.timeline == .trend { AnalyticsDistributionView(result: result, model: model, kind: .trend) }
            else { AnalyticsReviewView(result: result, selected: model.detail, select: model.select, content: .calendar) }
        }
        preview(result, detail: .completed, title: "最近完成", empty: "这段时间暂无完成记录，可换一个日期范围看看。")
        DisclosureGroup("进一步看看", isExpanded: $model.moreAnalysis) {
            VStack(alignment: .leading, spacing: 16) {
                if model.scope == .all { AnalyticsDistributionView(result: result, model: model, kind: .projects(.completed)) }
                AnalyticsReviewView(result: result, selected: model.detail, select: model.select, content: .lifetime)
            }.padding(.top, 14)
        }.font(.callout)
        Button("本期放弃记录 · \(result.abandoned.count) 项") { model.select(.abandoned) }.buttonStyle(.link).font(.caption)
    }

    private func importance(_ result: AnalyticsResult) -> some View {
        AnalyticsReviewView(result: result, selected: model.detail, select: model.select, content: .importance)
    }

    private func metric(_ title: String, value: String, caption: String, detail: AnalyticsDetail, tint: Color = .primary, info: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if let info { AnalyticsInfoButton(message: info) }
            }
            Button {
                if detail == .lifetimeAll { model.moreAnalysis = true }
                model.select(detail)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(title)，\(value)，\(caption)，查看事项")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(.primary.opacity(model.inspectorOpen && model.detail == detail ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func preview(_ result: AnalyticsResult, detail: AnalyticsDetail, title: String, empty: String) -> some View {
        let records = result.records(for: detail)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button("查看全部 \(records.count) 项") { model.select(detail) }.buttonStyle(.link).font(.caption)
                }
                if records.isEmpty { Text(empty).font(.callout).foregroundStyle(.secondary).padding(.vertical, 12) }
                ForEach(Array(records.prefix(5))) { item in
                    Button { model.select(.record(item.id)) } label: {
                        AnalyticsRecordSummary(item: item, result: result, showsProject: model.scope == .all)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, 5)
                    if item.id != records.prefix(5).last?.id { Divider().opacity(0.5) }
                }
            }.padding(10)
        }
    }

    @ViewBuilder private func warnings(_ result: AnalyticsResult) -> some View {
        if !result.scopedIssues.isEmpty || !result.membershipIssues.isEmpty {
            HStack(spacing: 12) {
                if !result.scopedIssues.isEmpty {
                    Button { model.select(.issues) } label: { Label("当前范围 \(result.scopedIssues.count) 项待确认", systemImage: "exclamationmark.circle") }
                }
                if model.scope != .all && !result.membershipIssues.isEmpty {
                    Button("全部项目另有\(result.membershipIssues.count)项归属待确认") { model.select(.membershipIssues) }
                }
                Spacer(minLength: 0)
            }.buttonStyle(.link).font(.caption)
        }
    }

    private func failure(_ error: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("概览未能更新").font(.headline)
                Text(error).font(.callout).textSelection(.enabled)
                if let result = model.result { Text("下方是上次结果，计算于 " + result.now.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
            }
            Spacer(); Button("重试") { model.invalidate() }
        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceNote(_ result: AnalyticsResult) -> some View {
        Text("本地数据 · 计算于 " + result.now.formatted(date: .omitted, time: .shortened) + " · " + result.calendar.timeZone.identifier)
            .font(.caption).foregroundStyle(.secondary)
            .help(environment.sync.lastSuccess.map { "最近云同步：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "离线也可查看本地数据；同步状态见上方控件。")
    }
    private func projectLabel(_ project: Project) -> String {
        model.result?.projectName(.project(project.id)) ?? (project.name + (project.status == .active ? "" : project.status == .archived ? " · 已归档" : " · 已删除"))
    }
    private func urgencyColor(overdue: Bool) -> Color {
        let color = overdue ? environment.appearance.palette.overdue : environment.appearance.palette.end
        // Text stays neutral; a darker/lighter semantic tint works even with a pale custom paper color.
        func component(_ x: Double) -> Double { scheme == .dark ? x * 0.45 + 0.55 : x * 0.55 }
        return Color(red: component(color.red), green: component(color.green), blue: component(color.blue))
    }
}

@MainActor
final class AnalyticsPopoverState: ObservableObject {
    @Published var open = false
}

struct AnalyticsInfoButton: View {
    let message: String
    @StateObject private var state = AnalyticsPopoverState()
    var body: some View {
        Button { state.open.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary) }
            .buttonStyle(.plain).accessibilityLabel("统计说明").popover(isPresented: $state.open) {
                Text(message).font(.callout).textSelection(.enabled).frame(width: 285, alignment: .leading).padding(16)
            }
    }
}
