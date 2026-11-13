import SwiftUI
import AppKit
import Combine

@MainActor
final class AppearanceDraft: ObservableObject {
    let guardID = UUID()
    @Published var start: String
    @Published var end: String
    @Published var overdue: String
    init(_ palette: NotePalette) { start = palette.start.hex; end = palette.end.hex; overdue = palette.overdue.hex }
    var palette: NotePalette? {
        guard let a = ProjectColor(hex: start), let b = ProjectColor(hex: end), let c = ProjectColor(hex: overdue) else { return nil }
        return NotePalette(start: a, end: b, overdue: c)
    }
    func reset() { start = NotePalette.standard.start.hex; end = NotePalette.standard.end.hex; overdue = NotePalette.standard.overdue.hex }
}
