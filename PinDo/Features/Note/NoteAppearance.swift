import SwiftUI

struct NoteAppearance {
    let urgency: Urgency
    let scheme: ColorScheme

    var palette: NotePalette = .standard
    var paper: ProjectColor {
        if urgency.band == .noDeadline {
            let gray = scheme == .dark ? 0.24 : 0.96
            return ProjectColor(red: gray, green: gray, blue: gray)
        }
        return palette.color(for: urgency)
    }
    var fill: Color { Color(red: paper.red, green: paper.green, blue: paper.blue) }
    var ink: Color { paper.usesWhiteInk ? .white : .black }
    var secondaryOpacity: Double { paper.secondaryInkOpacity }

    func border(project: Project?) -> Color {
        guard let project else { return ink.opacity(0.12) }
        let boost = scheme == .dark ? 0.18 : 0.0
        return Color(
            red: min(1, project.red + boost),
            green: min(1, project.green + boost),
            blue: min(1, project.blue + boost)
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


/// Shared neutral surfaces. Deadline and project colors keep their own meaning.
enum WorkspaceStyle {
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.098, green: 0.102, blue: 0.118) : Color(red: 0.969, green: 0.969, blue: 0.976)
    }
}
