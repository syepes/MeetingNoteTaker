import AppKit
import SwiftUI

/// MenuBarExtra can retain its largest window size even when its SwiftUI content
/// shrinks. Measure the content independently and resize the actual panel too.
struct MenuPopoverSizing: ViewModifier {
    @State private var contentSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
            .background(MenuPopoverWindowSize(size: contentSize))
    }
}

private struct MenuPopoverWindowSize: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.contentSize = size
        view.scheduleResize()
    }

    final class SizingView: NSView {
        var contentSize: CGSize = .zero
        private var resizeScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                // Also correct a later resize by SwiftUI or a cached size on reopen.
                for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
                }
            }
            scheduleResize()
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func windowChanged(_ notification: Notification) { scheduleResize() }

        func scheduleResize() {
            guard !resizeScheduled else { return }
            resizeScheduled = true
            // Wait until SwiftUI has completed this layout pass, and coalesce
            // updates from progress, recording state, and the window itself.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizeScheduled = false
                self.resizeToContent()
            }
        }

        private func resizeToContent() {
            guard let window, contentSize.width > 0, contentSize.height > 0,
                  contentSize.width.isFinite, contentSize.height.isFinite else { return }
            let size = CGSize(width: ceil(contentSize.width), height: ceil(contentSize.height))
            var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
            guard abs(window.frame.width - frame.width) > 0.5 ||
                    abs(window.frame.height - frame.height) > 0.5 else { return }
            // Keep the menu anchored beneath its status item when it shrinks.
            frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
