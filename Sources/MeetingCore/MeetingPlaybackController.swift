import Foundation
import AVFoundation
import Combine

public struct PlaybackSelection: Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let version: String
    public init(id: UUID, url: URL, version: String) { self.id = id; self.url = url; self.version = version }
}

public struct MeetingPlaybackState: Equatable, Sendable {
    public var loading = false
    public var playing = false
    public var duration: Double = 0
    public var position: Double = 0
    public var error: String?
    public var ready: Bool { !loading && error == nil && duration.isFinite && duration > 0 }
}

protocol PlaybackDevice: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}
extension AVAudioPlayer: PlaybackDevice {}

/// Only playback views observe this object; time ticks never invalidate AppModel.
@MainActor public final class MeetingPlaybackController: ObservableObject {
    @Published public private(set) var state = MeetingPlaybackState()
    public private(set) var selection: PlaybackSelection?
    private let worker: PlaybackWorker
    private var revision: UInt64 = 0
    private var scrubbing = false
    private var resumeAfterScrub = false

    public convenience init() { self.init(factory: { try AVAudioPlayer(contentsOf: $0) }) }
    init(factory: @escaping @Sendable (URL) throws -> PlaybackDevice) { worker = PlaybackWorker(factory: factory) }

    public func select(_ selection: PlaybackSelection?) {
        guard self.selection != selection else { return }
        self.selection = selection; scrubbing = false; resumeAfterScrub = false
        state = .init(loading: selection != nil)
        send { $0.load(selection?.url) }
    }
    public func release() {
        selection = nil; scrubbing = false; resumeAfterScrub = false; state = .init()
        send { $0.load(nil) }
    }
    /// Wait before deleting/replacing a file so the player releases its handle first.
    public func releaseAndWait() async { release(); await worker.flush() }
    public func waitForPendingOperations() async { await worker.flush() }
    public func play() { guard state.ready else { return }; send { $0.play() } }
    public func togglePlayback() {
        guard state.ready else { return }
        if state.playing {
            resumeAfterScrub = false
            state.playing = false
            send { $0.pause() }
        } else {
            state.playing = true
            play()
        }
    }
    public func stop() {
        guard selection != nil else { return }
        scrubbing = false; resumeAfterScrub = false; state.position = 0; state.playing = false
        send { $0.stop() }
    }
    public func beginSeeking() {
        guard state.ready, !scrubbing else { return }
        scrubbing = true; resumeAfterScrub = state.playing
        send { $0.pause() }
    }
    public func seek(to value: Double) {
        guard state.ready, value.isFinite else { return }
        state.position = min(state.duration, max(0, value))
        if !scrubbing { let position = state.position; send { $0.seek(position, resume: nil) } }
    }
    public func endSeeking() {
        guard scrubbing else { return }
        scrubbing = false
        let position = state.position, resume = resumeAfterScrub
        resumeAfterScrub = false
        send { $0.seek(position, resume: resume) }
    }
    private func send(_ operation: @escaping @Sendable (PlaybackWorker) -> Void) {
        revision &+= 1
        let expected = revision
        worker.submit(operation) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.revision == expected else { return }
                if self.scrubbing {
                    self.state.playing = false
                    if let error = snapshot.error { self.state.error = error }
                } else { self.state = snapshot }
            }
        }
    }
    nonisolated public static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(min(Double(Int.max / 2), max(0, seconds))) : 0
        if value >= 3600 { return String(format: "%d:%02d:%02d", value/3600, value/60%60, value%60) }
        return String(format: "%02d:%02d", value/60, value%60)
    }
}

/// All player access and file opening are confined to this serial queue.
private nonisolated final class PlaybackWorker: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingNoteTaker.playback", qos: .userInitiated)
    private let factory: @Sendable (URL) throws -> PlaybackDevice
    private var player: PlaybackDevice?
    private var timer: DispatchSourceTimer?
    private var report: (@Sendable (MeetingPlaybackState) -> Void)?
    private var error: String?
    private var finished = false
    init(factory: @escaping @Sendable (URL) throws -> PlaybackDevice) { self.factory = factory; super.init() }
    deinit {
        timer?.cancel()
        let cleanup = PlaybackCleanup(player: player)
        queue.async { cleanup.player?.stop() }
    }
    func submit(_ operation: @escaping @Sendable (PlaybackWorker) -> Void, report: @escaping @Sendable (MeetingPlaybackState) -> Void) {
        queue.async { self.report = report; operation(self); self.publish() }
    }
    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    func load(_ url: URL?) {
        haltTimer(); player?.stop(); player = nil; error = nil; finished = false
        guard let url else { return }
        do {
            let value = try factory(url)
            guard value.duration.isFinite, value.duration > 0, value.prepareToPlay() else {
                throw MeetingError.message("This audio file cannot be played.")
            }
            (value as? AVAudioPlayer)?.delegate = self
            player = value
        } catch { self.error = "Unable to open meeting audio: \(error.localizedDescription)" }
    }
    func play() {
        guard let player else { return }
        if finished || player.currentTime >= player.duration { player.currentTime = 0 }
        finished = false
        guard player.play() else { error = "Unable to start audio playback."; haltTimer(); return }
        startTimer()
    }
    func pause() { player?.pause(); haltTimer() }
    func stop() { finished = false; player?.stop(); player?.currentTime = 0; haltTimer() }
    func seek(_ position: Double, resume: Bool?) {
        guard let player else { return }
        let shouldResume = resume ?? player.isPlaying
        finished = false
        player.pause(); haltTimer()
        player.currentTime = min(player.duration, max(0, position))
        if shouldResume && position < player.duration { play() }
    }
    private func startTimer() {
        haltTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, let player = self.player else { return }
            if !player.isPlaying {
                self.finished = true
                self.haltTimer()
            }
            self.publish()
        }
        self.timer = timer; timer.resume()
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        queue.async {
            guard let current = self.player, ObjectIdentifier(current) == identity else { return }
            self.finished = flag
            if !flag { self.error = "Audio playback ended unexpectedly." }
            self.haltTimer(); self.publish()
        }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        let message = error?.localizedDescription ?? "Invalid audio data"
        queue.async {
            guard let current = self.player, ObjectIdentifier(current) == identity else { return }
            self.error = "Unable to decode meeting audio: \(message)"
            current.stop(); self.haltTimer(); self.publish()
        }
    }
    private func haltTimer() { timer?.cancel(); timer = nil }
    private func publish() {
        report?(.init(playing: player?.isPlaying ?? false, duration: player?.duration ?? 0,
                      position: player.map { finished ? $0.duration : min($0.duration, max(0, $0.currentTime)) } ?? 0, error: error))
    }
}

// Transfers the last owned reference during worker deinitialization. No player
// operations remain in flight; destruction and stop still occur on its queue.
private struct PlaybackCleanup: @unchecked Sendable { let player: PlaybackDevice? }
