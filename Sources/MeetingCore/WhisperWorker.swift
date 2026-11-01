import Foundation
import Darwin

/// One pipe worker per transcription job; all requests are sequential.
final class WhisperWorker: @unchecked Sendable {
    private let process = NativeProcessSupervisor()
    private let input = Pipe(), output = Pipe()
    private var task: Task<Void, Error>?
    private var pending = Data()
    let model: String
    private let executableOverride: URL?
    private let startupTimeout: Double
    private let requestTimeout: Double
    init(model: String, executable: URL? = nil, startupTimeout: Double = 180, requestTimeout: Double = 600) {
        self.model = model; executableOverride = executable; self.startupTimeout = startupTimeout; self.requestTimeout = requestTimeout
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func start() async throws {
        let executable = try executableOverride ?? NativeProcess.helper("whisper-worker")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("mnt-whisper-\(UUID()).log")
        task = Task { try await process.run(executable, arguments: [model], log: log, input: input.fileHandleForReading, output: output.fileHandleForWriting) }
        do {
            let ready = try await response(timeout: startupTimeout)
            guard ready["version"] as? Int == 1, ready["ready"] as? Bool == true else { throw MeetingError.message("Invalid Whisper worker handshake.") }
        } catch { await shutdown(); throw error }
    }
    func transcribe(_ url: URL, language: String) async throws -> Data {
        let id = UUID().uuidString
        var data = try JSONSerialization.data(withJSONObject: ["version": 1, "id": id, "path": url.path, "language": language])
        guard data.count < 8192 else { throw MeetingError.message("Whisper request exceeds protocol limit.") }
        data.append(10)
        try Task.checkCancellation()
        guard !process.hasExited else { throw MeetingError.message("Whisper worker exited unexpectedly.") }
        try input.fileHandleForWriting.write(contentsOf: data)
        let result = try await response(timeout: requestTimeout)
        guard result["version"] as? Int == 1, result["id"] as? String == id else { throw MeetingError.message("Whisper response does not match the pending chunk.") }
        if result["error"] != nil { throw MeetingError.message("Whisper could not decode this audio chunk.") }
        return try JSONSerialization.data(withJSONObject: result)
    }
    private func response(timeout: TimeInterval) async throws -> [String: Any] {
        let reader = Task.detached(priority: .userInitiated) { [self] () throws -> Data in
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while true {
                try Task.checkCancellation()
                if let end = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: end); pending.removeSubrange(...end); return Data(line)
                }
                guard pending.count <= 1024*1024 else { throw MeetingError.message("Whisper response exceeds protocol limit.") }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw MeetingError.message("Whisper worker timed out. The job can be resumed.") }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 && errno != EINTR { throw MeetingError.message("Whisper pipe failed.") }
                if ready > 0 {
                    var bytes = [UInt8](repeating: 0, count: 16384)
                    let count = read(descriptor.fd, &bytes, bytes.count)
                    guard count > 0 else { throw MeetingError.message("Whisper worker exited unexpectedly.") }
                    pending.append(contentsOf: bytes.prefix(count))
                }
                // The parent retains the pipe's write handle until cleanup. A completed
                // process is detected separately instead of relying solely on pipe EOF.
                if process.hasExited { throw MeetingError.message("Whisper worker exited unexpectedly.") }
            }
        }
        let data = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel(); self.process.terminate() }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MeetingError.message("Invalid Whisper worker response.") }
        return object
    }
    func cancel() { task?.cancel(); process.terminate() }
    func shutdown() async {
        cancel(); await process.shutdown(); _ = try? await task?.value; task = nil
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting] { try? handle.close() }
    }
}
