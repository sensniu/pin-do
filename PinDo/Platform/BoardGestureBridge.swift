import AppKit
import SwiftUI

/// Captures wheel/trackpad scrolling only inside this board, without stealing card clicks.
struct BoardGestureBridge: NSViewRepresentable {
    let onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> ScrollCaptureView {
        let view = ScrollCaptureView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureView, context: Context) { nsView.onScroll = onScroll }

    static func dismantleNSView(_ nsView: ScrollCaptureView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class ScrollCaptureView: NSView {
        var onScroll: ((CGSize) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
                self.onScroll?(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

