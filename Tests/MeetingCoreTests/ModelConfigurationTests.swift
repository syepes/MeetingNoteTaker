import XCTest
@testable import MeetingCore

final class ModelConfigurationTests: XCTestCase {
    func testAppleSpeechRejectsUnsupportedLocaleWithoutDownloading() async throws {
        var settings = SpeechSettings()
        settings.engine = .apple
        settings.appleLocale = "zz-ZZ"
        let provider = try SpeechProviders.make(settings)
        do {
            try await provider.prepare()
            XCTFail("An unsupported locale must not prepare successfully")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not support") || error.localizedDescription.contains("unavailable"))
        }
        await provider.shutdown()
    }

    func testAppleSpeechRequiresInstalledAssets() async throws {
        let supported = await ModelManager.appleLocales()
        let installed = await ModelManager.installedAppleLocales()
        guard let missing = supported.first(where: { !installed.contains($0) }) else {
            throw XCTSkip("Apple Speech unavailable or all supported locales already installed")
        }
        var settings = SpeechSettings()
        settings.engine = .apple
        settings.appleLocale = missing
        let provider = try SpeechProviders.make(settings)
        do {
            try await provider.prepare()
            XCTFail("Missing assets must require explicit installation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Install the Apple Speech language assets"))
        }
        await provider.shutdown()
        let after = await ModelManager.installedAppleLocales()
        XCTAssertEqual(after, installed, "Preparation must not download language assets")
    }

    func testSaveSelectedTranscriptionServerActivatesWithoutSeparateButton() throws {
        var current = AppSettings()
        current.speech.engine = .parakeet; current.speech.modelPath = "/models/parakeet"
        current.speech.language = "auto"
        let snapshot = current.speech
        var draft = RemoteSpeechConfiguration(speech: current.speech)
        draft.endpoint = " https://example.com/v1/ "; draft.model = " chosen-model "
        draft.language = "fr"; draft.detailedTimestamps = true
        let saved = try draft.applying(to: current, activate: draft.hasModelSelection)
        XCTAssertEqual(saved.speech.engine, .remote)
        XCTAssertEqual(saved.speech.remoteModel, "chosen-model")
        XCTAssertEqual(saved.speech.endpoint, "https://example.com/v1")
        XCTAssertEqual(saved.speech.remoteLanguage, "fr")
        XCTAssertTrue(saved.speech.detailedTimestamps)
        XCTAssertEqual(saved.speech.modelPaths[SpeechEngine.parakeet.rawValue], "/models/parakeet")
        XCTAssertEqual(saved.speech.language, "auto")
        XCTAssertEqual(current.speech, snapshot, "Existing settings and job snapshots remain unchanged")
    }

    func testSaveIncompleteTranscriptionServerKeepsLocalEngine() throws {
        var current = AppSettings(); current.speech.engine = .whisper
        var draft = RemoteSpeechConfiguration(speech: current.speech)
        draft.endpoint = "http://localhost:8000/v1"; draft.model = " \n "
        let saved = try draft.applying(to: current, activate: draft.hasModelSelection)
        XCTAssertEqual(saved.speech.engine, .whisper)
        XCTAssertEqual(saved.speech.endpoint, draft.endpoint)
        XCTAssertEqual(saved.speech.remoteModel, "")
    }

    func testSaveIncompleteTranscriptionServerDoesNotInvalidateActiveServer() throws {
        var current = AppSettings()
        current.speech.engine = .remote; current.speech.remoteModel = "working-model"
        var draft = RemoteSpeechConfiguration(speech: current.speech)
        draft.model = " "
        XCTAssertThrowsError(try draft.applying(to: current, activate: draft.hasModelSelection))
        XCTAssertEqual(current.speech.remoteModel, "working-model")
    }

    func testSavingServerDoesNotActivateItOrChangeLocalModel() throws {
        var settings = AppSettings()
        settings.speech.engine = .parakeet; settings.speech.modelPath = "/models/parakeet"
        settings.speech.language = "auto"
        var draft = RemoteSpeechConfiguration(speech: settings.speech)
        draft.endpoint = " HTTPS://Example.COM/v1/ "; draft.model = " whisper-1 "; draft.language = "fr"
        let saved = try draft.applying(to: settings, activate: false)
        XCTAssertEqual(saved.speech.engine, .parakeet)
        XCTAssertEqual(saved.speech.modelPath, "/models/parakeet")
        XCTAssertEqual(saved.speech.remoteLanguage, "fr")
        XCTAssertEqual(saved.speech.language, "auto")
        XCTAssertEqual(saved.speech.endpoint, "https://example.com/v1")
        XCTAssertEqual(saved.speech.remoteModel, "whisper-1")
        XCTAssertEqual(try draft.applying(to: settings, activate: true).speech.engine, .remote)
        draft.model = " "
        XCTAssertNoThrow(try draft.applying(to: settings, activate: false))
        XCTAssertThrowsError(try draft.applying(to: settings, activate: true))
    }
    func testEndpointValidationAndCredentialIsolation() throws {
        for invalid in ["localhost:8000", "ftp://example.com", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment", "https://example.com/v1/models", "https://example.com/v1/audio/transcriptions"] {
            XCTAssertThrowsError(try RemoteSpeechConfiguration.normalizedEndpoint(invalid), invalid)
        }
        XCTAssertEqual(RemoteSpeechConfiguration.credentialAccount(endpoint: "https://EXAMPLE.com/v1/"), RemoteSpeechConfiguration.credentialAccount(endpoint: "https://example.com/v1"))
        XCTAssertNotEqual(RemoteSpeechConfiguration.credentialAccount(endpoint: "https://a.example/v1"), RemoteSpeechConfiguration.credentialAccount(endpoint: "https://b.example/v1"))
        XCTAssertNotEqual(KeychainStore.analysisAccount(endpoint: "https://example.com/v1"), RemoteSpeechConfiguration.credentialAccount(endpoint: "https://example.com/v1"))
    }
    func testOlderSettingsLoadWithoutNewProfileFields() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        json.removeValue(forKey: "analysisProfiles")
        var speech = try XCTUnwrap(json["speech"] as? [String: Any])
        speech.removeValue(forKey: "appleLocale"); speech.removeValue(forKey: "remoteLanguage"); json["speech"] = speech
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.analysisProfiles); XCTAssertNil(decoded.speech.appleLocale); XCTAssertNil(decoded.speech.remoteLanguage)
        XCTAssertEqual(decoded.analysis.language, "English")
    }
    func testConnectionRequestsOnlyModelMetadataAndHandlesUnsupportedDiscovery() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ModelMetadataProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let result = try await RemoteSpeechServer.test(endpoint: "https://models.test/v1", key: "test-only", session: session)
        XCTAssertTrue(result.supportsDiscovery); XCTAssertEqual(result.models, ["a-model", "z-model"])
        let unsupported = try await RemoteSpeechServer.test(endpoint: "https://unsupported.test/v1", key: "", session: session)
        XCTAssertFalse(unsupported.supportsDiscovery); XCTAssertTrue(unsupported.models.isEmpty)
        for host in ["unauthorized.test", "malformed.test", "failure.test"] {
            do {
                _ = try await RemoteSpeechServer.test(endpoint: "https://\(host)/v1", key: "", session: session)
                XCTFail("Expected connection failure for \(host)")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }
}

