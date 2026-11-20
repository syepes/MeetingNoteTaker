import Foundation
import Darwin

public protocol AnalysisProvider: AnyObject {
    func prepare() async throws
    func generate(system: String, input: String) async throws -> String
    func cancel()
    func shutdown() async
    func countTokens(system: String, input: String) async throws -> InputTokenCount
    func configureEvidence(_ ids: Set<String>)
    func configureContract(_ contract: AnalysisContract)
}
public extension AnalysisProvider {
    func configureEvidence(_ ids: Set<String>) {}
    func configureContract(_ contract: AnalysisContract) {}
    func shutdown() async { cancel() }
    func countTokens(system: String, input: String) async throws -> InputTokenCount {
        .init(tokens: system.utf8.count + input.utf8.count + 1024, accuracy: .conservative)
    }
}
public final class ChatAnalysisProvider: AnalysisProvider, @unchecked Sendable {
    let settings: AnalysisSettings
    var endpoint: String
    var key: String
    var process: NativeProcess?
    var serverTask: Task<Void, Error>?
    private let httpSession: URLSession
    private let authorization: ServerAuthorization?
    private var supportsCounting: Bool?
    private var countCache: [String: InputTokenCount] = [:]
    private var contract = AnalysisContract(kind: .actionItems)
    public func configureContract(_ contract: AnalysisContract) { self.contract = contract }
    private var allowedEvidence: Set<String> = []
    public var peakResidentBytes: UInt64 { process?.peakResidentBytes ?? 0 }
    public func configureEvidence(_ ids: Set<String>) { allowedEvidence = ids }
    public init(_ settings: AnalysisSettings, session: URLSession = .shared, authorization: ServerAuthorization? = nil) {
        self.httpSession = session; self.settings = settings; endpoint = settings.endpoint
        key = KeychainStore.get(KeychainStore.analysisAccount(endpoint: settings.endpoint))
        self.authorization = settings.engine == .builtin ? nil : authorization ?? ServerAuthorization(endpoint: settings.endpoint, configuration: settings.authentication, apiKey: key,
            clientSecret: KeychainStore.get((settings.authentication ?? .init()).secretAccount(purpose: "analysis", endpoint: settings.endpoint)))
    }
    deinit { cancel() }
    public func prepare() async throws {
        guard settings.engine != .unconfigured else { throw MeetingError.message("Choose an analysis provider and model in Settings.") }
        if settings.engine == .builtin {
            try ModelManager.validateFile(URL(fileURLWithPath: settings.modelPath), kind: .gguf)
            let port = try Self.availablePort()
            endpoint = "http://127.0.0.1:\(port)/v1"; key = UUID().uuidString + UUID().uuidString
            let process = NativeProcess(); self.process = process
            let executable = try NativeProcess.helper("llama-server")
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("mnt-llama-\(UUID()).log")
            let args = ["-m", settings.modelPath, "--host", "127.0.0.1", "--port", String(port), "--api-key", key, "-c", String(settings.contextTokens), "-np", "1", "-ngl", "99", "--no-webui", "--no-context-shift"]
            serverTask = Task { try await process.run(executable, arguments: args, log: log) }
            for _ in 0..<180 {
                try Task.checkCancellation()
                if process.hasExited { throw MeetingError.message("Local LLM exited before becoming ready. Check model compatibility and available memory.") }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!); request.timeoutInterval = 1
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return }
                try await Task.sleep(for: .milliseconds(500))
            }
            cancel(); throw MeetingError.message("Local LLM did not become ready. Check model compatibility and available memory.")
        }
        try await authorization?.validate()
        guard !settings.model.isEmpty else { throw MeetingError.message("Choose an analysis model.") }
        _ = try HTTPClient.endpoint(endpoint, path: settings.engine == .ollama ? "api/chat" : "chat/completions")
    }
    /// Both counting and generation use this exact request, including schema,
    /// inference options, chat-template options and evidence IDs.
    func requestBody(system: String, input: String) -> [String: Any] {
        let messages = [["role": "system", "content": system], ["role": "user", "content": input]]
        if settings.engine == .ollama {
            return ["model": settings.model, "messages": messages, "stream": false, "format": contract.schema(evidence: allowedEvidence), "options": ["num_ctx": settings.contextTokens, "num_predict": settings.outputTokens, "temperature": 0.1]]
        }
        var body: [String: Any] = ["model": settings.engine == .builtin ? "local-model" : settings.model, "messages": messages, "stream": false, "max_tokens": settings.outputTokens]
        if settings.engine == .builtin, let preset = settings.inferencePreset {
            body["temperature"] = preset.temperature; body["top_p"] = preset.topP; body["top_k"] = preset.topK
            if preset.disableThinking { body["chat_template_kwargs"] = ["enable_thinking": false] }
        }
        if settings.structuredOutput || settings.engine == .builtin {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "meeting_analysis", "strict": true, "schema": contract.schema(evidence: allowedEvidence)]]
        }
        return body
    }
    public func countTokens(system: String, input: String) async throws -> InputTokenCount {
        let body = requestBody(system: system, input: input)
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let cacheKey = fingerprint(String(decoding: encoded, as: UTF8.self))
        if let cached = countCache[cacheKey] { return cached }
        if supportsCounting == nil {
            if settings.engine == .builtin { supportsCounting = true }
            else if settings.engine == .ollama { supportsCounting = false }
            else {
                // Probe only synthetic text. No transcript goes to a second service.
                let probe: [String: Any] = ["model": settings.model, "messages": [["role": "user", "content": "Hello"]], "max_tokens": 1]
                do {
                    let data = try await HTTPClient.json(endpoint, path: "chat/completions/input_tokens", body: probe, key: key, session: httpSession, authorization: authorization)
                    supportsCounting = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["input_tokens"] as? Int != nil
                } catch let error as HTTPFailure where [404,405,501].contains(error.status) { supportsCounting = false }
            }
        }
        let result: InputTokenCount
        if supportsCounting == true {
            let data = try await HTTPClient.json(endpoint, path: "chat/completions/input_tokens", body: body, key: key, session: httpSession, authorization: authorization)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tokens = object["input_tokens"] as? Int, tokens >= 0 else { throw MeetingError.message("Invalid input-token count from the analysis provider.") }
            result = .init(tokens: tokens, accuracy: settings.engine == .builtin ? .exactLocal : .providerReported)
        } else {
            // Includes schema, metadata, prior findings and serialized framing.
            // A byte is the conservative unit when the provider has no tokenizer API.
            result = .init(tokens: encoded.count + 256, accuracy: .conservative)
        }
        if countCache.count >= 256 { countCache.removeAll(keepingCapacity: true) }
        countCache[cacheKey] = result
        return result
    }
    public func generate(system: String, input: String) async throws -> String {
        let body = requestBody(system: system, input: input)
        if settings.engine == .ollama {
            let data = try await HTTPClient.json(endpoint, path: "api/chat", body: body, session: httpSession, authorization: authorization)
            struct Result: Decodable { struct Message: Decodable { var content: String }; var message: Message; var done_reason: String? }
            let result = try JSONDecoder().decode(Result.self, from: data)
            guard result.done_reason != "length" else { throw MeetingError.message("Analysis reached its output limit. Increase the output budget and retry.") }
            return result.message.content
        }
        let data = try await HTTPClient.json(endpoint, path: "chat/completions", body: body, key: key, session: httpSession, authorization: authorization)
        struct Result: Decodable { struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message; var finish_reason: String? }; var choices: [Choice] }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard let first = result.choices.first else { throw MeetingError.message("The provider returned no analysis choice.") }
        guard first.finish_reason != "length" else { throw MeetingError.message("Analysis reached its output limit. Increase the output budget and retry.") }
        guard let text = first.message.content else { throw MeetingError.message("The provider returned no analysis message content.") }
        return text
    }
    public func cancel() { serverTask?.cancel(); process?.terminate() }
    public func shutdown() async {
        cancel(); await process?.shutdown(); _ = try? await serverTask?.value
        process = nil; serverTask = nil; countCache.removeAll()
    }
    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw MeetingError.message("Cannot allocate a local inference socket.") }; defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw MeetingError.message("Cannot bind local inference socket.") }
        var size = socklen_t(MemoryLayout.size(ofValue: addr))
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        return UInt16(bigEndian: addr.sin_port)
    }
    public static func models(settings: AnalysisSettings, key: String? = nil, clientSecret: String? = nil, session: URLSession = .shared) async throws -> [String] {
        let authorization = ServerAuthorization(endpoint: settings.endpoint, configuration: settings.authentication,
            apiKey: key ?? KeychainStore.get(KeychainStore.analysisAccount(endpoint: settings.endpoint)),
            clientSecret: clientSecret ?? KeychainStore.get((settings.authentication ?? .init()).secretAccount(purpose: "analysis", endpoint: settings.endpoint)))
        let data = try await HTTPClient.json(settings.endpoint, path: settings.engine == .ollama ? "api/tags" : "models", body: nil, session: session, authorization: authorization)
        if settings.engine == .ollama {
            struct List: Decodable { struct Item: Decodable { var name: String }; var models: [Item] }
            return try JSONDecoder().decode(List.self, from: data).models.map(\.name).sorted()
        }
        struct List: Decodable { struct Item: Decodable { var id: String }; var data: [Item] }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }
}

