import Foundation

enum AppConfiguration {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.10.1"
    static var isPrototype: Bool {
        if ProcessInfo.processInfo.arguments.contains("--demo") { return true }
        #if DEBUG
        // A disposable Debug preview bundle can be launched by UI tools without touching a real store.
        return Bundle.main.object(forInfoDictionaryKey: "PinDoPreviewMode") as? Bool == true
        #else
        return false
        #endif
    }
    static var isDevelopment: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    static let windowID = "main-board"
    static var windowTitle: String {
        if isPrototype { return "PinDo · 交互预览" }
        return isDevelopment ? "PinDo · 开发版" : "PinDo"
    }
}

