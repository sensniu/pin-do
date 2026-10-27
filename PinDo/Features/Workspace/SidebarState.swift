import Combine
import Foundation

@MainActor
final class SidebarState: ObservableObject {
    @Published var shown: Bool
    @Published var pinned: Bool
    @Published var width: CGFloat
    @Published var managing = false
    var dragStart: CGFloat?
    private let defaults: UserDefaults
    private let prefix = "projects.sidebar."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rememberedPin = defaults.bool(forKey: "projects.sidebar.pinned")
        pinned = rememberedPin
        shown = rememberedPin
        let saved = defaults.double(forKey: prefix + "width")
        width = saved.isFinite && saved >= 200 ? min(420, saved) : 240
    }
    func toggle() {
        shown.toggle()
        if !shown { pinned = false; save() }
    }
    func togglePinned() { pinned.toggle(); shown = true; save() }
    func save() {
        defaults.set(pinned, forKey: prefix + "pinned")
        defaults.set(Double(width), forKey: prefix + "width")
    }
    func effectiveWidth(window: CGFloat) -> CGFloat { min(width, max(200, min(420, window - 480))) }
}
