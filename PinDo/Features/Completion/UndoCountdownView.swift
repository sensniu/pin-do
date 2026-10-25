import SwiftUI

struct UndoCountdownView: View {
    let receipt: CompletionUndo
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : 1.0 / 30)) { _ in
            let remaining = receipt.remaining(at: ProcessInfo.processInfo.systemUptime)
            Button(action: action) {
                ZStack {
                    Circle().stroke(.primary.opacity(0.12), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: remaining / CompletionUndo.duration)
                        .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .medium))
                }
                .frame(width: 36, height: 36)
                .padding(2)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(remaining <= 0)
            .help("撤回最近完成的一项")
            .accessibilityLabel("撤回最近完成的一项")
            .accessibilityIdentifier("undo-completion")
        }
    }
}