public enum AnalysisRunner {
    public static func validate(_ text: String, allowed: Set<String>) throws -> [AnalysisItem] {
        try AnalysisContract(kind: .actionItems).applying(text, to: FindingLedger(), current: allowed, allowed: allowed).items
    }
    public static func chunks(_ segments: [TranscriptSegment], byteBudget: Int) throws -> [String] {
        guard byteBudget >= 512 else { throw MeetingError.message("The system prompt leaves too little context. Increase the context budget or shorten the prompt.") }
        var chunks: [String] = []; var current = ""
        for segment in segments {
            let prefix = "[segment \(segment.id)] [\(MarkdownExporter.time(segment.start))–\(MarkdownExporter.time(segment.end))] \(segment.source.label): "
            // Split exceptionally long edited paragraphs without losing their original evidence ID.
            var part = ""
            for character in segment.text {
                if prefix.utf8.count + part.utf8.count + String(character).utf8.count > byteBudget/2 {
                    let line = prefix+part+"\n"
                    if current.utf8.count+line.utf8.count > byteBudget { chunks.append(current); current = "" }
                    current += line; part = ""
                }
                part.append(character)
            }
            let line = prefix+part+"\n"
            if current.utf8.count+line.utf8.count > byteBudget { chunks.append(current); current = "" }
            current += line
        }
        if !current.isEmpty { chunks.append(current) }; return chunks
    }
    /// Stable, Unicode-safe units make a validated checkpoint independent of
    /// adaptive request sizes. IDs always refer to original transcript segments.
    static func units(_ segments: [TranscriptSegment]) -> [AnalysisSnapshot.Unit] {
        AnalysisSnapshot(segments).units
    }

