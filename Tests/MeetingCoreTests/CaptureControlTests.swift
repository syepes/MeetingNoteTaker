import XCTest
@testable import MeetingCore

final class CaptureControlTests: XCTestCase {
    @MainActor func testBlockedAudioServiceDoesNotBlockMainActor() async throws {
        let commands = CaptureCommandQueue()
        let entered = expectation(description: "Capture executor entered")
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await commands.perform {
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                // Simulate a synchronous audio-service wait. Only the main actor
                // below can release it, proving the UI executor remains usable.
                return release.wait(timeout: .now() + 2) == .success
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        release.signal()
        let released = try await task.value
        XCTAssertTrue(released)
    }

    @MainActor func testCommandsCannotOvertakeSuspendedStart() async throws {
        let commands = CaptureCommandQueue()
        let entered = expectation(description: "Start suspended")
        let log = ControlLog()
        let start = Task {
            try await commands.perform {
                log.values.append("starting")
                entered.fulfill()
                try await Task.sleep(for: .milliseconds(80))
                log.values.append("started")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        commands.enqueue { log.values.append("pause") }
        commands.enqueue { log.values.append("resume") }
        let values = try await commands.perform { log.values.append("stop"); return log.values }
        try await start.value
        XCTAssertEqual(values, ["starting", "started", "pause", "resume", "stop"])
    }

    @MainActor func testFailedCommandDoesNotPreventStop() async throws {
        let commands = CaptureCommandQueue()
        do { try await commands.perform { throw MeetingError.message("fixture") }; XCTFail("Expected error") } catch {}
        let stopped = try await commands.perform { true }
        XCTAssertTrue(stopped)
    }

    func testHealthPresentationIgnoresPollingCountersButPreservesChanges() {
        let original = CaptureHealthSnapshot()
        var next = original
        next.microphone.lastBufferTime = 20; next.computer.lastBufferTime = 21
        next.availableBytes = 2_000_000_000
        XCTAssertEqual(original.presentation, next.presentation)
        next.microphone.droppedBuffers = 1
        XCTAssertNotEqual(original.presentation, next.presentation)
        next = original; next.storageWarning = "Low disk space"
        XCTAssertNotEqual(original.presentation, next.presentation)
        next = original; next.microphone.availability = .recovering
        XCTAssertNotEqual(original.presentation, next.presentation)
        next = original; next.phase = .paused
        XCTAssertNotEqual(original.presentation, next.presentation)
    }
}

@CaptureControl private final class ControlLog {
    var values: [String] = []
    nonisolated init() {}
}
