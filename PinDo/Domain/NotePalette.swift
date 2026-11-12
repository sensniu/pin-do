import Foundation
import Combine

struct NotePalette: Codable, Equatable, Sendable {
    var start: ProjectColor
    var end: ProjectColor
    var overdue: ProjectColor
    static let standard = NotePalette(
        start: ProjectColor(red: 237.0 / 255, green: 229.0 / 255, blue: 248.0 / 255),
        end: ProjectColor(red: 173.0 / 255, green: 135.0 / 255, blue: 224.0 / 255),
        overdue: ProjectColor(red: 237.0 / 255, green: 196.0 / 255, blue: 186.0 / 255))
    var isValid: Bool { [start, end, overdue].allSatisfy { $0.isValid } }

    func color(for urgency: Urgency) -> ProjectColor {
        if urgency.isOverdue { return overdue }
        let t = min(1, max(0, (urgency.intensity - 0.08) / 0.92))
        return ProjectColor(red: start.red + (end.red - start.red) * t,
                            green: start.green + (end.green - start.green) * t,
                            blue: start.blue + (end.blue - start.blue) * t)
    }
}

extension ProjectColor {
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var hex: String {
        func byte(_ v: Double) -> Int { v.isFinite ? Int((min(1, max(0, v)) * 255).rounded()) : 0 }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }), let bits = UInt32(value, radix: 16) else { return nil }
        self.init(red: Double((bits >> 16) & 255) / 255, green: Double((bits >> 8) & 255) / 255, blue: Double(bits & 255) / 255)
    }
    var secondaryInkOpacity: Double {
        func luminance(_ values: [Double]) -> Double {
            let l = values.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return l[0] * 0.2126 + l[1] * 0.7152 + l[2] * 0.0722
        }
        let base = [red, green, blue], background = luminance(base), ink = usesWhiteInk ? 1.0 : 0.0
        for step in 0...26 {
            let opacity = 0.74 + Double(step) / 100
            let foreground = luminance(base.map { $0 * (1 - opacity) + ink * opacity })
            if (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05) >= 4.5 { return opacity }
        }
        return 1
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    static let key = "appearance.notePalette.v1"
    @Published private(set) var palette: NotePalette
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(NotePalette.self, from: data), decoded.isValid {
            palette = decoded
        } else { palette = .standard }
    }
    @discardableResult func save(_ value: NotePalette) -> Bool {
        guard value.isValid, let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: Self.key)
        palette = value
        return true
    }
}
