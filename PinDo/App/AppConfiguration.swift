import Foundation

enum AppConfiguration {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    static let isPrototype = ProcessInfo.processInfo.arguments.contains("--demo")
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

