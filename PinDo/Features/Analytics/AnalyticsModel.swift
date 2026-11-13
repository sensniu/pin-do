import Combine
import Foundation

@MainActor
final class AnalyticsModel: ObservableObject {
    enum Preset: String, CaseIterable { case week = "近7天", month = "近30天", quarter = "近90天", custom = "自定义" }
    enum Page: String, CaseIterable { case summary = "现在", review = "回顾" }
    enum Composition: String, CaseIterable { case projects = "按项目", importance = "按星级", waiting = "按等待时间" }
    enum Timeline: String, CaseIterable { case trend = "趋势", calendar = "完成日历" }
    @Published var page: Page = .summary { didSet { if page != oldValue { filtersChanged() } } }
    @Published var scope: BoardScope = .all { didSet {
        if scope != oldValue {
            if scope != .all && composition == .projects { composition = .importance }
            filtersChanged()
        }
    } }
    @Published var preset: Preset = .month { didSet { if preset != oldValue && page == .review { filtersChanged() } } }
    @Published var customStart = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now { didSet { if page == .review { filtersChanged() } } }
    @Published var customEnd = Date.now { didSet { if page == .review { filtersChanged() } } }
    @Published var composition: Composition = .projects
    @Published var timeline: Timeline = .trend
    @Published var expandedProjects = false
    @Published var moreAnalysis = false
    @Published var selectedTrend: Date?
    @Published var inspectorOpen = false
    @Published var detail: AnalyticsDetail = .completed
    @Published private(set) var selectionRevision = 0
    @Published private(set) var result: AnalyticsResult?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var projects: [Project] = []
    private(set) var visible = false
    private var provider: (@MainActor () async throws -> AnalyticsInput)?
    private var work: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var generation = 0
    private var initialized = false
    private var dirty = true
    private var cached: AnalyticsInput?

    deinit { work?.cancel(); clock?.cancel() }
    func configure(_ provider: @escaping @MainActor () async throws -> AnalyticsInput) { self.provider = provider; cached = nil; invalidate() }
    func activate(scope: BoardScope) {
        if !initialized { self.scope = scope; initialized = true }
        visible = true; refresh()
    }
    func deactivate() { visible = false; clock?.cancel(); work?.cancel(); generation += 1; loading = false }
    func invalidate() { dirty = true; if visible { refresh() } }
    func select(_ detail: AnalyticsDetail) { self.detail = detail; inspectorOpen = true; selectionRevision += 1 }
    func closeDetails() { inspectorOpen = false }
    private func filtersChanged() {
        inspectorOpen = false; selectedTrend = nil; detail = .completed; result = nil; error = nil
        if visible { refresh() }
    }
    func refresh() {
        guard visible else { return }
        generation += 1; let current = generation
        work?.cancel(); clock?.cancel(); loading = true
        let scope = scope
        let range: AnalyticsRange
        if page == .summary { range = .recent(1) }
        else { switch preset { case .week: range = .recent(7); case .month: range = .recent(30); case .quarter: range = .recent(90); case .custom: range = .custom(customStart, customEnd) } }
        work = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                guard let self, self.visible, current == self.generation else { return }
                let input: AnalyticsInput
                if !self.dirty, let value = self.cached { input = value }
                else {
                    guard let provider = self.provider else { throw AnalyticsFailure.unavailable }
                    input = try await provider()
                }
                try Task.checkCancellation()
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
                let now = Date.now
                let computation = Task.detached(priority: .userInitiated) { try AnalyticsEngine.calculate(input, scope: scope, range: range, now: now, calendar: calendar) }
                let result = try await withTaskCancellationHandler { try await computation.value } onCancel: { computation.cancel() }
                guard self.visible, current == self.generation, !Task.isCancelled else { return }
                self.cached = input; self.projects = input.projects; self.dirty = false; self.result = result; self.error = nil; self.loading = false
                self.clock = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0.1, result.nextRefresh.timeIntervalSinceNow))) } catch { return }
                    self?.refresh()
                }
            } catch is CancellationError { return }
            catch {
                guard let self, current == self.generation else { return }
                self.error = error.localizedDescription; self.loading = false
            }
        }
    }
}
