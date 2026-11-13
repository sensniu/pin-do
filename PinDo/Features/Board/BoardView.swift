import SwiftUI

struct BoardView: View {
    var isActive = true
    @ObservedObject var model: BoardModel
    @ObservedObject var clock: BoardClock
    @StateObject private var session = BoardSession()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var boardColor: Color { WorkspaceStyle.canvas(scheme) }
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.22) }

    var body: some View {
        GeometryReader { window in
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let scale = currentScale(size: geometry.size)
                    ZStack {
                        boardColor
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    if session.dragOrigin == nil { session.dragOrigin = session.pan }
                                    session.pan = CGSize(
                                        width: (session.dragOrigin?.width ?? 0) + value.translation.width,
                                        height: (session.dragOrigin?.height ?? 0) + value.translation.height)
                                }
                                .onEnded { _ in session.dragOrigin = nil })
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
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                                .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("board-canvas"))
                                    .onChanged { value in
                                        if session.noteDragID == nil {
                                            session.noteDragID = item.id
                                            session.noteDragOrigin = world
                                            session.noteDragScale = scale
                                            session.manualScale = scale
                                            model.bringToFront(item.id)
                                        }
                                        guard session.noteDragID == item.id, let origin = session.noteDragOrigin else { return }
                                        model.moveNote(item.id, to: ViewportCalculator.draggedPosition(
                                            origin: origin, translation: value.translation, scale: session.noteDragScale))
                                    }
                                    .onEnded { _ in session.endNoteDrag() })
                                .scaleEffect(scale)
                                .position(point)
                                .zIndex(model.zIndex(for: item.id))
                                .accessibilityIdentifier("note-\(item.id)")
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.94)),
                                    removal: .opacity.combined(with: .offset(x: 12, y: -45)).combined(with: .scale(scale: 0.88))
                                ))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .coordinateSpace(name: "board-canvas")
                    .contentShape(Rectangle())
                    .background {
                        if isActive && model.draft == nil {
                            BoardGestureBridge { delta in
                                guard session.noteDragID == nil else { return }
                                session.pan.width += delta.width
                                session.pan.height += delta.height
                            }
                        }
                    }
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                guard session.noteDragID == nil else { return }
                                if session.pinchOrigin == nil { session.pinchOrigin = scale }
                                session.manualScale = clamped((session.pinchOrigin ?? scale) * value.magnification)
                            }
                            .onEnded { _ in session.pinchOrigin = nil }
                    )
                    .clipped()
                    .overlay(alignment: .bottomTrailing) { zoomControls(scale: scale).padding(16) }
                    .onAppear { model.updateViewport(geometry.size) }
                    .onChange(of: geometry.size) { _, size in model.updateViewport(size) }
                    .onChange(of: model.zoomRevision) { _, _ in session.manualScale = clamped(scale * model.zoomFactor) }
                }
            }
            .background(boardColor)
            .allowsHitTesting(model.draft == nil)

        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { if isActive { clock.start(items: model.visibleItems) } }
        .onChange(of: isActive) { _, active in if active { clock.start(items: model.visibleItems) } else { clock.stop() } }
        .onDisappear { clock.stop(); model.flushDraft() }
        .onChange(of: clock.now) { _, _ in clock.update(items: model.visibleItems) }
        .onChange(of: model.items) { _, _ in if isActive { clock.start(items: model.visibleItems) } }
        .onChange(of: model.layoutRevision) { _, _ in resetViewport(); if isActive { clock.start(items: model.visibleItems) } }
        .onChange(of: model.fitRevision) { _, _ in withAnimation(animation) { resetViewport() } }
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

