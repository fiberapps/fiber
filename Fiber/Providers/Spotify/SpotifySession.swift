import AuthenticationServices
import CryptoKit
import UIKit

/// The Spotify app registration this build was made with. Written into the
/// bundle by `scripts/prepare_spotify_config.py`; never committed.
nonisolated struct SpotifyConfig: Decodable, Sendable {
    var clientID: String
    var redirectURI: String

    static func load() -> SpotifyConfig? {
        guard let url = Bundle.main.url(forResource: "SpotifyConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(SpotifyConfig.self, from: data),
              !config.clientID.isEmpty
        else { return nil }
        return config
    }
}

/// Signs in with Spotify's Authorization Code + PKCE flow (no client secret),
/// keeps the refresh token in the Keychain, and sends authorized Web API requests.
final class SpotifySession: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let defaultRefreshKey = "spotify.refreshToken"
    private static let apiBase = "https://api.spotify.com/v1"
    private static let queryAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
    private static let scopes = [
        "streaming", "user-read-email", "user-read-private", "user-read-playback-state", "user-modify-playback-state", "user-read-currently-playing",
        "user-library-read", "playlist-read-private", "playlist-read-collaborative", "user-top-read", "user-read-recently-played",
    ]

    private struct TokenReply: Decodable {
        var access_token: String
        var expires_in: Double
        var refresh_token: String?
    }

    private struct TokenFailure: Decodable {
        var error: String?
        var error_description: String?
    }

    private struct APIFailure: Decodable {
        struct Detail: Decodable {
            var message: String?
            var reason: String?
        }
        var error: Detail
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    let config: SpotifyConfig
    private let refreshKey: String
    private let transport: Transport
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshing: Task<String, Error>?
    private var webSession: ASWebAuthenticationSession?
    /// The window the sign-in page is shown over; `signIn()` sets it before the web session starts.
    private var anchor: ASPresentationAnchor!

    init(config: SpotifyConfig,
         refreshKey: String = SpotifySession.defaultRefreshKey,
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.config = config
        self.refreshKey = refreshKey
        self.transport = transport
    }

    var hasSavedSignIn: Bool { Keychain.get(refreshKey) != nil }

    func signOut() {
        Keychain.remove(refreshKey)
        accessToken = nil
        expiry = .distantPast
    }

    // MARK: Sign-in

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    func signIn() async throws {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
            throw ProviderError.service("Fiber has no open window to show the Spotify sign-in over.")
        }
        anchor = window

        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let state = Self.randomString(16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
        ]
        guard let url = components.url, let scheme = URL(string: config.redirectURI)?.scheme else {
            throw ProviderError.service("The Spotify redirect address in this build isn't valid.")
        }

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let result = SpotifyAuthCompletion(continuation)
            // AuthenticationServices can invoke completion from an XPC/background queue.
            let completion: @Sendable (URL?, Error?) -> Void = { callbackURL, error in
                result.resolve(callbackURL, error: error)
            }
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme), completionHandler: completion)
            session.presentationContextProvider = self
            webSession = session
            if !session.start() {
                result.resolve(nil, error: ProviderError.service("The Spotify sign-in page couldn't be opened."))
            }
        }
        webSession = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let denied = items.first(where: { $0.name == "error" })?.value {
            throw ProviderError.service("Spotify didn't grant access (\(denied)).")
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw ProviderError.service("Spotify's sign-in reply didn't match this request.") }

        try await exchange([
            "grant_type": "authorization_code", "code": code, "redirect_uri": config.redirectURI,
            "client_id": config.clientID, "code_verifier": verifier,
        ])
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }

    // MARK: Tokens

    @discardableResult
    private func exchange(_ fields: [String: String]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" in a form body means a space, so a literal plus has to be escaped.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)

        let (data, response) = try await perform(request)
        guard response.statusCode == 200, let reply = try? JSONDecoder().decode(TokenReply.self, from: data) else {
            let failure = try? JSONDecoder().decode(TokenFailure.self, from: data)
            if failure?.error == "invalid_grant" {
                // Refresh tokens last six months, or are revoked in the Spotify account settings.
                signOut()
                throw ProviderError.service("Your Spotify sign-in has expired. Connect Spotify again in Settings.")
            }
            let detail = failure?.error_description ?? failure?.error ?? "status \(response.statusCode)"
            throw ProviderError.service("Spotify rejected the sign-in (\(detail)).")
        }
        accessToken = reply.access_token
        expiry = Date().addingTimeInterval(reply.expires_in - 60)
        if let refresh = reply.refresh_token { Keychain.set(refresh, for: refreshKey) }
        return reply.access_token
    }

    /// One refresh at a time: Spotify may rotate the refresh token, so two
    /// parallel refreshes could invalidate each other.
    func playbackToken() async throws -> String { try await validToken() }

    private func validToken() async throws -> String {
        if let accessToken, Date() < expiry { return accessToken }
        if let refreshing { return try await refreshing.value }
        guard let refresh = Keychain.get(refreshKey) else { throw ProviderError.notConnected(.spotify) }
        let fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": config.clientID]
        let task = Task { try await exchange(fields) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw ProviderError.service("Spotify sent an unreadable reply.") }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProviderError.network("Spotify couldn't be reached (\(error.localizedDescription)).")
        }
    }

    // MARK: Web API

    /// Sends one Web API request. `path` is either "/me/…" or a full "next page" URL.
    @discardableResult
    func send(_ method: String = "GET", _ path: String, query: [String: String] = [:], json: [String: Any]? = nil) async throws -> Data {
        guard var components = URLComponents(string: path.hasPrefix("http") ? path : Self.apiBase + path) else { throw ProviderError.notFound }
        if !query.isEmpty {
            // Everything except unreserved characters is escaped, so a "+" or "&" in a search term can't change the request.
            let extra = query.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed))
            }
            components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? []) + extra
        }
        guard let url = components.url else { throw ProviderError.notFound }
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }

        var retriedToken = false
        var waitedForLimit = false
        while true {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = method
            request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            let (data, response) = try await perform(request)
            let retryAfter = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            switch response.statusCode {
            case 200..<300:
                return data
            case 401 where !retriedToken:
                // The access token expired early; get a new one and retry once.
                retriedToken = true
                expiry = .distantPast
            case 429 where !waitedForLimit && retryAfter <= 6:
                waitedForLimit = true
                try await Task.sleep(for: .seconds(retryAfter + 0.1))
            default:
                throw Self.failure(status: response.statusCode, data: data, retryAfter: retryAfter)
            }
        }
    }

    func get<Value: Decodable>(_ path: String, query: [String: String] = [:], as type: Value.Type = Value.self) async throws -> Value {
        try Self.decode(try await send("GET", path, query: query), path: path)
    }

    /// For endpoints that answer 204 with no body when there is nothing to report.
    func getIfPresent<Value: Decodable>(_ path: String, query: [String: String] = [:], as type: Value.Type = Value.self) async throws -> Value? {
        let data = try await send("GET", path, query: query)
        return data.isEmpty ? nil : try Self.decode(data, path: path)
    }

    private static func decode<Value: Decodable>(_ data: Data, path: String) throws -> Value {
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw ProviderError.service("Spotify sent a reply Fiber couldn't read (\(path.components(separatedBy: "?")[0])).")
        }
    }

    private static func failure(status: Int, data: Data, retryAfter: Double) -> ProviderError {
        let detail = (try? JSONDecoder().decode(APIFailure.self, from: data))?.error
        let message = detail?.message ?? "status \(status)"
        if detail?.reason == "PREMIUM_REQUIRED" { return .subscriptionRequired }
        if detail?.reason == "NO_ACTIVE_DEVICE" {
            return .playback("Spotify's player inside Fiber isn't connected yet. Open Spotify in Fiber and tap Enable Audio, then try again.")
        }
        if detail?.reason == "QUOTA_EXCEEDED" {
            return .service("Spotify's request limit for this app has been reached. Try again later.")
        }
        switch status {
        case 403 where message.localizedCaseInsensitiveContains("registered"):
            return .service("This Spotify account isn't on the allowed list for this app. The app owner has to add it in the Spotify developer dashboard.")
        case 403 where message.localizedCaseInsensitiveContains("scope"):
            return .service("Spotify needs permission Fiber wasn't given. Disconnect Spotify in Settings and connect again.")
        case 403:
            return .permissionDenied
        case 404 where message.localizedCaseInsensitiveContains("device"):
            return .playback("Spotify couldn't find Fiber's player. Open Spotify in Fiber, tap Enable Audio, then try again.")
        case 404:
            return .notFound
        case 429:
            return .service("Spotify is limiting requests right now. Try again in \(Int(retryAfter.rounded(.up))) seconds.")
        default:
            return .service("Spotify answered: \(message)")
        }
    }
}

/// Exactly-once continuation delivery from AuthenticationServices' arbitrary callback queue.
nonisolated final class SpotifyAuthCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
    func resolve(_ url: URL?, error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if let url { pending.resume(returning: url) }
        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
            pending.resume(throwing: CancellationError())
        } else {
            pending.resume(throwing: error ?? ProviderError.service("Spotify sign-in ended unexpectedly."))
        }
    }
}
