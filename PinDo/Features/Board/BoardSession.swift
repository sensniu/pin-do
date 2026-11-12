import Combine
import Foundation

@MainActor
final class BoardSession: ObservableObject {
    @Published var manualScale: CGFloat?
    @Published var pan = CGSize.zero
    var dragOrigin: CGSize?
    var pinchOrigin: CGFloat?
    var noteDragID: UUID?
    var noteDragOrigin: CGPoint?
    var noteDragScale: CGFloat = 1

    func reset() {
        manualScale = nil
        pan = .zero
        dragOrigin = nil
        pinchOrigin = nil
        endNoteDrag()
    }

    func endNoteDrag() { noteDragID = nil; noteDragOrigin = nil }
}

