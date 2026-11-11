import Foundation
import Testing
@testable import Fiber

/// What went wrong, if a `ProviderError` was thrown.
@MainActor
func providerError(_ work: () async throws -> Void) async -> ProviderError? {
    do {
        try await work()
        return nil
    } catch {
        return error as? ProviderError
    }
}

@MainActor
struct SpotifySessionTests {
    let fixture: SpotifyFixture
    var stub: SpotifyStub { fixture.stub }
    var session: SpotifySession { fixture.session }

    init() throws { fixture = try SpotifyFixture() }

    @Test func refreshesOnceAndReusesTheToken() async throws {
        fixture.api = { _ in .json(#"{"id":"u1"}"#) }
        let _: SpotifyProfile = try await session.get("/me")
        let _: SpotifyProfile = try await session.get("/me")

        #expect(stub.tokenRequests.count == 1)
        let form = stub.tokenRequests[0].bodyText
        #expect(form.contains("grant_type=refresh_token"))
        #expect(form.contains("refresh_token=refresh-1"))
        #expect(form.contains("client_id=test-client"))
        let headers = stub.calls("GET", "/me").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(headers == ["Bearer token-1", "Bearer token-1"])
    }

    @Test func parallelRequestsShareOneRefresh() async throws {
        fixture.api = { _ in .json(#"{"id":"u1"}"#) }
        async let first: SpotifyProfile = session.get("/me")
        async let second: SpotifyProfile = session.get("/me")
        _ = try await (first, second)
        #expect(stub.tokenRequests.count == 1)
    }

    @Test func savesARotatedRefreshToken() async throws {
        fixture.tokenReply = { _ in .json(#"{"access_token":"a","expires_in":3600,"refresh_token":"refresh-2"}"#) }
        fixture.api = { _ in .json(#"{"id":"u1"}"#) }
        let _: SpotifyProfile = try await session.get("/me")
        #expect(Keychain.get(fixture.key) == "refresh-2")
    }

    @Test func aRevokedSignInIsForgotten() async {
        fixture.tokenReply = { _ in .json(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#, status: 400) }
        let error = await providerError { let _: SpotifyProfile = try await session.get("/me") }
        guard case .service(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("expired"))
        #expect(!session.hasSavedSignIn)
        #expect(stub.calls("GET", "/me").isEmpty)
    }

    @Test func otherSignInFailuresKeepTheSavedSignIn() async {
        fixture.tokenReply = { _ in .json(#"{"error":"server_error","error_description":"Try later"}"#, status: 503) }
        let error = await providerError { let _: SpotifyProfile = try await session.get("/me") }
        guard case .service(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("Try later"))
        #expect(session.hasSavedSignIn)
    }

    @Test func aSignedOutSessionRefusesRequests() async throws {
        let signedOut = try SpotifyFixture(signedIn: false)
        let error = await providerError { let _: SpotifyProfile = try await signedOut.session.get("/me") }
        #expect(error == .notConnected(.spotify))
        #expect(signedOut.stub.requests.isEmpty)
    }

    @Test func retriesOnceWithAFreshTokenAfterUnauthorized() async throws {
        var served = 0
        fixture.api = { _ in
            served += 1
            return served == 1 ? .json(#"{"error":{"status":401,"message":"The access token expired"}}"#, status: 401) : .json(#"{"id":"u1"}"#)
        }
        let profile: SpotifyProfile = try await session.get("/me")
        #expect(profile.id == "u1")
        #expect(stub.tokenRequests.count == 2)
        #expect(stub.calls("GET", "/me").last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-2")
    }

    @Test func givesUpAfterASecondUnauthorized() async {
        fixture.api = { _ in .json(#"{"error":{"status":401,"message":"Invalid access token"}}"#, status: 401) }
        let error = await providerError { let _: SpotifyProfile = try await session.get("/me") }
        #expect(error != nil)
        #expect(stub.calls("GET", "/me").count == 2)
    }

    @Test func waitsOutAShortRateLimit() async throws {
        var served = 0
        fixture.api = { _ in
            served += 1
            return served == 1 ? SpotifyStub.Reply(status: 429, body: "{}", headers: ["Retry-After": "0"]) : .json(#"{"id":"u1"}"#)
        }
        let profile: SpotifyProfile = try await session.get("/me")
        #expect(profile.id == "u1")
        #expect(stub.calls("GET", "/me").count == 2)
    }

    @Test func reportsALongRateLimitWithoutWaiting() async {
        fixture.api = { _ in SpotifyStub.Reply(status: 429, body: "{}", headers: ["Retry-After": "30"]) }
        let error = await providerError { let _: SpotifyProfile = try await session.get("/me") }
        guard case .service(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("30 seconds"))
        #expect(stub.calls("GET", "/me").count == 1)
    }

    @Test func escapesQueryValues() async throws {
        fixture.api = { _ in .json("{}") }
        let _: SpotifySearchReply = try await session.get("/search", query: ["q": "AC/DC & Co+1", "type": "track"])
        let _: SpotifySearchReply = try await session.get("/search", query: ["q": "Sigur Rós", "type": "track"])
        let urls = stub.calls("GET", "/search").compactMap { $0.url?.absoluteString }
        #expect(urls == [
            "https://api.spotify.com/v1/search?q=AC%2FDC%20%26%20Co%2B1&type=track",
            "https://api.spotify.com/v1/search?q=Sigur%20R%C3%B3s&type=track",
        ])
    }

    @Test func followsAFullNextPageURL() async throws {
        fixture.api = { _ in .json(SpotifyJSON.page([])) }
        let next = "https://api.spotify.com/v1/me/tracks?offset=50&limit=50"
        let _: SpotifyPage<SpotifySavedTrack> = try await session.get(next)
        #expect(stub.calls("GET", "/me/tracks").first?.queryValues == ["offset": "50", "limit": "50"])
    }

    @Test func noContentMeansNothingToReport() async throws {
        fixture.api = { _ in .noContent }
        let state: SpotifyPlayerState? = try await session.getIfPresent("/me/player")
        #expect(state == nil)
    }

    @Test func sendsJSONBodies() async throws {
        fixture.api = { _ in .noContent }
        try await session.send("PUT", "/me/player/play", query: ["device_id": "d1"], json: ["uris": ["spotify:track:t1"]])
        let request = try #require(stub.calls("PUT", "/me/player/play").first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.queryValues == ["device_id": "d1"])
        #expect(request.bodyJSON["uris"] as? [String] == ["spotify:track:t1"])
    }

    @Test(arguments: [
        (403, #"{"error":{"status":403,"message":"Check settings on developer.spotify.com/dashboard, the user may not be registered."}}"#, "allowed list"),
        (403, #"{"error":{"status":403,"message":"Insufficient client scope"}}"#, "permission"),
        (404, #"{"error":{"status":404,"message":"Device not found","reason":"NO_ACTIVE_DEVICE"}}"#, "Enable Audio"),
        (404, #"{"error":{"status":404,"message":"Device not found"}}"#, "Fiber's player"),
        (500, #"{"error":{"status":500,"message":"Server exploded"}}"#, "Server exploded"),
    ])
    func explainsSpotifyFailures(status: Int, body: String, expected: String) async {
        fixture.api = { _ in .json(body, status: status) }
        let error = await providerError { let _: SpotifyProfile = try await session.get("/me") }
        let message: String
        switch error {
        case .service(let text)?, .playback(let text)?: message = text
        default: message = "\(String(describing: error))"
        }
        #expect(message.localizedCaseInsensitiveContains(expected), "\(message)")
    }

    @Test func explainsAnExhaustedQuota() async {
        let body = #"{"error":{"status":429,"message":"Rate limited","reason":"QUOTA_EXCEEDED"}}"#
        fixture.api = { _ in SpotifyStub.Reply(status: 429, body: body, headers: ["Retry-After": "60"]) }
        let error = await providerError { let _: SpotifyProfile = try await session.get("/me") }
        guard case .service(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("request limit"))
    }

    @Test func mapsStatusesWithoutADetailMessage() async {
        let cases: [(Int, String, ProviderError)] = [
            (403, #"{"error":{"message":"Forbidden"}}"#, .permissionDenied),
            (403, #"{"error":{"message":"Premium required","reason":"PREMIUM_REQUIRED"}}"#, .subscriptionRequired),
            (404, #"{"error":{"message":"Not found"}}"#, .notFound),
        ]
        for (status, body, expected) in cases {
            fixture.api = { _ in .json(body, status: status) }
            let error = await providerError { let _: SpotifyProfile = try await session.get("/me") }
            #expect(error == expected)
        }
    }

    @Test func networkFailuresAreReported() async throws {
        let broken = try SpotifyFixture()
        let session = SpotifySession(config: broken.config, refreshKey: broken.key, transport: { _ in throw URLError(.notConnectedToInternet) })
        let error = await providerError { let _: SpotifyProfile = try await session.get("/me") }
        guard case .network? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
    }

    @Test func cancelledRequestsStayCancellations() async throws {
        let broken = try SpotifyFixture()
        let session = SpotifySession(config: broken.config, refreshKey: broken.key, transport: { _ in throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) { let _: SpotifyProfile = try await session.get("/me") }
    }
}

struct SpotifyModelTests {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    @Test func readsBothPlaylistEntryShapes() throws {
        let json = SpotifyJSON.page([
            #"{"item":\#(SpotifyJSON.track("t1", "New Shape"))}"#,
            #"{"track":\#(SpotifyJSON.track("t2", "Old Shape"))}"#,
            "null",
            #"{"item":null}"#,
            #"{"item":{"id":"e1","name":"A Podcast","type":"episode","duration_ms":1000}}"#,
            #"{"item":{"id":null,"name":"Local File","type":"track","is_local":true,"duration_ms":1000}}"#,
        ])
        let page = try decode(SpotifyPage<SpotifyPlaylistEntry>.self, json)
        let tracks = page.items.compactMap(\.song).compactMap { SpotifyMapping.track($0) }
        #expect(tracks.map(\.title) == ["New Shape", "Old Shape"])
    }

    @Test func searchSkipsNullPlaylists() throws {
        let json = #"{"playlists":{"items":[null,\#(SpotifyJSON.playlist("p1", "Real")),null],"total":3}}"#
        let reply = try decode(SpotifySearchReply.self, json)
        #expect(reply.playlists?.items.map(\.name) == ["Real"])
        #expect(reply.tracks == nil)
    }

    @Test func mapsATrack() throws {
        let dto = try decode(SpotifyTrackDTO.self, SpotifyJSON.track("t1", "Song"))
        let track = try #require(SpotifyMapping.track(dto))
        #expect(track.id == MediaID(service: .spotify, raw: "t1"))
        #expect(track.title == "Song")
        #expect(track.artistName == "Artist")
        #expect(track.artistID?.raw == "ar1")
        #expect(track.albumID?.raw == "al1")
        #expect(track.albumTitle == "Album")
        #expect(track.duration == 200)
        #expect(track.trackNumber == 2)
    }

    @Test func tracksInsideAnAlbumTakeTheAlbumsArtwork() throws {
        let album = try #require(SpotifyMapping.album(try decode(SpotifyAlbumDTO.self, SpotifyJSON.album("al9", "Parent"))))
        let bare = try decode(SpotifyTrackDTO.self, #"{"id":"t5","name":"Bare","type":"track","duration_ms":90000,"artists":[{"id":"ar1","name":"Artist"}]}"#)
        let track = try #require(SpotifyMapping.track(bare, in: album))
        #expect(track.albumTitle == "Parent")
        #expect(track.albumID == album.id)
        #expect(track.artwork == album.artwork)
    }

    @Test func mapsAnAlbum() throws {
        let album = try #require(SpotifyMapping.album(try decode(SpotifyAlbumDTO.self, SpotifyJSON.album("al1", "Album", year: "1999-12"))))
        #expect(album.year == 1999)
        #expect(album.artistName == "Artist")
        #expect(album.shareURL?.absoluteString == "https://open.spotify.com/album/al1")
    }

    @Test func choosesAnImageThatIsSharpButNotHuge() {
        func images(_ widths: [Int?]) -> [SpotifyImage] {
            widths.map { SpotifyImage(url: "https://images.test/\($0 ?? 0)", width: $0, height: $0) }
        }
        #expect(SpotifyMapping.artwork(images([640, 300, 64])) == .remote(template: "https://images.test/640"))
        #expect(SpotifyMapping.artwork(images([3000, 640])) == .remote(template: "https://images.test/640"))
        #expect(SpotifyMapping.artwork(images([3000])) == .remote(template: "https://images.test/3000"))
        #expect(SpotifyMapping.artwork(images([nil])) == .remote(template: "https://images.test/0"))
        #expect(SpotifyMapping.artwork([]) == .none)
        #expect(SpotifyMapping.artwork(nil) == .none)
    }

    @Test func playlistsAreReadableOnlyWhenOwnedOrShared() throws {
        func dto(owner: String?, collaborative: Bool?) throws -> SpotifyPlaylistDTO {
            let ownerJSON = owner.map { #","owner":{"id":"\#($0)"}"# } ?? ""
            let shared = collaborative.map { #","collaborative":\#($0)"# } ?? ""
            return try decode(SpotifyPlaylistDTO.self, #"{"id":"p","name":"P"\#(ownerJSON)\#(shared)}"#)
        }
        #expect(SpotifyMapping.isReadable(try dto(owner: "me", collaborative: false), userID: "me"))
        #expect(SpotifyMapping.isReadable(try dto(owner: "other", collaborative: true), userID: "me"))
        #expect(!SpotifyMapping.isReadable(try dto(owner: "other", collaborative: false), userID: "me"))
        #expect(!SpotifyMapping.isReadable(try dto(owner: nil, collaborative: nil), userID: "me"))
        #expect(!SpotifyMapping.isReadable(try dto(owner: "me", collaborative: false), userID: nil))
    }

    @Test func cleansPlaylistDescriptions() throws {
        let playlist = try #require(SpotifyMapping.playlist(try decode(SpotifyPlaylistDTO.self, SpotifyJSON.playlist("p1", "Mix"))))
        #expect(playlist.notes == "Made & shared here")
        #expect(playlist.curator == "user1")
        #expect(!playlist.isEditable)
    }

    @Test func pagesTolerateMissingFields() throws {
        let page = try decode(SpotifyPage<SpotifySavedAlbum>.self, #"{"items":[{"album":\#(SpotifyJSON.album())}]}"#)
        #expect(page.items.count == 1)
        #expect(page.next == nil)
        #expect(page.total == nil)
        let empty = try decode(SpotifyPage<SpotifySavedAlbum>.self, "{}")
        #expect(empty.items.isEmpty)
    }

    @Test func readsPlayerState() throws {
        let state = try decode(SpotifyPlayerState.self, #"{"device":{"id":"d1","name":"iPhone","type":"Smartphone","is_active":true},"is_playing":true,"progress_ms":4200,"item":\#(SpotifyJSON.track("t1"))}"#)
        #expect(state.isPlaying == true)
        #expect(state.progressMs == 4200)
        #expect(state.item?.id == "t1")
        #expect(state.device?.isActive == true)
    }
}

struct SpotifyAuthCallbackTests {
    @Test func backgroundCompletionResumesOnlyOnce() async throws {
        let expected = URL(string: "fiber-test://callback?code=test")!
        let result: URL = try await withCheckedThrowingContinuation { continuation in
            let completion = SpotifyAuthCompletion(continuation)
            Task.detached {
                completion.resolve(expected, error: nil)
                completion.resolve(nil, error: CancellationError())
            }
        }
        #expect(result == expected)
    }

    @Test func failedStartIgnoresALateCallback() async {
        do {
            let _: URL = try await withCheckedThrowingContinuation { continuation in
                let completion = SpotifyAuthCompletion(continuation)
                completion.resolve(nil, error: CancellationError())
                completion.resolve(URL(string: "fiber-test://callback"), error: nil)
            }
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
    }
}
