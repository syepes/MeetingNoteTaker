import SwiftUI

public struct MeetingPlaybackButtons: View {
    @ObservedObject var playback: MeetingPlaybackController
    public init(playback: MeetingPlaybackController) { self.playback = playback }
    public var body: some View {
        Button(playback.state.playing ? "Pause" : "Play", action: playback.togglePlayback)
            .disabled(!playback.state.ready)
    }
}

public struct MeetingPlaybackProgress: View {
    @ObservedObject var playback: MeetingPlaybackController
    public init(playback: MeetingPlaybackController) { self.playback = playback }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(MeetingPlaybackController.time(playback.state.position)).monospacedDigit()
                Slider(value: Binding(get: { playback.state.position }, set: { playback.seek(to: $0) }),
                       in: 0...max(0.001, playback.state.duration), onEditingChanged: { editing in
                    if editing { playback.beginSeeking() } else { playback.endSeeking() }
                })
                .disabled(!playback.state.ready)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(MeetingPlaybackController.time(playback.state.position)) of \(MeetingPlaybackController.time(playback.state.duration))")
                Text(MeetingPlaybackController.time(playback.state.duration)).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            if playback.state.loading { Text("Loading audio…").font(.caption).foregroundStyle(.secondary) }
            if let error = playback.state.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}

/// Observe the actual hosting window; SwiftUI's internal window identifiers are
/// not part of the playback lifecycle contract.
public struct MeetingPlaybackWindowLifecycle: NSViewRepresentable {
    let opened: () -> Void
    let closed: () -> Void
    public init(opened: @escaping () -> Void, closed: @escaping () -> Void) { self.opened = opened; self.closed = closed }
    public func makeNSView(context: Context) -> WindowObserver { WindowObserver() }
    public func updateNSView(_ view: WindowObserver, context: Context) { view.opened = opened; view.closed = closed }
    public final class WindowObserver: NSView {
        var opened: () -> Void = {}
        var closed: () -> Void = {}
        private var observers: [NSObjectProtocol] = []
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
            guard let window else { return }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.closed() })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.opened() })
        }
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
