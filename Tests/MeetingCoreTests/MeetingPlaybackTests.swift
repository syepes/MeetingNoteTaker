import XCTest
import AVFoundation
import SwiftUI
import AppKit
@testable import MeetingCore

final class MeetingPlaybackTests: XCTestCase {
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Playback state did not settle")
    }
    private func selection(_ name: String = "fixture") -> PlaybackSelection { .init(id: UUID(), url: URL(fileURLWithPath: "/tmp/" + name), version: "1") }

    @MainActor func testSeekStopAndScrubResume() async throws {
        let device = FakePlaybackDevice()
        let controller = MeetingPlaybackController(factory: { _ in device })
        controller.select(selection())
        try await wait { controller.state.ready }
        controller.seek(to: 500); controller.play()
        try await wait { controller.state.playing && controller.state.position == 500 }
        controller.togglePlayback()
        try await wait { !device.isPlaying }
        XCTAssertEqual(controller.state.position, 500)
        controller.togglePlayback()
        try await wait { device.isPlaying }
        XCTAssertEqual(controller.state.position, 500)
        controller.beginSeeking(); controller.seek(to: 200)
        try await wait { !controller.state.playing }
        controller.endSeeking()
        try await wait { controller.state.playing && controller.state.position == 200 }
        controller.stop()
        try await wait { !device.isPlaying && device.currentTime == 0 }
        controller.beginSeeking(); controller.seek(to: 120); controller.endSeeking()
        try await wait { device.currentTime == 120 }
        XCTAssertFalse(controller.state.playing)
        controller.seek(to: -10); try await wait { device.currentTime == 0 }
        controller.seek(to: 99999); try await wait { device.currentTime == 7200 }
        controller.seek(to: .nan); XCTAssertTrue(controller.state.position.isFinite)
        await controller.releaseAndWait()
    }

    @MainActor func testCompletionReplayAndRelease() async throws {
        let device = FakePlaybackDevice()
        let controller = MeetingPlaybackController(factory: { _ in device })
        controller.select(selection()); try await wait { controller.state.ready }
        controller.play(); try await wait { controller.state.playing }
        device.stop() // Simulated natural completion, detected by the progress timer.
        try await wait { !controller.state.playing && controller.state.position == 7200 }
        controller.play(); try await wait { controller.state.playing && controller.state.position == 0 }
        await controller.releaseAndWait()
        XCTAssertNil(controller.selection); XCTAssertFalse(controller.state.ready); XCTAssertFalse(device.isPlaying)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.state.position, 0)
    }

    @MainActor func testStaleLoadAndMissingFile() async throws {
        let controller = MeetingPlaybackController(factory: { url in
            XCTAssertFalse(Thread.isMainThread)
            if url.lastPathComponent == "slow" { Thread.sleep(forTimeInterval: 0.05); return FakePlaybackDevice() }
            throw MeetingError.message("Missing fixture")
        })
        controller.select(selection("slow")); controller.select(selection("missing"))
        try await wait { controller.state.error != nil }
        XCTAssertEqual(controller.selection?.url.lastPathComponent, "missing")
        XCTAssertFalse(controller.state.ready)
        controller.select(selection("slow")); await controller.releaseAndWait()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.selection); XCTAssertNil(controller.state.error); XCTAssertFalse(controller.state.ready)
    }

    @MainActor func testGeneratedAudioLoadsAndSeeksWithoutAutoplay() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        buffer.floatChannelData![0].update(repeating: 0, count: 16000)
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let controller = MeetingPlaybackController()
        controller.select(.init(id: UUID(), url: url, version: "1"))
        try await wait { controller.state.ready || controller.state.error != nil }
        XCTAssertNil(controller.state.error); XCTAssertEqual(controller.state.duration, 1, accuracy: 0.01)
        XCTAssertFalse(controller.state.playing)
        controller.seek(to: 0.5); try await wait { abs(controller.state.position - 0.5) < 0.01 }
        await controller.releaseAndWait()
    }

    @MainActor func testNativePlaybackLayoutAndCorruptAudio() async throws {
        _ = NSApplication.shared
        let controller = MeetingPlaybackController(factory: { _ in FakePlaybackDevice() })
        controller.select(selection()); try await wait { controller.state.ready }
        controller.seek(to: 125)
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 12) {
                HStack { MeetingPlaybackButtons(playback: controller) }
                MeetingPlaybackProgress(playback: controller)
            }.padding(20).frame(width: 620).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            var windowClosed = false
            let host = NSHostingView(rootView: view.background(MeetingPlaybackWindowLifecycle(opened: {}, closed: { windowClosed = true })))
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            XCTAssertEqual(size.width, 620); XCTAssertGreaterThan(size.height, 60)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.setFrameSize(size); host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("playback-\(scheme == .dark ? "dark" : "light").png"))
            window.close()
            XCTAssertTrue(windowClosed, "Closing the actual hosting window must release playback regardless of its identifier")
        }
        await controller.releaseAndWait()
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: bad) }
        try Data("not audio".utf8).write(to: bad)
        let real = MeetingPlaybackController()
        real.select(.init(id: UUID(), url: bad, version: "1"))
        try await wait { real.state.error != nil }
        XCTAssertFalse(real.state.ready)
        await real.releaseAndWait()
    }

    func testTimeLabels() {
        XCTAssertEqual(MeetingPlaybackController.time(0), "00:00")
        XCTAssertEqual(MeetingPlaybackController.time(65), "01:05")
        XCTAssertEqual(MeetingPlaybackController.time(7265), "2:01:05")
        XCTAssertEqual(MeetingPlaybackController.time(.nan), "00:00")
    }
}

private final class FakePlaybackDevice: PlaybackDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 0
    private var playing = false
    var duration: Double { 7200 }
    var currentTime: Double { get { lock.withLock { time } } set { lock.withLock { time = newValue } } }
    var isPlaying: Bool { lock.withLock { playing } }
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { lock.withLock { playing = true }; return true }
    func pause() { lock.withLock { playing = false } }
    func stop() { lock.withLock { playing = false } }
}
