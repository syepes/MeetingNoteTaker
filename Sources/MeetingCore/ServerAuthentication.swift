import Foundation

public enum ServerAuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case apiKey, oauthClientCredentials
}
public enum OAuthClientAuthentication: String, Codable, CaseIterable, Sendable {
    case basic, formBody
}
/// Only non-secret configuration is encoded in settings and job snapshots.
public struct ServerAuthentication: Codable, Equatable, Sendable {
    public var method: ServerAuthenticationMethod = .apiKey
    public var clientID = ""
    public var tokenURL = ""
    public var scope = ""
    public var clientAuthentication: OAuthClientAuthentication = .basic
    public init() {}

    public func validated(endpoint: String) throws -> Self {
        guard method == .oauthClientCredentials else { return self }
        var result = self
        result.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.clientID.isEmpty else { throw MeetingError.message("Enter an OAuth client ID.") }
        result.tokenURL = try Self.secureURL(tokenURL, label: "OAuth token URL").absoluteString
        _ = try Self.secureURL(endpoint, label: "OAuth server URL")
        return result
    }
    /// Distinct secrets for each server, purpose, token endpoint and client.
    public func secretAccount(purpose: String, endpoint: String) -> String {
        let base = (try? RemoteSpeechConfiguration.normalizedEndpoint(endpoint)) ?? endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (try? Self.secureURL(tokenURL, label: "OAuth token URL").absoluteString) ?? tokenURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return "oauth-\(purpose)-" + fingerprint([base, token, clientID.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "\n"))
    }
    static func secureURL(_ value: String, label: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw MeetingError.message("Enter a full \(label) without embedded credentials or a fragment.")
        }
        parts.scheme = parts.scheme?.lowercased(); parts.host = host
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard parts.scheme == "https" || (parts.scheme == "http" && loopback), let url = parts.url else {
            throw MeetingError.message("\(label) must use HTTPS. HTTP is supported only for localhost development servers.")
        }
        return url
    }
}

/// Per-job credential snapshot and in-memory token cache. Nothing here is Codable
/// or logged. A new job uses current Keychain credentials; running jobs stay stable.
public actor ServerAuthorization {
    private let configuration: ServerAuthentication
    private let endpoint: String
    private let apiKey: String
    private let clientSecret: String
    private let now: @Sendable () -> Date
    private struct Token: Sendable { let value: String; let expiresAt: Date }
    private var cached: Token?
    private var pending: (id: UUID, task: Task<Token, Error>)?

    public init(endpoint: String, configuration: ServerAuthentication? = nil, apiKey: String = "", clientSecret: String = "", now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint; self.configuration = configuration ?? .init()
        self.apiKey = apiKey; self.clientSecret = clientSecret; self.now = now
    }
    public func validate() throws {
        _ = try configuration.validated(endpoint: endpoint)
        if configuration.method == .oauthClientCredentials, clientSecret.isEmpty {
            throw MeetingError.message("Enter the OAuth client secret and save it in Settings → Models.")
        }
    }
    public func send(_ request: URLRequest, session: URLSession = .shared) async throws -> Data {
        try validate()
        // A credential must never be reused for another origin or API prefix.
        guard let url = request.url, let base = URL(string: endpoint),
              url.scheme?.lowercased() == base.scheme?.lowercased(), url.host?.lowercased() == base.host?.lowercased(), url.port == base.port,
              url.path == base.path || url.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") else {
            throw MeetingError.message("Authentication cannot be used outside its configured server URL.")
        }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let credential = configuration.method == .oauthClientCredentials ? try await accessToken(session: session) : apiKey
            var authorized = request
            authorized.cachePolicy = .reloadIgnoringLocalCacheData; authorized.httpShouldHandleCookies = false
            authorized.setValue(credential.isEmpty ? nil : "Bearer \(credential)", forHTTPHeaderField: "Authorization")
            do {
                let data = try await HTTPClient.send(authorized, session: session, rejectRedirects: true)
                try Task.checkCancellation()
                return data
            }
            catch let error as HTTPFailure where error.status == 401 && configuration.method == .oauthClientCredentials && attempt == 0 {
                if cached?.value == credential { cached = nil }
            }
        }
        throw MeetingError.message("The server rejected OAuth authentication after token renewal.")
    }
    private func accessToken(session: URLSession) async throws -> String {
        try Task.checkCancellation()
        if let cached, cached.expiresAt > now() { return cached.value }
        let work: (id: UUID, task: Task<Token, Error>)
        if let pending { work = pending }
        else {
            let config = try configuration.validated(endpoint: endpoint), secret = clientSecret, clock = now
            work = (UUID(), Task { try await Self.fetchToken(config, secret: secret, session: session, now: clock) })
            pending = work
        }
        do {
            let token = try await withTaskCancellationHandler { try await work.task.value } onCancel: { work.task.cancel() }
            try Task.checkCancellation()
            if pending?.id == work.id { cached = token; pending = nil }
            return token.value
        } catch {
            if pending?.id == work.id { pending = nil }
            throw error
        }
    }
    private static func fetchToken(_ config: ServerAuthentication, secret: String, session: URLSession, now: @Sendable () -> Date) async throws -> Token {
        var request = URLRequest(url: try ServerAuthentication.secureURL(config.tokenURL, label: "OAuth token URL"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var fields = [("grant_type", "client_credentials")]
        if !config.scope.isEmpty { fields.append(("scope", config.scope)) }
        switch config.clientAuthentication {
        case .basic:
            let credentials = formEncode(config.clientID) + ":" + formEncode(secret)
            request.setValue("Basic " + Data(credentials.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        case .formBody: fields += [("client_id", config.clientID), ("client_secret", secret)]
        }
        request.httpBody = Data(fields.map { formEncode($0.0) + "=" + formEncode($0.1) }.joined(separator: "&").utf8)
        let started = now()
        let data: Data
        do { data = try await HTTPClient.send(request, session: session, rejectRedirects: true) }
        catch let error as HTTPFailure {
            // Never expose error_description or response bodies; identity servers
            // sometimes echo submitted credentials in their errors.
            throw MeetingError.message("OAuth token request failed (HTTP \(error.status)). Check the token URL, client credentials, scope, and client authentication method.")
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MeetingError.message("Could not reach the OAuth token server (network error \(error.code.rawValue)).")
        }
        struct Response: Decodable { let access_token: String; let token_type: String; let expires_in: Double? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.token_type.lowercased() == "bearer",
              response.access_token.range(of: #"\A[A-Za-z0-9\-._~+/]+=*\z"#, options: .regularExpression) != nil,
              response.expires_in.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw MeetingError.message("The OAuth server returned an invalid bearer token response.")
        }
        // Without an advertised lifetime use the token once, rather than guessing
        // its expiry. Renew slightly early when a lifetime is provided.
        let ttl = response.expires_in ?? 0
        return Token(value: response.access_token, expiresAt: started.addingTimeInterval(max(0, ttl - min(30, ttl * 0.1))))
    }
    static func formEncode(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: return String(UnicodeScalar(byte))
            case 32: return "+"
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
    }
}

/// Reject redirects for credential exchanges and authenticated API calls.
/// In particular a 307/308 must not forward a client_secret POST body elsewhere.
final class CredentialRedirectBlocker: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = CredentialRedirectBlocker()
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
