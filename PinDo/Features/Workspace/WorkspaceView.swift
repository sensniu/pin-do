import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var navigation: AppNavigation
    @StateObject private var clock = BoardClock()
    @EnvironmentObject private var sync: SyncCoordinator
    @EnvironmentObject private var settings: AppearanceSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    toolbar
                    Divider().opacity(0.5)
                    ZStack {
                        VStack(spacing: 0) {
                            if navigation.mode == .board {
                                ProjectTabBarView(model: model)
                                Divider().opacity(0.5)
                            }
                            BoardView(isActive: navigation.mode == .board, model: model, clock: clock)
                        }
                        .opacity(navigation.mode == .board ? 1 : 0)
                        .allowsHitTesting(navigation.mode == .board)
                        .disabled(navigation.mode != .board)
                        .accessibilityHidden(navigation.mode != .board)
                        AnalyticsView(model: environment.analytics, environment: environment)
                            .opacity(navigation.mode == .overview ? 1 : 0)
                            .allowsHitTesting(navigation.mode == .overview)
                            .disabled(navigation.mode != .overview)
                            .accessibilityHidden(navigation.mode != .overview)
                    }
                }
                .allowsHitTesting(model.draft == nil || navigation.mode == .overview)
                .accessibilityHidden(model.draft != nil && navigation.mode == .board)
                if let draft = model.draft, navigation.mode == .board {
                    Color.black.opacity(scheme == .dark ? 0.35 : 0.10).ignoresSafeArea()
                    NoteEditorView(
                        draft: draft, now: .now, showsProjectBorder: model.selectedScope == .all,
                        projects: model.activeProjects, projectLabel: model.projectLabel,
                        maxHeight: max(320, geometry.size.height - 48),
                        submit: { model.submit($0) }, cancel: { model.cancelEditing() },
                        abandon: { model.abandon($0) }, complete: { model.completeEditing($0) },
                        draftChanged: { model.updateDraft($0) }
                    )
                    .id(draft.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .background(WorkspaceStyle.canvas(scheme))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.draft?.id)
            .overlay(alignment: .topTrailing) {
                if let notice = model.notice {
                    Text(notice).font(.system(size: 12)).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 100).padding(.trailing, 24)
                        .accessibilityLabel(notice)
                        .task(id: notice) {
                            do { try await Task.sleep(for: .seconds(3)) } catch { return }
                            if model.notice == notice { model.notice = nil }
                        }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .alert("操作未保存", isPresented: Binding(get: { model.errorMessage != nil && navigation.panel == nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("工作区", selection: Binding(get: { navigation.mode }, set: { environment.setWorkspace($0) })) {
                ForEach(WorkspaceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 154)
            if navigation.mode == .board && navigation.overviewReturnAvailable {
                Button("返回概览") { environment.setWorkspace(.overview) }.font(.caption).buttonStyle(.link)
            }
            if navigation.mode == .board {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text(model.boardTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(maxWidth: 240)
                        boardCount
                    }.fixedSize(horizontal: true, vertical: false)
                    boardCount
                }.help(model.boardTitle)
                Spacer(minLength: 0)
                Button { animate { model.reorderBoard() } } label: {
                    Image(systemName: "square.grid.3x3").font(.system(size: 15)).frame(width: 30, height: 32)
                }.buttonStyle(.plain).help("重新排列当前白板（覆盖手动位置）")
                    .accessibilityLabel("重新排列当前白板").accessibilityIdentifier("reorder-board")
                SyncRefreshButton(sync: sync)
                if let receipt = model.undo {
                    UndoCountdownView(receipt: receipt) { animate { model.undoCompletion() } }.id(receipt.id)
                }
                Button { animate { model.beginNew() } } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .medium)).frame(width: 32, height: 32)
                        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help("新建待办 ⌘N").accessibilityLabel("新建待办").accessibilityIdentifier("new-todo")
            } else {
                Spacer(minLength: 0)
                SyncRefreshButton(sync: sync)
            }
            Button { environment.presentSettings() } label: { Image(systemName: "gearshape").frame(width: 28, height: 32) }
                .buttonStyle(.plain).help("设置 ⌘,").accessibilityLabel("设置")
        }.frame(height: 44).padding(.horizontal, 20)
    }

    private var boardCount: some View {
        let overdue = model.visibleItems.filter { UrgencyPolicy().evaluate(dueAt: $0.dueAt, now: clock.now).isOverdue }.count
        return Text("\(model.visibleItems.count) 项" + (overdue > 0 ? " · \(overdue) 项已逾期" : ""))
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
    }

    private func animate(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22), action)
    }
}
