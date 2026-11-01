import XCTest
@testable import MeetingCore

final class OAuthTests: XCTestCase {
    private func server(_ handler: @escaping (URLRequest, Int) -> (Int, String)) -> OAuthStub {
        let stub = OAuthStub(handler: handler)
        addTeardownBlock { stub.close() }
        return stub
    }
    private func configuration(_ stub: OAuthStub, method: OAuthClientAuthentication = .basic) -> ServerAuthentication {
        var auth = ServerAuthentication(); auth.method = .oauthClientCredentials
        auth.clientID = "client: é+"; auth.tokenURL = stub.base + "/token"; auth.scope = "meeting.read meeting.write"; auth.clientAuthentication = method
        return auth
    }
    private func authorize(_ stub: OAuthStub, config: ServerAuthentication? = nil, clock: @escaping @Sendable () -> Date = { Date() }) -> ServerAuthorization {
        ServerAuthorization(endpoint: stub.base + "/v1", configuration: config ?? configuration(stub), apiKey: "must-not-fallback", clientSecret: "secret&+= é", now: clock)
    }
    private func request(_ stub: OAuthStub) -> URLRequest { URLRequest(url: URL(string: stub.base + "/v1/models")!) }
    private let token = #"{"access_token":"token-1","token_type":"Bearer","expires_in":3600}"#

