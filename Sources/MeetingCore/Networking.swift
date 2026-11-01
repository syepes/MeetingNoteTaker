import Foundation
import Security
import Darwin

public enum KeychainStore {
    public static func get(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MeetingNoteTaker", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    public static func analysisAccount(endpoint: String) -> String {
        "analysis-server-" + fingerprint((try? RemoteSpeechConfiguration.normalizedEndpoint(endpoint)) ?? endpoint)
    }
    public static func migrateAnalysisKey(endpoint: String) throws {
        let legacy = get("analysis"); guard !legacy.isEmpty else { return }
        let account = analysisAccount(endpoint: endpoint)
        if get(account).isEmpty { try set(legacy, account: account) }
        try set("", account: "analysis")
    }
    public static func migrateSpeechKey(endpoint: String) throws {
        let legacy = get("speech")
        guard !legacy.isEmpty else { return }
        let account = RemoteSpeechConfiguration.credentialAccount(endpoint: endpoint)
        if get(account).isEmpty { try set(legacy, account: account) }
        // Delete the legacy entry only after its endpoint-scoped replacement exists.
        try set("", account: "speech")
    }
    public static func set(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MeetingNoteTaker", kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query; item[kSecValueData as String] = Data(value.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw MeetingError.message("Keychain save failed (\(status)).") }
    }
}
public enum HTTPClient {
    public static func endpoint(_ base: String, path: String) throws -> URL {
        guard var url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil, url.user == nil, url.password == nil else { throw MeetingError.message("Enter a full HTTP(S) API base URL without credentials.") }
        url.appendPathComponent(path); return url
    }
    public static func send(_ request: URLRequest, session: URLSession = .shared, rejectRedirects: Bool = false) async throws -> Data {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request, delegate: rejectRedirects ? CredentialRedirectBlocker.shared : nil)
                guard let response = response as? HTTPURLResponse else { throw MeetingError.message("Invalid HTTP response.") }
                if (200..<300).contains(response.statusCode) { return data }
                if [408,429,500,502,503,504].contains(response.statusCode), attempt < 2 {
                    let delay = min(30, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt)))
                    try await Task.sleep(for: .seconds(delay)); continue
                }
                throw HTTPFailure(status: response.statusCode, data: data)
            } catch let error as URLError where attempt < 2 && [.timedOut,.networkConnectionLost,.cannotConnectToHost].contains(error.code) {
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw MeetingError.message("The server could not complete the request.")
    }
    public static func json(_ base: String, path: String, body: [String: Any]?, key: String = "", session: URLSession = .shared, authorization: ServerAuthorization? = nil) async throws -> Data {
        var request = URLRequest(url: try endpoint(base, path: path)); request.timeoutInterval = 600
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let authorization { return try await authorization.send(request, session: session) }
        return try await send(request, session: session)
    }
}
public final class NativeProcessSupervisor: @unchecked Sendable {
    private let lock = NSLock(); private var process: Process?; private var launched = false; private var exited = false; private var cancelled = false; private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var memoryTimer: DispatchSourceTimer?
    private var peakBytes: UInt64 = 0
    public var peakResidentBytes: UInt64 { lock.lock(); defer { lock.unlock() }; return peakBytes }
    public init() {}
    public static func helper(_ name: String) throws -> URL {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"), URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/helpers/\(name)")]
        guard let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw MeetingError.message("Missing bundled \(name). Run scripts/build-native.sh and rebuild the app.") }
        return result
    }
    public func run(_ executable: URL, arguments: [String], log: URL, input: FileHandle? = nil, output: FileHandle? = nil) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let p = Process(); p.executableURL = executable; p.arguments = arguments
                FileManager.default.createFile(atPath: log.path, contents: nil)
                do {
                    let out = try FileHandle(forWritingTo: log); p.standardOutput = output ?? out; p.standardError = out; p.standardInput = input
                    p.terminationHandler = { [weak self] process in
                        try? out.close(); self?.didExit()
                        if process.terminationStatus == 0 { continuation.resume() }
                        else { continuation.resume(throwing: MeetingError.message("Local inference stopped (exit \(process.terminationStatus)). See \(log.lastPathComponent).")) }
                    }
                    lock.lock()
                    if cancelled { lock.unlock(); try? out.close(); continuation.resume(throwing: CancellationError()); return }
                    process = p; launched = true
                    do {
                        try p.run()
                        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
                        timer.setEventHandler { [weak self, weak p] in
                            guard let self, let p, p.isRunning else { return }
                            var info = proc_taskinfo()
                            if proc_pidinfo(p.processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 {
                                self.lock.lock(); self.peakBytes = max(self.peakBytes, info.pti_resident_size); self.lock.unlock()
                            }
                        }
                        memoryTimer = timer; timer.resume(); lock.unlock()
                    } catch { process = nil; exited = true; lock.unlock(); try? out.close(); continuation.resume(throwing: error) }
                } catch { continuation.resume(throwing: error) }
            }
            try Task.checkCancellation()
        } onCancel: { self.terminate() }
    }
    public var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return launched && exited }
    private func didExit() {
        lock.lock(); memoryTimer?.cancel(); memoryTimer = nil; process = nil; exited = true; let waiters = exitWaiters; exitWaiters = []; lock.unlock()
        waiters.forEach { $0.resume() }
    }
    public func shutdown() async {
        terminate()
        await withCheckedContinuation { continuation in
            lock.lock()
            if process == nil { lock.unlock(); continuation.resume() }
            else { exitWaiters.append(continuation); lock.unlock() }
        }
    }
    public func terminate() {
        lock.lock(); let alreadyCancelled = cancelled; cancelled = true; let running = process; lock.unlock()
        guard !alreadyCancelled else { return }
        if let running, running.isRunning {
            running.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now()+3) { if running.isRunning { kill(running.processIdentifier, SIGKILL) } }
        }
    }
}

public typealias NativeProcess = NativeProcessSupervisor

/// Retain only the classification, never a server body containing transcript text.
public struct HTTPFailure: LocalizedError {
    public let status: Int
    public let contextOverflow: Bool
    public init(status: Int, data: Data) {
        self.status = status
        let text = String(decoding: data.prefix(16384), as: UTF8.self).lowercased()
        contextOverflow = [400, 413, 422].contains(status) &&
            ["context_length_exceeded", "exceeds the available context", "exceed_context_size", "maximum context length", "too many tokens", "input is too long"].contains(where: text.contains)
    }
    public var errorDescription: String? { contextOverflow ? "The request exceeds the model context." : "Server returned HTTP \(status). Check endpoint, model, and credentials." }
}
