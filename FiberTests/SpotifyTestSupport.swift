import Foundation
@testable import Fiber

/// Polls until `condition` holds, for work that finishes on its own tasks.
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Stands in for the network: records every request and answers from `handler`.
@MainActor
final class SpotifyStub {
    nonisolated struct Reply: Sendable {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
        /// Held back before answering, so a test can make replies arrive out of order.
        var delay = Duration.zero

        static func json(_ body: String, status: Int = 200) -> Reply { Reply(status: status, body: body) }
        static let noContent = Reply(status: 204)
        static let missing = Reply(status: 404, body: #"{"error":{"status":404,"message":"Not found"}}"#)
    }

    private(set) var requests: [URLRequest] = []
    var handler: (URLRequest) -> Reply = { _ in .missing }
    /// GET paths that never answer, so a background poll can't interfere with a test.
    var stalledPaths: Set<String> = []

    var transport: SpotifySession.Transport {
        { [self] request in
            guard let reply = await answer(request) else {
                try await Task.sleep(for: .seconds(3600))
                throw URLError(.timedOut)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            if reply.delay > .zero { try await Task.sleep(for: reply.delay) }
            return (Data(reply.body.utf8), response)
        }
    }

    private func answer(_ request: URLRequest) -> Reply? {
        requests.append(request)
        if request.httpMethod == "GET", stalledPaths.contains(request.url?.path ?? "") { return nil }
        return handler(request)
    }

    /// Requests to the Web API (not the token endpoint) with this method and path, e.g. ("PUT", "/me/player/play").
    func calls(_ method: String, _ path: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method && $0.url?.host == "api.spotify.com" && $0.url?.path == "/v1" + path }
    }

    var tokenRequests: [URLRequest] { requests.filter { $0.url?.host == "accounts.spotify.com" } }

    /// Waits until at least `count` requests with this method and path have arrived.
    @discardableResult
    func waitForCall(_ method: String, _ path: String, count: Int = 1) async -> Bool {
        await eventually { calls(method, path).count >= count }
    }
}

extension URLRequest {
    var queryValues: [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    var bodyText: String { httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    var bodyJSON: [String: Any] { (try? JSONSerialization.jsonObject(with: httpBody ?? Data())) as? [String: Any] ?? [:] }
}

/// A signed-in (or signed-out) `SpotifySession` wired to a `SpotifyStub`.
@MainActor
final class SpotifyFixture {
    let stub = SpotifyStub()
    let key = "spotify.test.\(UUID().uuidString)"
    let config = SpotifyConfig(clientID: "test-client", redirectURI: "fiber-test://callback")
    private(set) var session: SpotifySession!
    /// Answers Web API requests. By default it serves `routes`; a test can replace it.
    var api: (URLRequest) -> SpotifyStub.Reply = { _ in .missing }
    var tokenReply: (Int) -> SpotifyStub.Reply = { count in
        .json(#"{"access_token":"token-\#(count)","expires_in":3600,"token_type":"Bearer"}"#)
    }
    private var tokenCount = 0
    private var routes: [String: (URLRequest) -> SpotifyStub.Reply] = [:]

    init(signedIn: Bool = true) throws {
        if signedIn { Keychain.set("refresh-1", for: key) }
        // Weak, because a playback task can outlive the test that started it.
        stub.handler = { [weak self] request in
            guard let self else { return .missing }
            guard request.url?.host == "accounts.spotify.com" else { return api(request) }
            tokenCount += 1
            return tokenReply(tokenCount)
        }
        api = { [weak self] request in
            guard let self, let path = request.url?.path, path.hasPrefix("/v1"),
                  let reply = routes[String(path.dropFirst(3))]
            else { return .missing }
            return reply(request)
        }
        session = SpotifySession(config: config, refreshKey: key, transport: stub.transport)
    }

    deinit { Keychain.remove(key) }

    /// Answers requests to this Web API path (without "/v1") with `body`.
    func route(_ path: String, _ body: String, status: Int = 200) {
        routes[path] = { _ in .json(body, status: status) }
    }

    /// Answers requests to this Web API path (without "/v1") by looking at the request.
    func route(_ path: String, _ reply: @escaping (URLRequest) -> SpotifyStub.Reply) {
        routes[path] = reply
    }
}

enum SpotifyJSON {
    static func image(_ id: String, width: Int = 640) -> String {
        #"{"url":"https://images.test/\#(id)-\#(width)","width":\#(width),"height":\#(width)}"#
    }

    static func artist(_ id: String = "ar1", _ name: String = "Artist") -> String {
        #"{"id":"\#(id)","name":"\#(name)","images":[\#(image(id))],"genres":["pop"]}"#
    }

    static func album(_ id: String = "al1", _ name: String = "Album", artist: String = "ar1", year: String = "2020-05-01",
                      type: String = "album", tracks: String? = nil) -> String {
        let embedded = tracks.map { #","tracks":\#($0)"# } ?? ""
        return #"{"id":"\#(id)","name":"\#(name)","album_type":"\#(type)","release_date":"\#(year)","images":[\#(image(id)),\#(image(id, width: 64))],"artists":[\#(self.artist(artist, "Artist"))],"external_urls":{"spotify":"https://open.spotify.com/album/\#(id)"}\#(embedded)}"#
    }

    static func track(_ id: String, _ name: String = "Song", artist: String = "ar1", album: String = "al1") -> String {
        #"{"id":"\#(id)","name":"\#(name)","type":"track","duration_ms":200000,"explicit":false,"track_number":2,"artists":[\#(self.artist(artist, "Artist"))],"album":\#(self.album(album, "Album", artist: artist))}"#
    }

    /// A track as it appears inside its album's own track list: no album, no artwork.
    static func bareTrack(_ id: String, _ name: String = "Song", number: Int = 1) -> String {
        #"{"id":"\#(id)","name":"\#(name)","type":"track","duration_ms":180000,"track_number":\#(number),"artists":[\#(artist())]}"#
    }

    static func playlist(_ id: String, _ name: String, owner: String = "user1", collaborative: Bool = false) -> String {
        #"{"id":"\#(id)","name":"\#(name)","description":"Made &amp; shared <a href=\"x\">here</a>","collaborative":\#(collaborative),"images":[\#(image(id))],"owner":{"id":"\#(owner)","display_name":"\#(owner)"}}"#
    }

    static func page(_ items: [String], next: String? = nil, total: Int? = nil) -> String {
        let next = next.map { #""\#($0)""# } ?? "null"
        return #"{"items":[\#(items.joined(separator: ","))],"next":\#(next),"total":\#(total ?? items.count)}"#
    }
}