    func testClientCredentialsEncodingBothMethodsAndCaching() async throws {
        for method in OAuthClientAuthentication.allCases {
            let stub = server { req, _ in req.url!.path == "/token" ? (200, self.token) : (200, #"{"data":[]}"#) }
            let auth = authorize(stub, config: configuration(stub, method: method))
            async let first = auth.send(request(stub), session: stub.session)
            async let second = auth.send(request(stub), session: stub.session)
            _ = try await (first, second)
            let requests = stub.requests
            let exchange = try XCTUnwrap(requests.first { $0.url!.path == "/token" })
            XCTAssertEqual(requests.filter { $0.url!.path == "/token" }.count, 1)
            XCTAssertEqual(exchange.httpMethod, "POST")
            XCTAssertEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            let body = OAuthStub.body(exchange)
            XCTAssertTrue(body.contains("grant_type=client_credentials"))
            XCTAssertTrue(body.contains("scope=meeting.read+meeting.write"))
            if method == .basic {
                XCTAssertEqual(exchange.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("client%3A+%C3%A9%2B:secret%26%2B%3D+%C3%A9".utf8).base64EncodedString())
                XCTAssertFalse(body.contains("client_secret")); XCTAssertFalse(body.contains("client_id"))
            } else {
                XCTAssertNil(exchange.value(forHTTPHeaderField: "Authorization"))
                XCTAssertTrue(body.contains("client_id=client%3A+%C3%A9%2B"))
                XCTAssertTrue(body.contains("client_secret=secret%26%2B%3D+%C3%A9"))
            }
            for api in requests.filter({ $0.url!.path != "/token" }) {
                XCTAssertEqual(api.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
                XCTAssertFalse(OAuthStub.body(api).contains("secret"))
            }
        }
    }
    func testTokenExpiryAndMissingExpiryRenewWithoutGuessingLifetime() async throws {
        let clock = OAuthClock()
        let stub = server { req, _ in req.url!.path == "/token" ? (200, #"{"access_token":"token-1","token_type":"bearer","expires_in":100}"#) : (200, "{}") }
        let auth = authorize(stub, clock: { clock.date })
        _ = try await auth.send(request(stub), session: stub.session)
        clock.advance(50)
        _ = try await auth.send(request(stub), session: stub.session)
        XCTAssertEqual(stub.tokenRequests, 1)
        clock.advance(41)
        _ = try await auth.send(request(stub), session: stub.session)
        XCTAssertEqual(stub.tokenRequests, 2)
        let noExpiry = server { req, _ in req.url!.path == "/token" ? (200, #"{"access_token":"token-1","token_type":"Bearer"}"#) : (200, "{}") }
        let uncached = authorize(noExpiry)
        for _ in 0..<2 { _ = try await uncached.send(request(noExpiry), session: noExpiry.session) }
        XCTAssertEqual(noExpiry.tokenRequests, 2)
    }
    func testRejectedTokenRenewsOnceWithoutAPIKeyFallback() async throws {
        for alwaysReject in [false, true] {
            let stub = server { req, count in
                if req.url!.path == "/token" { return (200, "{\"access_token\":\"token-\(count)\",\"token_type\":\"Bearer\",\"expires_in\":3600}") }
                return (alwaysReject || req.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" ? 401 : 200, "{}")
            }
            do {
                _ = try await authorize(stub).send(request(stub), session: stub.session)
                XCTAssertFalse(alwaysReject)
            } catch let error as HTTPFailure { XCTAssertTrue(alwaysReject); XCTAssertEqual(error.status, 401) }
            XCTAssertEqual(stub.tokenRequests, 2)
            XCTAssertEqual(stub.requests.filter { $0.url!.path != "/token" }.count, 2)
            XCTAssertFalse(stub.requests.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer must-not-fallback" })
        }
    }
    func testTokenFailuresAreRedactedAndNeverUploadToAPI() async throws {
        let invalid = [
            (400, #"{"error":"invalid_client","error_description":"secret&+= é"}"#),
            (307, "redirect with secret&+= é"),
            (200, #"{"access_token":"secret&+= é","token_type":"MAC"}"#),
            (200, #"{"access_token":"token\r\nInjected: bad","token_type":"Bearer"}"#),
            (200, #"{"access_token":"token\n","token_type":"Bearer"}"#),
            (200, #"{"token_type":"Bearer"}"#),
            (200, #"{"access_token":"token","token_type":"Bearer","expires_in":-1}"#),
            (200, "not JSON secret&+= é")
        ]
        for response in invalid {
            let stub = server { _, _ in response }
            do { _ = try await authorize(stub).send(request(stub), session: stub.session); XCTFail("Expected token rejection") }
            catch { XCTAssertFalse(error.localizedDescription.contains("secret&+= é")) }
            XCTAssertEqual(stub.requests.count, 1)
        }
    }
    func testConfigurationValidationAndSecretIsolation() throws {
        var config = ServerAuthentication(); config.method = .oauthClientCredentials; config.clientID = "client"
        for invalid in ["http://example.com/token", "https://u:p@example.com/token", "file:///token", "https://example.com/token#fragment", "https:///token"] {
            config.tokenURL = invalid
            XCTAssertThrowsError(try config.validated(endpoint: "https://api.example.com/v1"))
        }
        config.tokenURL = "https://identity.example.com/token"
        XCTAssertThrowsError(try config.validated(endpoint: "http://api.example.com/v1"))
        config.tokenURL = "http://localhost:8080/token"
        XCTAssertNoThrow(try config.validated(endpoint: "http://127.0.0.1:8081/v1"))
        let account = config.secretAccount(purpose: "speech", endpoint: "https://API.example.com/v1/")
        XCTAssertEqual(account, config.secretAccount(purpose: "speech", endpoint: "https://api.example.com/v1"))
        XCTAssertNotEqual(account, config.secretAccount(purpose: "analysis", endpoint: "https://api.example.com/v1"))
        XCTAssertNotEqual(account, config.secretAccount(purpose: "speech", endpoint: "https://other.example.com/v1"))
        var changed = config; changed.clientID = "other"
        XCTAssertNotEqual(account, changed.secretAccount(purpose: "speech", endpoint: "https://api.example.com/v1"))
        changed = config; changed.tokenURL = "https://other.example.com/token"
        XCTAssertNotEqual(account, changed.secretAccount(purpose: "speech", endpoint: "https://api.example.com/v1"))
        changed = config; changed.scope = "new.scope"
        XCTAssertEqual(account, changed.secretAccount(purpose: "speech", endpoint: "https://api.example.com/v1"))
    }
    func testOldSettingsAndOAuthJobSnapshotsRemainCompatible() throws {
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        for key in ["speech", "analysis"] {
            var part = old[key] as! [String: Any]; part.removeValue(forKey: "authentication"); old[key] = part
        }
        var settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(settings.speech.authentication); XCTAssertNil(settings.analysis.authentication)
        let stub = server { _, _ in (200, "{}") }
        let auth = configuration(stub)
        var draft = RemoteSpeechConfiguration(speech: settings.speech)
        draft.endpoint = stub.base + "/v1"; draft.model = "speech"; draft.authentication = auth
        settings = try draft.applying(to: settings, activate: true)
        var analysis = AnalysisSettings(); analysis.engine = .compatible; analysis.model = "chat"; analysis.authentication = auth
        settings = analysis.applyingModelConfiguration(to: settings, activate: true)
        var job = MeetingSession(folder: "/tmp", stem: "fixture", speech: settings.speech, echoReduction: false)
        job.analysisSnapshot = settings.analysis
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: data)
        XCTAssertEqual(decoded.speech.authentication, auth); XCTAssertEqual(decoded.analysisSnapshot?.authentication, auth)
        let json = String(decoding: data, as: UTF8.self)
        for secretField in ["client_secret", "access_token", "clientSecret", "must-not-fallback"] { XCTAssertFalse(json.contains(secretField)) }
    }
    func testOAuthProtectsSpeechUploadAndDiscovery() async throws {
        let stub = server { req, _ in
            switch req.url!.path {
            case "/token": return (200, self.token)
            case "/v1/models": return (200, #"{"data":[{"id":"speech"}]}"#)
            default: return (200, #"{"text":"Bonjour, hola."}"#)
            }
        }
        let auth = configuration(stub)
        let discovery = try await RemoteSpeechServer.test(endpoint: stub.base + "/v1", key: "ignored", authentication: auth, clientSecret: "secret&+= é", session: stub.session)
        XCTAssertEqual(discovery.models, ["speech"])
        var settings = SpeechSettings(); settings.endpoint = stub.base + "/v1"; settings.remoteModel = "speech"; settings.authentication = auth
        let provider = RemoteSpeechProvider(settings, session: stub.session, authorization: authorize(stub))
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        try Data("test-only-audio".utf8).write(to: audio)
        try await provider.prepare()
        let result = try await provider.transcribe(audio, source: .computer, offset: 3, duration: 2)
        XCTAssertEqual(result.first?.text, "Bonjour, hola."); XCTAssertEqual(result.first?.start, 3)
        let upload = try XCTUnwrap(stub.requests.first { $0.url!.path == "/v1/audio/transcriptions" })
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertTrue(OAuthStub.body(upload).contains("test-only-audio"))
        XCTAssertFalse(OAuthStub.body(upload).contains("client_secret"))
    }
    func testOAuthProtectsAnalysisDiscoveryCountingAndGenerationIncludingOllama() async throws {
        for engine in [LLMEngine.compatible, .ollama] {
            let stub = server { req, _ in
                switch req.url!.path {
                case "/token": return (200, self.token)
                case "/v1/models": return (200, #"{"data":[{"id":"chat"}]}"#)
                case "/v1/api/tags": return (200, #"{"models":[{"name":"chat"}]}"#)
                case "/v1/chat/completions/input_tokens": return (200, #"{"input_tokens":32}"#)
                case "/v1/api/chat": return (200, #"{"message":{"content":"{\"items\":[]}"},"done_reason":"stop"}"#)
                default: return (200, #"{"choices":[{"message":{"content":"{\"items\":[]}"},"finish_reason":"stop"}]}"#)
                }
            }
            var settings = AnalysisSettings(); settings.engine = engine; settings.endpoint = stub.base + "/v1"; settings.model = "chat"; settings.authentication = configuration(stub)
            let models = try await ChatAnalysisProvider.models(settings: settings, key: "ignored", clientSecret: "secret&+= é", session: stub.session)
            XCTAssertEqual(models, ["chat"])
            let provider = ChatAnalysisProvider(settings, session: stub.session, authorization: authorize(stub))
            try await provider.prepare()
            _ = try await provider.countTokens(system: "test", input: "test")
            let output = try await provider.generate(system: "test", input: "test")
            XCTAssertEqual(output, #"{"items":[]}"#)
            for api in stub.requests.filter({ $0.url!.path != "/token" }) { XCTAssertEqual(api.value(forHTTPHeaderField: "Authorization"), "Bearer token-1") }
            await provider.shutdown()
        }
    }
    func testCredentialsCannotFollowRedirectsCacheResponsesOrCrossServerBoundaries() async throws {
        let stub = server { _, _ in (200, self.token) }
        let auth = authorize(stub)
        for url in ["https://other.test/v1/models", stub.base + "/v10/models", stub.base + "/token", "http://" + stub.host + "/v1/models"] {
            do { _ = try await auth.send(URLRequest(url: URL(string: url)!), session: stub.session); XCTFail("Unexpected credential destination") } catch {}
        }
        XCTAssertTrue(stub.requests.isEmpty)
        let request = request(stub), task = stub.session.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": "https://other.test/"])!
        CredentialRedirectBlocker.shared.urlSession(stub.session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://other.test/")!)) { XCTAssertNil($0) }
        CredentialRedirectBlocker.shared.urlSession(stub.session, dataTask: task, willCacheResponse: CachedURLResponse(response: response, data: Data(token.utf8))) { XCTAssertNil($0) }
    }
    func testCancellationStopsTokenExchangeAndAllowsRetry() async throws {
        let started = expectation(description: "Token requested")
        let stub = server { _, count in if count == 1 { started.fulfill() }; return (200, self.token) }
        stub.delay = 0.2
        let auth = authorize(stub)
        let task = Task { try await auth.send(request(stub), session: stub.session) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        _ = try await auth.send(request(stub), session: stub.session)
        XCTAssertEqual(stub.tokenRequests, 2)
    }
}

private final class OAuthClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}
private final class OAuthStub: @unchecked Sendable {
    let host = UUID().uuidString.lowercased() + ".test"
    var base: String { "https://" + host }
    let session: URLSession
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private var tokens = 0
    var delay: TimeInterval = 0
    private let handler: (URLRequest, Int) -> (Int, String)
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    var tokenRequests: Int { lock.lock(); defer { lock.unlock() }; return tokens }
    init(handler: @escaping (URLRequest, Int) -> (Int, String)) {
        self.handler = handler
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthProtocol.self]
        session = URLSession(configuration: config)
        OAuthProtocol.register(self)
    }
    func respond(_ request: URLRequest) -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        // Snapshot streamed request bodies so assertions don't consume them twice.
        var snapshot = request; snapshot.httpBody = Data(Self.body(request).utf8)
        captured.append(snapshot)
        if request.url!.path == "/token" { tokens += 1 }
        return handler(snapshot, tokens)
    }
    func close() { session.invalidateAndCancel(); OAuthProtocol.remove(host) }
    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return String(decoding: data, as: UTF8.self)
    }
}
private final class OAuthProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var servers: [String: OAuthStub] = [:]
    private var work: DispatchWorkItem?
    static func register(_ server: OAuthStub) { lock.lock(); defer { lock.unlock() }; servers[server.host] = server }
    static func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; servers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = Self.servers[request.url!.host!]; Self.lock.unlock()
        guard let server else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let (status, body) = server.respond(request)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8)); self.client?.urlProtocolDidFinishLoading(self)
        }
        work = item; DispatchQueue.global().asyncAfter(deadline: .now() + server.delay, execute: item)
    }
    override func stopLoading() { work?.cancel() }
}
