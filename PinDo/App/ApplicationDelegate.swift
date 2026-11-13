import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let environment = AppEnvironment()
    let quit = QuitController()
    private(set) var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var observations: [AnyCancellable] = []
    private var quitting = false
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = ApplicationLaunchPolicy.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAtLogin = launchedAtLogin || ApplicationLaunchPolicy.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image()
        item.button?.toolTip = "PinDo 便利贴白板"
        item.button?.setAccessibilityLabel("PinDo 菜单")
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu; statusItem = item
        quit.confirmed = { NSApp.terminate(nil) }
        quit.start()
        environment.navigation.$panel.compactMap { $0 }.sink { [weak self] _ in self?.showBoard() }.store(in: &observations)
        NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .NSCalendarDayChanged))
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemClockDidChange))
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.environment.analytics.refresh() } }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.environment.analytics.refresh() } }.store(in: &observations)
        let background = ProcessInfo.processInfo.arguments.contains("--background") ||
            (AppConfiguration.isPrototype && Bundle.main.object(forInfoDictionaryKey: "PinDoPreviewBackground") as? Bool == true)
        if ApplicationLaunchPolicy.showsWindow(isLoginItem: launchedAtLogin, backgroundRequested: background) { showBoard() }
    }

    func showBoard() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = AppConfiguration.windowTitle
            window.identifier = NSUserInterfaceItemIdentifier(AppConfiguration.windowID)
            window.contentMinSize = NSSize(width: 760, height: 560)
            window.isReleasedWhenClosed = false; window.isRestorable = false
            window.delegate = self
            let defaults = UserDefaults.standard
            let hasSavedFrame = defaults.string(forKey: "NSWindow Frame PinDoMainWindow") != nil
            window.setFrameAutosaveName("PinDoMainWindow")
            if let screen = screen(for: hasSavedFrame ? window.frame : nil) {
                let minimum = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize), styleMask: window.styleMask).size
                let frame = WindowSizing.frame(visible: screen.visibleFrame, restored: hasSavedFrame ? window.frame : nil,
                                               minimum: minimum, upgrade: defaults.integer(forKey: WindowSizing.preferenceKey) < WindowSizing.preferenceVersion)
                window.setFrame(frame, display: false)
                window.saveFrame(usingName: "PinDoMainWindow")
                defaults.set(WindowSizing.preferenceVersion, forKey: WindowSizing.preferenceKey)
            }
            window.contentViewController = NSHostingController(rootView: MainWindowView(environment: environment))
            self.window = window
        }
        // A monitor may have been unplugged while the window was closed.
        if let window, let screen = screen(for: window.frame) {
            let minimum = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize), styleMask: window.styleMask).size
            let frame = WindowSizing.frame(visible: screen.visibleFrame, restored: window.frame, minimum: minimum, upgrade: false)
            if frame != window.frame { window.setFrame(frame, display: false) }
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if environment.navigation.mode == .overview { environment.analytics.activate(scope: environment.board?.selectedScope ?? .all) }
    }

    private func screen(for frame: CGRect?) -> NSScreen? {
        if let frame, let candidate = NSScreen.screens.max(by: {
            let a = $0.visibleFrame.intersection(frame), b = $1.visibleFrame.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }), candidate.visibleFrame.intersects(frame) { return candidate }
        return NSScreen.main ?? NSScreen.screens.first
    }

    func resetWindowSize() {
        guard let window, let screen = screen(for: window.frame) else { return }
        let minimum = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize), styleMask: window.styleMask).size
        window.setFrame(WindowSizing.frame(visible: screen.visibleFrame, restored: nil, minimum: minimum, upgrade: false), display: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showBoard(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard environment.navigation.present(nil) else { return false }
        guard environment.board?.flushDraft() != false else {
            environment.notice = "草稿尚未保存，请处理保存错误后再关闭窗口。"; return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) { environment.analytics.deactivate() }
    func applicationDidBecomeActive(_ notification: Notification) {
        environment.login.refresh(); environment.sync.requestSync()
        if window?.isVisible == true, environment.navigation.mode == .overview { environment.analytics.refresh() }
    }
    func applicationDidResignActive(_ notification: Notification) { quit.cancel() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true; quit.cancel()
        Task {
            let canQuit = await environment.prepareToQuit()
            quitting = false
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        quit.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        environment.login.refresh(); environment.sync.refreshStatus()
        menu.removeAllItems()
        add("打开 PinDo", action: #selector(openBoard), to: menu)
        let new = add("新建待办", action: #selector(newTodo), to: menu); new.isEnabled = environment.board != nil
        menu.addItem(.separator())
        let statusText = environment.sync.busy ? "正在同步…" : environment.sync.error == nil ? environment.sync.message : "同步未完成 · 打开设置查看"
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        let sync = add(environment.sync.primaryActionTitle, action: #selector(syncNow), to: menu)
        sync.isEnabled = environment.repository != nil && !environment.sync.busy
        if environment.sync.error != nil || !environment.sync.conflicts.isEmpty { add("查看同步问题…", action: #selector(syncSettings), to: menu) }
        menu.addItem(.separator())
        add("设置…", action: #selector(settings), to: menu)
        add("退出 PinDo…", action: #selector(quitFromMenu), to: menu)
    }
    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }
    @objc private func openBoard() { showBoard() }
    @objc private func newTodo() { showBoard(); environment.newTodo() }
    @objc private func syncNow() { environment.sync.performPrimaryAction() }
    @objc private func syncSettings() { environment.presentSettings(.sync, issues: true) }
    @objc private func settings() { environment.presentSettings() }
    @objc private func quitFromMenu() { quit.confirmFromMenu() }
}
