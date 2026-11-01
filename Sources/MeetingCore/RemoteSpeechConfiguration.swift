import Foundation

public struct RemoteSpeechConfiguration: Equatable, Sendable {
    public var endpoint: String
    public var model: String
    public var language: String
    public var detailedTimestamps: Bool
    public var authentication: ServerAuthentication?

    public var hasModelSelection: Bool { !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init(speech: SpeechSettings) {
        endpoint = speech.endpoint; model = speech.remoteModel
        let previous = speech.remoteLanguage ?? speech.language
        language = ["auto", "en", "fr"].contains(previous) ? previous : "auto"
        detailedTimestamps = speech.detailedTimestamps; authentication = speech.authentication
    }
    public func validated(requireModel: Bool) throws -> Self {
        var result = self
        result.endpoint = try Self.normalizedEndpoint(endpoint)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requireModel || !result.model.isEmpty else { throw MeetingError.message("Enter or choose a transcription model before activating Server.") }
        guard ["auto", "en", "fr"].contains(language) else { throw MeetingError.message("Choose Automatic, English, or French.") }
        result.authentication = try authentication?.validated(endpoint: result.endpoint)
        return result
    }
    public static func normalizedEndpoint(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw MeetingError.message("Enter a full http:// or https:// API base URL, without credentials, a query, or a fragment. Include the server’s API prefix, such as /v1.")
        }
        parts.scheme = parts.scheme?.lowercased(); parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard !parts.path.hasSuffix("/audio/transcriptions"), !parts.path.hasSuffix("/models"), let url = parts.url else {
            throw MeetingError.message("Enter the API base URL, such as https://example.com/v1, without /models or /audio/transcriptions.")
        }
        return url.absoluteString
    }
    public static func credentialAccount(endpoint: String) -> String {
        let normalized = (try? normalizedEndpoint(endpoint)) ?? endpoint
        return "speech-server-" + fingerprint(normalized)
    }
    public func applying(to settings: AppSettings, activate: Bool) throws -> AppSettings {
        // Saving an incomplete draft must not erase a currently active server model.
        let config = try validated(requireModel: activate || settings.speech.engine == .remote)
        var result = settings
        result.speech.authentication = config.authentication
        result.speech.endpoint = config.endpoint; result.speech.remoteModel = config.model
        result.speech.remoteLanguage = config.language; result.speech.detailedTimestamps = config.detailedTimestamps
        if activate { result.speech.engine = .remote }
        return result
    }
}

public struct RemoteSpeechConnection: Sendable {
    public let models: [String]
    public let supportsDiscovery: Bool
}

public enum RemoteSpeechServer {
    /// Metadata-only probe: never uploads audio or selects a model automatically.
    public static func test(endpoint: String, key: String, authentication: ServerAuthentication? = nil, clientSecret: String = "", session: URLSession = .shared) async throws -> RemoteSpeechConnection {
        let base = try RemoteSpeechConfiguration.normalizedEndpoint(endpoint)
        var request = URLRequest(url: try HTTPClient.endpoint(base, path: "models"))
        request.httpMethod = "GET"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let authorization = ServerAuthorization(endpoint: base, configuration: authentication, apiKey: key, clientSecret: clientSecret)
        let data: Data
        do { data = try await authorization.send(request, session: session) }
        catch let error as HTTPFailure where [404, 405, 501].contains(error.status) { return .init(models: [], supportsDiscovery: false) }
        try Task.checkCancellation()
        struct ModelList: Decodable { struct Model: Decodable { var id: String }; var data: [Model] }
        guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw MeetingError.message("The server responded, but /models did not return an OpenAI-compatible model list. Check the API prefix or enter a model ID manually.")
        }
        let models = Set(list.data.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).sorted()
        return .init(models: models, supportsDiscovery: true)
    }
}
