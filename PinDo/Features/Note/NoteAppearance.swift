import SwiftUI

struct NoteAppearance {
    let urgency: Urgency
    let scheme: ColorScheme

    var fill: Color {
        if urgency.band == .noDeadline {
            return scheme == .dark ? Color(white: 0.21) : Color(white: 0.94)
        }
        if urgency.isOverdue { return Color(red: 0.96, green: 0.73, blue: 0.69) }
        let intensity = urgency.intensity
        return Color(
            red: 0.96 - 0.23 * intensity,
            green: 0.94 - 0.40 * intensity,
            blue: 0.99 - 0.06 * intensity
        )
    }

    var ink: Color {
        if urgency.band == .noDeadline && scheme == .dark { return .white }
        // Colored paper stays light in both modes, so black keeps it legible.
        return .black
    }

    func border(category: TodoCategory?) -> Color {
        guard let category else { return ink.opacity(0.12) }
        let boost = scheme == .dark ? 0.18 : 0.0
        return Color(
            red: min(1, category.red + boost),
            green: min(1, category.green + boost),
            blue: min(1, category.blue + boost)
        )
    }
}

struct StarsView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in
                Image(systemName: "star.fill").font(.system(size: 10, weight: .medium))
            }
        }
        .accessibilityLabel("重要程度 \(count) 颗星")
    }
}