private final class ModelMetadataProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertNil(request.httpBody); XCTAssertNil(request.httpBodyStream)
        let host = request.url!.host!
        if host == "models.test" { XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only") }
        else { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
        let status = host == "unsupported.test" ? 404 : host == "unauthorized.test" ? 401 : host == "failure.test" ? 503 : 200
        let body = host == "malformed.test" ? "<html>not a model list</html>" : #"{"data":[{"id":"z-model"},{"id":"a-model"},{"id":"z-model"},{"id":" "}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ModelConfigurationTests {
    func testSaveSelectedAnalysisModelAppliesTuningAndPreservesBehavior() {
        var current = AppSettings()
        current.analysis.engine = .builtin; current.analysis.modelPath = "/models/local.gguf"
        current.analysis.language = "French"; current.analysis.automatic = true
        let snapshot = current.analysis
        var draft = current.analysis
        draft.contextTokens = 16384; draft.outputTokens = 2048
        draft.language = "English"; draft.automatic = false
        let saved = draft.applyingModelConfiguration(to: current, activate: draft.hasModelSelection)
        XCTAssertEqual(saved.analysis.contextTokens, 16384); XCTAssertEqual(saved.analysis.outputTokens, 2048)
        XCTAssertEqual(saved.analysis.language, "French"); XCTAssertTrue(saved.analysis.automatic)
        XCTAssertEqual(saved.analysisProfiles?[LLMEngine.builtin.rawValue]?.contextTokens, 16384)
        XCTAssertEqual(current.analysis, snapshot, "Existing job snapshots and the original settings remain unchanged")
    }
    func testSaveServerModelSelectionActivatesWithoutSeparateButton() {
        var current = AppSettings(); current.analysis.engine = .builtin; current.analysis.modelPath = "/models/local.gguf"
        for engine in [LLMEngine.ollama, .compatible] {
            var draft = AnalysisSettings(); draft.engine = engine; draft.model = "chosen-model"
            draft.endpoint = "http://localhost:1234/v1"
            let saved = draft.applyingModelConfiguration(to: current, activate: draft.hasModelSelection)
            XCTAssertEqual(saved.analysis.engine, engine); XCTAssertEqual(saved.analysis.model, "chosen-model")
            XCTAssertEqual(saved.analysis.endpoint, draft.endpoint)
        }
    }
    func testSaveIncompleteProviderKeepsActiveModel() {
        var current = AppSettings(); current.analysis.engine = .builtin; current.analysis.modelPath = "/models/local.gguf"
        for engine in [LLMEngine.builtin, .ollama, .compatible] {
            var draft = AnalysisSettings(); draft.engine = engine; draft.model = "  "; draft.modelPath = "  "
            let saved = draft.applyingModelConfiguration(to: current, activate: draft.hasModelSelection)
            XCTAssertFalse(draft.hasModelSelection)
            XCTAssertEqual(saved.analysis, current.analysis)
            XCTAssertEqual(saved.analysisProfiles?[engine.rawValue], draft)
        }
    }
}
