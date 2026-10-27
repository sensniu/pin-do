import SwiftUI

struct BoardView: View {
    @ObservedObject var model: BoardModel
    var toggleSidebar: () -> Void = {}
    @StateObject private var clock = BoardClock()
    @StateObject private var session = BoardSession()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var boardColor: Color { scheme == .dark ? .black : .white }
    private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.22) }

    var body: some View {
        GeometryReader { window in
            VStack(spacing: 0) {
                header.padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 8)
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
                                    world: world, bounds: model.layout.bounds, viewport: geometry.size,
                                    scale: scale, pan: session.pan
                                )
                                StickyNoteView(
                                    item: item, now: clock.now, project: model.project(item.projectID),
                                    edit: { model.edit(item) },
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
                    .overlay(alignment: .bottomTrailing) { zoomControls(scale: scale).padding(20) }
                }
                footer.padding(.horizontal, 30).padding(.bottom, 16).padding(.top, 8)
            }
            .background(boardColor)
            .allowsHitTesting(model.draft == nil)

        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear { clock.start(items: model.visibleItems) }
        .onDisappear { clock.stop(); model.flushDraft() }
        .onChange(of: clock.now) { _, _ in clock.update(items: model.visibleItems) }
        .onChange(of: model.items) { _, _ in clock.start(items: model.visibleItems) }
        .onChange(of: model.layoutRevision) { _, _ in resetViewport(); clock.start(items: model.visibleItems) }
        .onChange(of: model.fitRevision) { _, _ in withAnimation(animation) { resetViewport() } }
        .alert("操作未保存", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.boardTitle).font(.system(size: 23, weight: .semibold)).lineLimit(1).help(model.boardTitle)
                let overdue = model.visibleItems.filter { UrgencyPolicy().evaluate(dueAt: $0.dueAt, now: clock.now).isOverdue }.count
                Text("\(model.visibleItems.count) 项待办" + (overdue > 0 ? " · \(overdue) 项已逾期" : ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.right").font(.system(size: 18)).frame(width: 36, height: 40)
            }
            .buttonStyle(.plain)
            .help("显示或隐藏项目栏")
            .accessibilityLabel("项目侧栏")
            if let receipt = model.undo {
                UndoCountdownView(receipt: receipt) {
                    withAnimation(animation) { model.undoCompletion() }
                }
                .id(receipt.id)
                .padding(.trailing, 10)
            }
            Button { withAnimation(animation) { model.beginNew() } } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 42, height: 42)
                    .background(scheme == .dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            }
            .buttonStyle(.plain)
            .help("新增待办 ⌘N")
            .accessibilityLabel("新增待办")
            .accessibilityIdentifier("new-todo")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text(AppConfiguration.isPrototype ? "交互预览 · 示例与本次修改暂不保存" : "本地保存 · " + (AppConfiguration.isDevelopment ? "开发数据" : "v\(AppConfiguration.version)"))
            Spacer()
            Text("点击编辑 · 双指缩放 · 滚动浏览")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack").font(.system(size: 34, weight: .ultraLight))
            Text("留一点空间，给下一件事。")
                .font(.system(size: 16, weight: .medium))
            Button("添加一张便利贴") { model.beginNew() }.buttonStyle(.link)
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
            Button { withAnimation(animation) { resetViewport() } } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 30, height: 30)
            }.help("适应白板 ⌘0")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(boardColor, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 1))
    }

    private func currentScale(size: CGSize) -> CGFloat {
        session.manualScale ?? ViewportCalculator.fitScale(bounds: model.layout.bounds, viewport: size)
    }

    private func clamped(_ value: CGFloat) -> CGFloat { min(2, max(0.05, value)) }

    private func resetViewport() {
        session.reset()
    }
}

