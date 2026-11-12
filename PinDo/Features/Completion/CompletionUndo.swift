import Foundation

struct CompletionUndo: Identifiable {
    let id: UUID
    let itemID: UUID
    let originalPosition: CGPoint
    let originalHeight: CGFloat
    var originalFrame: CGRect { BoardLayoutEngine.frame(at: originalPosition, height: originalHeight) }
    let startedAt: TimeInterval
    let scope: BoardScope
    let item: TodoItem
    static let duration: TimeInterval = 3

    func remaining(at uptime: TimeInterval) -> TimeInterval {
        max(0, Self.duration - (uptime - startedAt))
    }
}

