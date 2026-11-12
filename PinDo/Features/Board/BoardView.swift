import SwiftUI

struct BoardView: View {
    @ObservedObject var model: BoardModel
    @StateObject private var clock = BoardClock()
    @StateObject private var session = BoardSession()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var boardColor: Color { WorkspaceStyle.canvas(scheme) }
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.22) }

    var body: some View {
        GeometryReader { window in
            VStack(spacing: 0) {
                header.padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 4)
                GeometryReader { geometry in
                    let scale = currentScale(size: geometry.size)
                    ZStack {
                        boardColor
                        if model.visibleItems.isEmpty {
                            emptyState
                        }
                        ForEach(model.visibleItems) { item in
                            if let world = model.layout.positions[item.id] {
                                let point = ViewportCalculator.position(
                                    world: world, bounds: model.viewportBounds, viewport: geometry.size,
                                    scale: scale, pan: session.pan
                                )
                                StickyNoteView(
                                    item: item, now: clock.now, height: model.layout.heights[item.id] ?? NoteMetrics.height(for: item), project: model.project(item.projectID), showsProjectBorder: model.selectedScope == .all, overview: scale < 0.7,
                                    edit: { withAnimation(animation) { model.edit(item) } },
                                    complete: { withAnimation(animation) { model.complete(item.id) } }
                                )
                                .scaleEffect(scale)
                                .position(point)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.94)),
                                    removal: .opacity.combined(with: .offset(x: 12, y: -45)).combined(with: .scale(scale: 0.88))
                                ))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .background {
                        if model.draft == nil {
                            BoardGestureBridge { delta in
                                session.pan.width += delta.width
                                session.pan.height += delta.height
                            }
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                if session.dragOrigin == nil { session.dragOrigin = session.pan }
                                session.pan = CGSize(
                                    width: (session.dragOrigin?.width ?? 0) + value.translation.width,
                                    height: (session.dragOrigin?.height ?? 0) + value.translation.height
                                )
                            }
                            .onEnded { _ in session.dragOrigin = nil }
                    )
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                if session.pinchOrigin == nil { session.pinchOrigin = scale }
                                session.manualScale = clamped((session.pinchOrigin ?? scale) * value.magnification)
                            }
                            .onEnded { _ in session.pinchOrigin = nil }
                    )
                    .clipped()
                    .overlay(alignment: .bottomTrailing) { zoomControls(scale: scale).padding(16) }
                    .onAppear { model.updateViewport(geometry.size) }
                    .onChange(of: geometry.size) { _, size in model.updateViewport(size) }
                }
            }
            .background(boardColor)
            .allowsHitTesting(model.draft == nil)

        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { clock.start(items: model.visibleItems) }
        .onDisappear { clock.stop(); model.flushDraft() }
        .onChange(of: clock.now) { _, _ in clock.update(items: model.visibleItems) }
        .onChange(of: model.items) { _, _ in clock.start(items: model.visibleItems) }
        .onChange(of: model.layoutRevision) { _, _ in resetViewport(); clock.start(items: model.visibleItems) }
        .onChange(of: model.fitRevision) { _, _ in withAnimation(animation) { resetViewport() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.boardTitle).font(.system(size: 17, weight: .semibold))
                .lineLimit(1).help(model.boardTitle)
            let overdue = model.visibleItems.filter { UrgencyPolicy().evaluate(dueAt: $0.dueAt, now: clock.now).isOverdue }.count
            Text("\(model.visibleItems.count) 项" + (overdue > 0 ? " · \(overdue) 项已逾期" : ""))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 8)
            if let receipt = model.undo {
                Text("已完成").font(.system(size: 12)).foregroundStyle(.secondary)
                UndoCountdownView(receipt: receipt) {
                    withAnimation(animation) { model.undoCompletion() }
                }.id(receipt.id)
            }
            Button { withAnimation(animation) { model.beginNew() } } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).help("新增待办 ⌘N")
                .accessibilityLabel("新增待办").accessibilityIdentifier("new-todo")
        }.frame(height: 42)
    }

    private var emptyTitle: String {
        switch model.selectedScope {
        case .all: "从一件小事开始"
        case .unassigned: "这里暂时没有未分配的待办"
        case .project: "为这个项目添加第一件待办"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack").font(.system(size: 34, weight: .ultraLight))
            Text(emptyTitle)
                .font(.system(size: 16, weight: .medium))
            Button("添加待办  ⌘N") { withAnimation(animation) { model.beginNew() } }.buttonStyle(.link)
        }
        .foregroundStyle(.secondary)
    }

    private func zoomControls(scale: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { session.manualScale = clamped(scale / 1.2) } label: {
                Image(systemName: "minus").frame(width: 30, height: 30)
            }.help("缩小")
            Text("\(Int((scale * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced)).frame(width: 46)
            Button { session.manualScale = clamped(scale * 1.2) } label: {
                Image(systemName: "plus").frame(width: 30, height: 30)
            }.help("放大")
            Divider().frame(height: 14).padding(.horizontal, 6)
            Button { withAnimation(animation) { model.fitBoard() } } label: {
                Text("适应").font(.system(size: 11)).frame(width: 38, height: 30)
            }.help("适应白板 ⌘0")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(boardColor, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 1))
    }

    private func currentScale(size: CGSize) -> CGFloat {
        session.manualScale ?? ViewportCalculator.fitScale(bounds: model.viewportBounds, viewport: size)
    }

    private func clamped(_ value: CGFloat) -> CGFloat { min(2, max(0.05, value)) }

    private func resetViewport() {
        session.reset()
    }
}

