import SwiftUI
import AppKit
import Combine

@MainActor
final class AppearanceDraft: ObservableObject {
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

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings
    @StateObject private var draft: AppearanceDraft
    @Environment(\.dismiss) private var dismiss
    init(settings: AppearanceSettings) {
        self.settings = settings
        _draft = StateObject(wrappedValue: AppearanceDraft(settings.palette))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("便利贴颜色").font(.title2.weight(.semibold))
            Text("提前七天开始渐变，越接近截止时间越靠近终点色。")
                .font(.callout).foregroundStyle(.secondary)
            row("渐变起点", text: $draft.start)
            row("渐变终点", text: $draft.end)
            row("逾期颜色", text: $draft.overdue)
            let palette = draft.palette ?? settings.palette
            HStack(spacing: 10) {
                preview("较远", color: palette.start)
                preview("临近截止", color: palette.end)
                preview("已逾期", color: palette.overdue)
            }
            LinearGradient(colors: [color(palette.start), color(palette.end)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 8).clipShape(Capsule()).accessibilityHidden(true)
            Text(draft.palette == nil ? "请输入有效的六位颜色值，例如 #A78BDF。" : "逾期始终使用固定颜色；无截止时间的便利贴保持中性灰。")
                .font(.caption).foregroundStyle(draft.palette == nil ? Color.red : Color.secondary)
            Divider()
            HStack {
                Button("恢复默认") { draft.reset() }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let value = draft.palette, settings.save(value) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(draft.palette == nil)
            }
        }.padding(24).frame(width: 500)
    }
    private func color(_ rgb: ProjectColor) -> Color { Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
    private func row(_ title: String, text: Binding<String>) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(get: { color(ProjectColor(hex: text.wrappedValue) ?? NotePalette.standard.start) }, set: { value in
                if let rgb = NSColor(value).usingColorSpace(.sRGB) {
                    text.wrappedValue = ProjectColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent).hex
                }
            }), supportsOpacity: false)
            TextField("#RRGGBB", text: text).font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder).frame(width: 94).accessibilityLabel(title + "颜色值")
        }
    }
    private func preview(_ title: String, color rgb: ProjectColor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text("便利贴内容预览").font(.system(size: 11)).opacity(rgb.secondaryInkOpacity)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .foregroundStyle(rgb.usesWhiteInk ? .white : .black)
            .background(color(rgb), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.15)))
    }
}
