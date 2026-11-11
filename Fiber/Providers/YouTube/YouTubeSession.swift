import Foundation

/// Signed-in calls to YouTube Music's own browse API, plus the iOS player's
/// audio address for a song. The refresh material is the Google session cookie
/// from the sign-in page, kept in the Keychain.
final class YouTubeSession {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let cookieKey = "youtube.cookie"
    static let accountKey = "youtube.account"
    private static let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"

    private let transport: Transport
    private(set) var cookieHeader: String?
    private(set) var accountName: String?

    init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
        cookieHeader = Keychain.get(Self.cookieKey)
        accountName = Keychain.get(Self.accountKey)
    }

    var hasCookies: Bool { cookieHeader.flatMap(YouTubeAuth.sapisid(in:)) != nil }

    func store(cookieHeader: String, account: String?) {
        self.cookieHeader = cookieHeader
        Keychain.set(cookieHeader, for: Self.cookieKey)
        accountName = account
        if let account, !account.isEmpty {
            Keychain.set(account, for: Self.accountKey)
        }
    }

    func signOut() {
        cookieHeader = nil
        accountName = nil
        Keychain.remove(Self.cookieKey)
        Keychain.remove(Self.accountKey)
    }

    func browse(_ browseID: String) async throws -> [String: Any] {
        try await remix("browse", ["browseId": browseID])
    }

    func browseContinuation(_ token: String) async throws -> [String: Any] {
        try await remix("browse", ["continuation": token])
    }

    func search(_ term: String) async throws -> [String: Any] {
        try await remix("search", ["query": term])
    }

    /// Follows a few extra pages so an album or playlist isn't only its first screen.
    func pages(for browseID: String, limit: Int = 5) async throws -> [Any] {
        var pages: [Any] = [try await browse(browseID)]
        var seen = Set<String>()
        while pages.count < limit, let token = YouTubeCatalog.continuationToken(in: pages.last!), seen.insert(token).inserted {
            pages.append(try await browseContinuation(token))
        }
        return pages
    }

    func audioURL(for videoID: String) async throws -> URL {
        let json = try await post(host: "https://www.youtube.com", endpoint: "player", client: .ios, fields: [
            "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true,
        ])
        return try YouTubeAudio.bestURL(in: json)
    }

    // MARK: Requests

    private enum Client { case remix, ios }

    private func remix(_ endpoint: String, _ fields: [String: Any]) async throws -> [String: Any] {
        try await post(host: "https://music.youtube.com", endpoint: endpoint, client: .remix, fields: fields)
    }

    private func post(host: String, endpoint: String, client: Client, fields: [String: Any]) async throws -> [String: Any] {
        guard var components = URLComponents(string: "\(host)/youtubei/v1/\(endpoint)") else { throw ProviderError.service("YouTube Music's address was invalid.") }
        components.queryItems = [URLQueryItem(name: "key", value: Self.apiKey), URLQueryItem(name: "prettyPrint", value: "false")]
        guard let url = components.url else { throw ProviderError.service("YouTube Music's address was invalid.") }
        var body: [String: Any] = ["context": context(client)]
        for (key, value) in fields { body[key] = value }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Origin")
        request.setValue(host + "/", forHTTPHeaderField: "Referer")
        request.setValue(client == .ios ? YouTubeAudio.playbackUserAgent : remixUserAgent, forHTTPHeaderField: "User-Agent")
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            if let sapisid = YouTubeAuth.sapisid(in: cookieHeader) {
                let stamp = Int(Date().timeIntervalSince1970)
                request.setValue(YouTubeAuth.authorization(sapisid: sapisid, origin: host, timestamp: stamp), forHTTPHeaderField: "Authorization")
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.network("YouTube Music couldn't be reached (\(error.localizedDescription)).")
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.service("YouTube Music sent an unreadable reply.") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.service("YouTube Music sent a reply Fiber couldn't read.")
        }
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "status \(http.statusCode)"
            if http.statusCode == 401 || (error["status"] as? String) == "UNAUTHENTICATED" {
                throw ProviderError.notConnected(.youtubeMusic)
            }
            throw ProviderError.service("YouTube Music answered: \(message)")
        }
        return json
    }

    private var remixUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    private func context(_ client: Client) -> [String: Any] {
        switch client {
        case .remix:
            return ["client": [
                "clientName": "WEB_REMIX",
                "clientVersion": remixVersion,
                "hl": "en",
                "gl": "US",
            ]]
        case .ios:
            return ["client": [
                "clientName": "IOS",
                "clientVersion": YouTubeAudio.iosClientVersion,
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.0",
                "hl": "en",
                "gl": "US",
            ]]
        }
    }

    private var remixVersion: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return "1.\(formatter.string(from: Date())).01.00"
    }
}
