import AppKit
import SwiftUI

@MainActor
final class QuitController {
    private var gesture = QuitGesture()
    private var monitor: Any?
    private var hold: Task<Void, Never>?
    private var expiration: Task<Void, Never>?
    private var panel: NSPanel?
    private let promptOverride: (() -> Void)?
    var confirmed: (() -> Void)?

    init(prompt: (() -> Void)? = nil) { promptOverride = prompt }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }
    func cancel() {
        gesture.cancel(); hold?.cancel(); expiration?.cancel(); panel?.orderOut(nil)
    }
    func stop() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        let time = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime
        if event.type == .flagsChanged {
            if !event.modifierFlags.contains(.command) {
                let held = gesture.release(at: time); hold?.cancel()
                if held { finish() }
            }
            return event
        }
        let isQ = event.charactersIgnoringModifiers?.lowercased() == "q" || event.keyCode == 12
        if event.type == .keyUp, isQ {
            let held = gesture.release(at: time); hold?.cancel()
            // A busy main loop may receive key-up before the hold timer gets CPU time.
            if held { finish(); return nil }
            return event
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.type == .keyDown, isQ, modifiers == .command else {
            if event.type == .keyDown { cancel() }
            return event
        }
        if gesture.press(at: time, isRepeat: event.isARepeat) { finish(); return nil }
        guard !event.isARepeat else { return nil }
        showPrompt()
        hold?.cancel()
        hold = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(QuitGesture.holdDuration)) } catch { return }
            // Local key-up / modifier changes and application focus loss cancel the tracked hold.
            // Reading global modifier state here can disagree with the event stream being handled.
            guard let self, self.gesture.heldLongEnough(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.finish()
        }
        expiration?.cancel()
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(QuitGesture.doublePressInterval)) } catch { return }
            self?.cancel()
        }
        return nil
    }
    private func finish() { cancel(); confirmed?() }

    func confirmFromMenu() {
        cancel()
        let alert = NSAlert()
        alert.messageText = "退出 PinDo？"
        alert.informativeText = "退出后停止后台同步。待办、草稿和待同步内容会保存在本机，下次打开继续。"
        alert.addButton(withTitle: "退出"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { confirmed?() }
    }
    private func showPrompt() {
        if let promptOverride { promptOverride(); return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 100),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating
            panel.hidesOnDeactivate = true; panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView:
                VStack(spacing: 8) {
                    Text("按住 ⌘Q 以退出 PinDo").font(.system(size: 17, weight: .semibold))
                    Text("或在 2 秒内再按一次 ⌘Q").font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(width: 350, height: 100).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)))
            self.panel = panel
        }
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(x: frame.midX - 175, y: frame.midY - 50))
        }
        panel?.orderFrontRegardless()
    }
}