    static func checkpointIdentity(definition: AnalysisDefinition, settings: AnalysisSettings, transcript: String) throws -> String {
        fingerprint("analysis-v3|" + transcript + "|" + definition.kind.rawValue + "|" + definition.current.id.uuidString + "|" + definition.current.text + "|" + String(decoding: try meetingEncoder.encode(settings), as: UTF8.self))
    }
    public static func checkpointIdentity(definition: AnalysisDefinition, settings: AnalysisSettings, segments: [TranscriptSegment]) throws -> String {
        try checkpointIdentity(definition: definition, settings: settings, transcript: MarkdownExporter.transcriptFingerprint(segments))
    }
    public static func run(definition: AnalysisDefinition, settings: AnalysisSettings, session: MeetingSession, segments: [TranscriptSegment], provider: any AnalysisProvider,
        checkpoint: AnalysisCheckpoint? = nil, saveCheckpoint: @escaping (AnalysisCheckpoint) async throws -> Void = { _ in },
        progress: @escaping (String) async -> Void = { _ in }) async throws -> AnalysisResult {
        try await run(definition: definition, settings: settings, session: session, snapshot: AnalysisSnapshot(segments),
                      provider: provider, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint, progress: progress)
    }

    static func run(definition: AnalysisDefinition, settings: AnalysisSettings, session: MeetingSession, snapshot: AnalysisSnapshot, provider: any AnalysisProvider,
        checkpoint: AnalysisCheckpoint?, saveCheckpoint: @escaping (AnalysisCheckpoint) async throws -> Void,
        progress: @escaping (String) async -> Void) async throws -> AnalysisResult {
        let budget = settings.contextTokens - settings.outputTokens - max(256, Int(ceil(Double(settings.contextTokens) * 0.02)))
        guard budget > 0 else { throw MeetingError.message("Increase the context budget or reduce the output budget.") }
        let identity = fingerprint(try checkpointIdentity(definition: definition, settings: settings, transcript: snapshot.fingerprint)
            + "|" + String(session.startedAt.timeIntervalSince1970) + "|" + session.timezone)
        var cursor = 0, requests = 0
        var ledger = FindingLedger()
        if let saved = checkpoint, saved.formatVersion == 3, saved.identity == identity {
            guard (0...snapshot.units.count).contains(saved.consumedUnits), saved.requests >= 0,
                  let ids = saved.findingIDs, let nextID = saved.nextFindingID, nextID > 0,
                  ids.count == saved.findings.count, Set(ids).count == ids.count,
                  ids.allSatisfy({ $0 > 0 && $0 < nextID }),
                  saved.findings.allSatisfy({ !$0.evidenceSegmentIDs.isEmpty && $0.evidenceSegmentIDs.allSatisfy { snapshot.lookup[$0] != nil } })
            else { throw MeetingError.message("Invalid analysis checkpoint. Regenerate this analysis.") }
            cursor = saved.consumedUnits; requests = saved.requests
            ledger = FindingLedger(ids: ids, items: saved.findings, nextID: nextID)
        }
        let startCursor = cursor
        let started = Date(), jobID = UUID()
        let meeting = "Meeting started: \(ISO8601DateFormatter().string(from: session.startedAt)); timezone: \(session.timezone).\n"
        let instructions = DefaultPrompts.shared(language: settings.language) + "\n\n" + definition.current.text
        var lastAccuracy: TokenCountAccuracy?
        while cursor < snapshot.units.count {
            try Task.checkCancellation()
            let contract = AnalysisContract(kind: definition.kind, changes: cursor > 0)
            provider.configureContract(contract)
            let system = instructions + "\n\n" + contract.instructions
            var framing = meeting
            if contract.changes { framing += "Active findings (source data):\n" + (try ledger.compactJSON()) + "\n" }
            framing += "TRANSCRIPT DATA:\n"
            let priorEvidence = Set(ledger.items.flatMap(\.evidenceSegmentIDs))
            func request(_ count: Int) -> (input: String, current: Set<String>, allowed: Set<String>) {
                let range = cursor..<cursor + count
                let current = Set(snapshot.units[range].map(\.id))
                let allowed = priorEvidence.union(current)
                provider.configureEvidence(allowed)
                return (framing + snapshot.text(range), current, allowed)
            }
            provider.configureEvidence(priorEvidence)
            let base = try await provider.countTokens(system: system, input: framing)
            let fitBudget = budget - min(160, max(0, budget - base.tokens) / 4)
            guard base.tokens < fitBudget else { throw MeetingError.message("The prompt and active findings fill the model context. Increase context size or shorten the prompt.") }
            let byteLimit = max(256, (fitBudget - base.tokens) * (base.accuracy == .conservative ? 1 : 4))
            let upper = snapshot.upperBound(from: cursor, bytes: byteLimit)
            func measure(_ count: Int) async throws -> InputTokenCount? {
                let input = request(count).input
                do {
                    let measured = try await provider.countTokens(system: system, input: input)
                    return measured.tokens <= fitBudget ? measured : nil
                } catch let error as HTTPFailure where error.contextOverflow { return nil }
            }

            var count = upper
            var measured = try await measure(upper)
            if measured == nil {
                var low = 1, high = upper - 1
                count = 0
                while low <= high {
                    try Task.checkCancellation()
                    let mid = (low + high) / 2
                    if let fit = try await measure(mid) { measured = fit; count = mid; low = mid + 1 }
                    else { high = mid - 1 }
                }
            }
            guard count > 0 else { throw MeetingError.message("The next transcript fragment exceeds the available context. Increase the context size.") }
            let preferred = snapshot.boundary(from: cursor, fitting: count)
            if preferred != count, let fit = try await measure(preferred) { count = preferred; measured = fit }
            var overflows = 0
            while let fit = measured {
                try Task.checkCancellation()
                let part = request(count)
                lastAccuracy = fit.accuracy
                let metric = ProcessingProgress(jobID: jobID, stage: definition.kind.rawValue, completed: cursor-startCursor,
                    total: snapshot.units.count-startCursor, elapsed: Date().timeIntervalSince(started))
                let eta = metric.estimatedRemaining.map { " · about \(Int($0))s left" } ?? ""
                await progress("\(definition.kind.title): \(cursor)/\(snapshot.units.count) · \(fit.accuracy.rawValue) \(fit.tokens) tokens\(eta)")
                do {
                    requests += 1
                    let output = try await provider.generate(system: system, input: part.input)
                    let updated: FindingLedger
                    do { updated = try contract.applying(output, to: ledger, current: part.current, allowed: part.allowed) }
                    catch {
                        try Task.checkCancellation()
                        let repair = system + "\nCorrect the response format: " + error.localizedDescription
                        let cost = try await provider.countTokens(system: repair, input: part.input)
                        guard cost.tokens <= budget else { throw MeetingError.message("The correction request exceeds the context budget. Increase context size and retry.") }
                        requests += 1
                        let replacement = try await provider.generate(system: repair, input: part.input)
                        updated = try contract.applying(replacement, to: ledger, current: part.current, allowed: part.allowed)
                    }
                    try Task.checkCancellation()
                    let end = cursor + count
                    try await saveCheckpoint(.init(identity: identity, consumedUnits: end, formatVersion: 3, findingIDs: updated.ids,
                                                   nextFindingID: updated.nextID, findings: updated.items, requests: requests))
                    ledger = updated; cursor = end
                    break
                } catch let error as HTTPFailure where error.contextOverflow && overflows < 3 && count > 1 {
                    overflows += 1
                    count = snapshot.boundary(from: cursor, fitting: max(1, count/2))
                    measured = try await measure(count)
                    if measured == nil { throw error }
                }
            }
        }
        return AnalysisResult(kind: definition.kind, items: ledger.items, promptRevision: definition.current, provider: settings.engine.rawValue,
            model: settings.engine == .builtin ? URL(fileURLWithPath: settings.modelPath).lastPathComponent : settings.model, language: settings.language,
            generatedAt: Date(), transcriptFingerprint: snapshot.fingerprint, processing: .init(jobID: jobID, stage: definition.kind.rawValue,
                completed: cursor, total: snapshot.units.count, elapsed: Date().timeIntervalSince(started), tokenAccuracy: lastAccuracy, requests: requests))
    }
}
