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
    private lazy var login = LoginItemController(canConfigure:
        !AppConfiguration.isDevelopment && !AppConfiguration.isPrototype &&
        Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path == "/Applications")

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
        Publishers.Merge4(environment.$managingProjects, environment.$managingAppearance,
                          environment.sync.$showingSettings, environment.sync.$showingConflicts)
            .filter { $0 }.sink { [weak self] _ in self?.showBoard() }.store(in: &observations)
        let background = ProcessInfo.processInfo.arguments.contains("--background") ||
            (AppConfiguration.isPrototype && Bundle.main.object(forInfoDictionaryKey: "PinDoPreviewBackground") as? Bool == true)
        if ApplicationLaunchPolicy.showsWindow(isLoginItem: launchedAtLogin, backgroundRequested: background) { showBoard() }
    }

    func showBoard() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 850),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = AppConfiguration.windowTitle
            window.identifier = NSUserInterfaceItemIdentifier(AppConfiguration.windowID)
            window.contentMinSize = NSSize(width: 760, height: 560)
            window.isReleasedWhenClosed = false; window.isRestorable = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: MainWindowView(environment: environment))
            window.center(); window.setFrameAutosaveName("PinDoMainWindow")
            self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showBoard(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard environment.board?.flushDraft() != false else {
            environment.notice = "草稿尚未保存，请处理保存错误后再关闭窗口。"; return false
        }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        login.refresh(); environment.sync.requestSync()
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
        login.refresh(); environment.sync.refreshStatus()
        menu.removeAllItems()
        add("打开白板", action: #selector(openBoard), to: menu)
        let statusText = environment.sync.busy ? "正在同步…" : environment.sync.error == nil ? environment.sync.message : "同步未完成 · 打开设置查看"
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        let sync = add("立即同步", action: #selector(syncNow), to: menu)
        sync.isEnabled = environment.sync.enabled && !environment.sync.busy
        add("WebDAV 同步设置…", action: #selector(syncSettings), to: menu)
        menu.addItem(.separator())
        let launch = add(login.label, action: #selector(toggleLogin), to: menu)
        launch.state = login.status == .enabled ? .on : login.status == .requiresApproval ? .mixed : .off
        launch.isEnabled = login.canConfigure
        if !login.canConfigure {
            let info = NSMenuItem(title: "安装到应用程序后可设置自启", action: nil, keyEquivalent: "")
            info.isEnabled = false; menu.addItem(info)
        }
        if login.status == .requiresApproval { add("在系统设置中允许…", action: #selector(loginSettings), to: menu) }
        menu.addItem(.separator())
        add("退出 PinDo…", action: #selector(quitFromMenu), to: menu)
    }
    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }
    @objc private func openBoard() { showBoard() }
    @objc private func syncNow() { environment.sync.requestSync() }
    @objc private func syncSettings() { showBoard(); environment.sync.showingSettings = true }
    @objc private func loginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func quitFromMenu() { quit.confirmFromMenu() }
    @objc private func toggleLogin() {
        login.setEnabled(login.status == .off || login.status == .unavailable)
        if let error = login.error { showBoard(); environment.notice = error }
        else if login.status == .requiresApproval {
            showBoard(); environment.notice = "开机自启等待系统允许，请从菜单栏打开系统登录项设置完成授权。"
        }
    }
}
