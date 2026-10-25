import Combine
import Foundation

@MainActor
final class BoardSession: ObservableObject {
    @Published var manualScale: CGFloat?
    @Published var pan = CGSize.zero
    var dragOrigin: CGSize?
    var pinchOrigin: CGFloat?

    func reset() {
        manualScale = nil
        pan = .zero
        dragOrigin = nil
        pinchOrigin = nil
    }
}

