import AppKit

/// Uses the same font, width, line spacing and truncation limits as the card.
enum NoteMetrics {
    static let width: CGFloat = 212
    static let padding: CGFloat = 10
    static let minimumHeight: CGFloat = 112
    static let maximumHeight: CGFloat = 200

    static func height(for item: TodoItem) -> CGFloat {
        let title = textHeight(item.title, size: 16, weight: .semibold, lines: 2)
        let notes = item.notes.isEmpty ? 0 : textHeight(item.notes, size: 12, weight: .regular, lines: 3) + 4
        // Paper inset, header, title separation, bottom breathing room and deadline.
        return min(maximumHeight, max(minimumHeight, ceil(20 + 28 + 4 + title + notes + 8 + 14 + (item.plannedStartAt != nil ? 6 : 0))))
    }

    private static func textHeight(_ text: String, size: CGFloat, weight: NSFont.Weight, lines: Int) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .paragraphStyle: paragraph])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width - padding * 2, height: 10_000))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lines
        container.lineBreakMode = .byTruncatingTail
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}
