import Foundation
import Testing
@testable import Fiber

// Rows as Spotify wraps them in lists.
private func savedAlbum(_ album: String) -> String { #"{"added_at":"2024-01-01T00:00:00Z","album":\#(album)}"# }
private func savedTrack(_ track: String) -> String { #"{"added_at":"2024-01-01T00:00:00Z","track":\#(track)}"# }
private func historyRow(_ track: String) -> String { #"{"played_at":"2024-01-01T00:00:00Z","track":\#(track)}"# }
private func playlistItem(_ track: String) -> String { #"{"added_at":"2024-01-01T00:00:00Z","item":\#(track)}"# }
private func oldPlaylistTrack(_ track: String) -> String { #"{"added_at":"2024-01-01T00:00:00Z","track":\#(track)}"# }

private let episode = #"{"id":"e1","name":"An Episode","type":"episode","duration_ms":1000}"#
private let localFile = #"{"id":"l1","name":"Local File","type":"track","is_local":true,"duration_ms":1000}"#
private let serverError = #"{"error":{"status":500,"message":"boom"}}"#
private let forbidden = #"{"error":{"status":403,"message":"Forbidden"}}"#

/// A search reply holding only the lists given.
private func searchReply(tracks: [String]? = nil, albums: [String]? = nil, artists: [String]? = nil, playlists: [String]? = nil) -> String {
    let lists = [("tracks", tracks), ("albums", albums), ("artists", artists), ("playlists", playlists)]
    let parts = lists.compactMap { name, items in items.map { #""\#(name)":\#(SpotifyJSON.page($0))"# } }
    return "{" + parts.joined(separator: ",") + "}"
}

/// Serves `total` saved songs a page at a time, the way Spotify pages /me/tracks.
private func savedTracksReply(total: Int, slowOffset: Int? = nil) -> (URLRequest) -> SpotifyStub.Reply {
    { request in
        let values = request.queryValues
        let limit = Int(values["limit"] ?? "") ?? 50
        let offset = Int(values["offset"] ?? "") ?? 0
        let end = min(offset + limit, total)
        let next = end < total ? "https://api.spotify.com/v1/me/tracks?offset=\(end)&limit=\(limit)" : nil
        let rows = (offset..<max(offset, end)).map { savedTrack(SpotifyJSON.bareTrack("t\($0)")) }
        var reply = SpotifyStub.Reply.json(SpotifyJSON.page(rows, next: next, total: total))
        if offset == slowOffset { reply.delay = .milliseconds(150) }
        return reply
    }
}

private func spotifyID(_ raw: String) -> MediaID { MediaID(service: .spotify, raw: raw) }

@MainActor
struct SpotifyProviderTests {
    let fixture: SpotifyFixture
    let provider: SpotifyProvider
    var stub: SpotifyStub { fixture.stub }

    init() async throws {
        fixture = try SpotifyFixture()
        fixture.route("/me", #"{"id":"user1","display_name":"Breno"}"#)
        provider = SpotifyProvider(session: fixture.session)
        await provider.restore()
    }

    /// Plenty of everything, with one recent album listened to twice and one playlist that isn't the user's.
    private func serveHome() {
        fixture.route("/me/player/recently-played", SpotifyJSON.page([
            historyRow(SpotifyJSON.track("h1", album: "al1")),
            historyRow(SpotifyJSON.track("h2", album: "al1")),
            historyRow(SpotifyJSON.track("h3", album: "al2")),
        ]))
        fixture.route("/me/playlists", SpotifyJSON.page([
            SpotifyJSON.playlist("mine", "Mine"),
            SpotifyJSON.playlist("theirs", "Theirs", owner: "someone"),
        ]))
        fixture.route("/me/albums", SpotifyJSON.page([savedAlbum(SpotifyJSON.album("sa1"))]))
        fixture.route("/me/top/artists", SpotifyJSON.page([SpotifyJSON.artist("ta1", "Top Artist")]))
        fixture.route("/me/top/tracks", SpotifyJSON.page([SpotifyJSON.track("tt1")]))
    }

    // MARK: Connection

    @Test func restoringShowsTheAccountName() {
        #expect(provider.connection == .connected(account: "Breno"))
        #expect(stub.calls("GET", "/me").count == 1)
    }

    @Test func theAccountIDStandsInWhenThereIsNoName() async throws {
        let other = try SpotifyFixture()
        other.route("/me", #"{"id":"user9"}"#)
        let nameless = SpotifyProvider(session: other.session)
        await nameless.restore()
        #expect(nameless.connection == .connected(account: "user9"))
    }

    @Test func withoutASavedSignInNothingIsAsked() async throws {
        let signedOut = try SpotifyFixture(signedIn: false)
        let fresh = SpotifyProvider(session: signedOut.session)
        await fresh.restore()
        #expect(fresh.connection == .disconnected)
        #expect(signedOut.stub.requests.isEmpty)
    }

    @Test func anExpiredSignInAsksToConnectAgain() async throws {
        let expired = try SpotifyFixture()
        expired.tokenReply = { _ in .json(#"{"error":"invalid_grant"}"#, status: 400) }
        let fresh = SpotifyProvider(session: expired.session)
        await fresh.restore()
        guard case .failed(let message) = fresh.connection else { Issue.record("Unexpected \(fresh.connection)"); return }
        #expect(message.contains("expired"))
        #expect(!expired.session.hasSavedSignIn)
        let error = await providerError { _ = try await fresh.library() }
        #expect(error == .notConnected(.spotify))
    }

    @Test func aFailedAccountLookupIsReported() async throws {
        let broken = try SpotifyFixture()
        broken.route("/me", serverError, status: 500)
        let fresh = SpotifyProvider(session: broken.session)
        await fresh.restore()
        guard case .failed(let message) = fresh.connection else { Issue.record("Unexpected \(fresh.connection)"); return }
        #expect(message.contains("boom"))
    }

    @Test func aBuildWithoutAnAppRegistrationExplainsWhy() async {
        let unregistered = SpotifyProvider(session: nil)
        guard case .unavailable(let reason) = unregistered.connection else { Issue.record("Unexpected \(unregistered.connection)"); return }
        #expect(reason.contains("SPOTIFY_CLIENT_ID"))

        await unregistered.connect()
        await unregistered.restore()
        await unregistered.disconnect()
        #expect(unregistered.connection == .unavailable(reason))

        let error = await providerError { _ = try await unregistered.library() }
        #expect(error == .notConnected(.spotify))
        #expect(throws: ProviderError.self) { _ = try unregistered.makeEngine() }
    }

    @Test func disconnectingForgetsTheSignIn() async {
        await provider.disconnect()
        #expect(provider.connection == .disconnected)
        #expect(!fixture.session.hasSavedSignIn)
        let error = await providerError { _ = try await provider.library() }
        #expect(error == .notConnected(.spotify))
    }

    @Test func everyPlayUsesTheSameEngine() throws {
        let first = try provider.makeEngine()
        let second = try provider.makeEngine()
        #expect(first === second)
    }

    // MARK: Paging

    @Test func aShortListIsOnePage() async throws {
        fixture.route("/me/albums", SpotifyJSON.page([savedAlbum(SpotifyJSON.album("al1"))]))
        let albums = try await SpotifyProvider.fetchAll(fixture.session, "/me/albums", maxItems: 100, as: SpotifySavedAlbum.self)
        #expect(albums.count == 1)
        let calls = stub.calls("GET", "/me/albums")
        #expect(calls.count == 1)
        #expect(calls.first?.queryValues["limit"] == "50")
    }

    @Test func theRestOfALongListArrivesInOrder() async throws {
        // The second page is the slowest, so it finishes after the pages behind it.
        fixture.route("/me/tracks", savedTracksReply(total: 450, slowOffset: 50))
        let songs = try await SpotifyProvider.fetchAll(fixture.session, "/me/tracks", maxItems: 1000, as: SpotifySavedTrack.self)
        #expect(songs.compactMap(\.track.id) == (0..<450).map { "t\($0)" })

        let offsets = stub.calls("GET", "/me/tracks").map { Int($0.queryValues["offset"] ?? "0") ?? -1 }.sorted()
        #expect(offsets == (0..<9).map { $0 * 50 })
    }

    @Test func theLimitStopsFurtherPages() async throws {
        fixture.route("/me/tracks", savedTracksReply(total: 500))
        let songs = try await SpotifyProvider.fetchAll(fixture.session, "/me/tracks", maxItems: 120, as: SpotifySavedTrack.self)
        #expect(songs.count == 120)
        #expect(stub.calls("GET", "/me/tracks").count == 3)
    }

    @Test func nextLinksAreFollowedWhenThereIsNoTotal() async throws {
        let first = savedAlbum(SpotifyJSON.album("al1")), second = savedAlbum(SpotifyJSON.album("al2")), third = savedAlbum(SpotifyJSON.album("al3"))
        fixture.route("/me/albums") { request in
            if request.queryValues["offset"] == nil {
                return .json(#"{"items":[\#(first),\#(second)],"next":"https://api.spotify.com/v1/me/albums?offset=2&limit=2"}"#)
            }
            return .json(#"{"items":[\#(third)],"next":null}"#)
        }
        let albums = try await SpotifyProvider.fetchAll(fixture.session, "/me/albums", limit: 2, maxItems: 10, as: SpotifySavedAlbum.self)
        #expect(albums.compactMap(\.album.id) == ["al1", "al2", "al3"])
        #expect(stub.calls("GET", "/me/albums").count == 2)
    }

    @Test func aFailingPageFailsTheWholeList() async {
        let pages = savedTracksReply(total: 200)
        fixture.route("/me/tracks") { request in
            request.queryValues["offset"] == "100" ? .json(serverError, status: 500) : pages(request)
        }
        let error = await providerError {
            _ = try await SpotifyProvider.fetchAll(fixture.session, "/me/tracks", maxItems: 1000, as: SpotifySavedTrack.self)
        }
        guard case .service(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("boom"))
    }

    // MARK: Library

    @Test func theLibraryKeepsWhatCanBeUsed() async throws {
        fixture.route("/me/albums", SpotifyJSON.page([savedAlbum(SpotifyJSON.album("al1")), savedAlbum(SpotifyJSON.album("al2"))]))
        fixture.route("/me/tracks", SpotifyJSON.page([
            savedTrack(SpotifyJSON.track("t1")), savedTrack(localFile), savedTrack(episode), savedTrack(SpotifyJSON.track("t2")),
        ]))
        fixture.route("/me/playlists", SpotifyJSON.page([
            SpotifyJSON.playlist("mine", "Mine"),
            SpotifyJSON.playlist("theirs", "Theirs", owner: "someone"),
            SpotifyJSON.playlist("shared", "Shared", owner: "someone", collaborative: true),
        ]))

        let library = try await provider.library()
        #expect(library.albums.map(\.id.raw) == ["al1", "al2"])
        #expect(library.songs.map(\.id.raw) == ["t1", "t2"])
        #expect(library.playlists.map(\.id.raw) == ["mine", "shared"])
        #expect(library.songs.allSatisfy { $0.id.service == .spotify })
    }

    @Test func aRefusedLibraryReadPointsToReconnecting() async {
        fixture.route("/me/albums", SpotifyJSON.page([]))
        fixture.route("/me/playlists", SpotifyJSON.page([]))
        fixture.route("/me/tracks", forbidden, status: 403)
        let error = await providerError { _ = try await provider.library() }
        guard case .service(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("disconnect Spotify"))
    }

    // MARK: Home

    @Test func homeShowsEveryShelfTheAccountHasContentFor() async throws {
        serveHome()
        let shelves = try await provider.homeShelves()
        #expect(shelves.map(\.id) == ["sp-home-recent", "sp-home-playlists", "sp-home-albums", "sp-home-songs", "sp-home-artists"])
        #expect(shelves[0].entries.map(\.id.raw) == ["al1", "al2"])
        #expect(shelves[0].entries.allSatisfy { $0.kicker == "Recently Played" })
        #expect(shelves[1].entries.map(\.id.raw) == ["mine"])
        #expect(shelves[2].entries.map(\.id.raw) == ["sa1"])
        #expect(shelves[3].entries.map(\.id.raw) == ["tt1"])
        #expect(shelves[4].entries.map(\.id.raw) == ["ta1"])
        #expect(stub.calls("GET", "/me/top/tracks").first?.queryValues["time_range"] == "medium_term")
    }

    @Test func homeSurvivesOneShelfFailing() async throws {
        serveHome()
        fixture.route("/me/top/tracks", forbidden, status: 403)
        let shelves = try await provider.homeShelves()
        #expect(shelves.map(\.id) == ["sp-home-recent", "sp-home-playlists", "sp-home-albums", "sp-home-artists"])
    }

    @Test func homeReportsTheProblemWhenEverythingFails() async {
        fixture.api = { _ in .json(serverError, status: 500) }
        let error = await providerError { _ = try await provider.homeShelves() }
        guard case .service(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("boom"))
    }

    @Test func anAccountWithNoHistoryFallsBackToNewReleases() async throws {
        for path in ["/me/player/recently-played", "/me/playlists", "/me/albums", "/me/top/artists", "/me/top/tracks"] {
            fixture.route(path, SpotifyJSON.page([]))
        }
        fixture.route("/search", searchReply(albums: [SpotifyJSON.album("n1", "New One")]))
        let shelves = try await provider.homeShelves()
        #expect(shelves.map(\.id) == ["sp-new-feature"])
        #expect(shelves.first?.entries.map(\.id.raw) == ["n1"])
    }

    // MARK: New

    @Test func newReleasesLeadWithSixAndListTheRest() async throws {
        let firstPage = (1...10).map { SpotifyJSON.album("n\($0)", "New \($0)", type: $0 == 2 ? "single" : "album") }
        // Repeats n1, as overlapping pages do.
        let secondPage = [SpotifyJSON.album("n1")] + (11...14).map { SpotifyJSON.album("n\($0)", "New \($0)") }
        fixture.route("/search") { request in
            switch request.queryValues["offset"] {
            case nil: return .json(searchReply(albums: firstPage))
            case "10": return .json(searchReply(albums: secondPage))
            default: return .json(serverError, status: 500)
            }
        }

        let shelves = try await provider.newShelves()
        #expect(shelves.map(\.id) == ["sp-new-feature", "sp-new-albums"])
        #expect(shelves[0].entries.map(\.id.raw) == (1...6).map { "n\($0)" })
        #expect(shelves[0].entries[0].kicker == "New Release")
        #expect(shelves[0].entries[1].kicker == "New Single")
        #expect(shelves[1].entries.map(\.id.raw) == (7...14).map { "n\($0)" })
        #expect(shelves[1].canExpand)
        #expect(stub.calls("GET", "/search").allSatisfy { $0.queryValues["q"] == "tag:new" && $0.queryValues["type"] == "album" })
    }

    @Test func noNewReleasesMeansNoShelves() async throws {
        fixture.route("/search", searchReply(albums: []))
        #expect(try await provider.newShelves().isEmpty)
    }

    @Test func aFailedNewReleasesSearchIsReported() async {
        fixture.route("/search", serverError, status: 500)
        let error = await providerError { _ = try await provider.newShelves() }
        guard case .service(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("boom"))
    }

    // MARK: Search

    @Test func searchMergesTwoPagesOfSongsAndKeepsOpenablePlaylists() async throws {
        fixture.route("/search") { request in
            if request.queryValues["type"] == "track" {
                return .json(searchReply(tracks: [SpotifyJSON.track("t2"), SpotifyJSON.track("t3")]))
            }
            return .json(searchReply(
                tracks: [SpotifyJSON.track("t1"), SpotifyJSON.track("t2")],
                albums: [SpotifyJSON.album("al1")],
                artists: [SpotifyJSON.artist("ar1")],
                // Search results can contain null playlists.
                playlists: ["null", SpotifyJSON.playlist("mine", "Mine"), SpotifyJSON.playlist("theirs", "Theirs", owner: "someone")]))
        }

        let results = try await provider.search("  Daft Punk ")
        #expect(results.tracks.map(\.id.raw) == ["t1", "t2", "t3"])
        #expect(results.albums.map(\.id.raw) == ["al1"])
        #expect(results.artists.map(\.id.raw) == ["ar1"])
        #expect(results.playlists.map(\.id.raw) == ["mine"])

        let calls = stub.calls("GET", "/search")
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.queryValues["q"] == "Daft Punk" && $0.queryValues["limit"] == "10" })
        #expect(Set(calls.map { $0.queryValues["type"] ?? "" }) == ["track,album,artist,playlist", "track"])
    }

    @Test func aBlankSearchAsksNothing() async throws {
        let before = stub.requests.count
        let results = try await provider.search("   ")
        #expect(results.isEmpty)
        #expect(stub.requests.count == before)
    }

    @Test func aMissingSecondPageOfSongsIsIgnored() async throws {
        fixture.route("/search") { request in
            if request.queryValues["type"] == "track" { return .json(serverError, status: 500) }
            return .json(searchReply(tracks: [SpotifyJSON.track("t1")]))
        }
        let results = try await provider.search("anything")
        #expect(results.tracks.map(\.id.raw) == ["t1"])
    }

    @Test func aFailedSearchIsReported() async {
        fixture.route("/search") { request in
            if request.queryValues["type"] == "track" { return .json(searchReply(tracks: [])) }
            return .json(serverError, status: 500)
        }
        let error = await providerError { _ = try await provider.search("anything") }
        guard case .service(let message)? = error else { Issue.record("Unexpected \(String(describing: error))"); return }
        #expect(message.contains("boom"))
    }

    // MARK: Albums

    @Test func anAlbumListsItsSongsAcrossPages() async throws {
        let firstPage = SpotifyJSON.page(
            [SpotifyJSON.bareTrack("t1", "One", number: 1), SpotifyJSON.bareTrack("t2", "Two", number: 2)],
            next: "https://api.spotify.com/v1/albums/al1/tracks?offset=2&limit=2", total: 3)
        fixture.route("/albums/al1", SpotifyJSON.album("al1", "Album", tracks: firstPage))
        fixture.route("/albums/al1/tracks", SpotifyJSON.page([SpotifyJSON.bareTrack("t3", "Three", number: 3)]))
        fixture.route("/artists/ar1/albums", SpotifyJSON.page([SpotifyJSON.album("al1"), SpotifyJSON.album("al2", "Other")]))

        let detail = try await provider.albumDetail(spotifyID("al1"))
        #expect(detail.tracks.map(\.title) == ["One", "Two", "Three"])
        // Songs listed inside an album carry no album or artwork of their own.
        #expect(detail.tracks.allSatisfy { $0.albumID == detail.album.id && $0.albumTitle == "Album" && $0.artwork == detail.album.artwork })
        #expect(detail.moreByArtist.map(\.id.raw) == ["al2"])
        #expect(stub.calls("GET", "/artists/ar1/albums").first?.queryValues["include_groups"] == "album,single")
    }

    @Test func anAlbumOpensEvenWhenTheArtistsOtherAlbumsCannotBeRead() async throws {
        fixture.route("/albums/al1", SpotifyJSON.album("al1", "Album", tracks: SpotifyJSON.page([SpotifyJSON.bareTrack("t1")])))
        fixture.route("/artists/ar1/albums", forbidden, status: 403)
        let detail = try await provider.albumDetail(spotifyID("al1"))
        #expect(detail.tracks.count == 1)
        #expect(detail.moreByArtist.isEmpty)
    }

    @Test func anUnknownAlbumIsNotFound() async {
        let error = await providerError { _ = try await provider.albumDetail(spotifyID("nope")) }
        #expect(error == .notFound)
    }

    // MARK: Playlists

    @Test func aPlaylistReadsTheNewItemsEndpoint() async throws {
        fixture.route("/playlists/p1", SpotifyJSON.playlist("p1", "Mine"))
        fixture.route("/playlists/p1/items", SpotifyJSON.page([
            playlistItem(SpotifyJSON.track("t1", "One")),
            #"{"item":null}"#,
            playlistItem(localFile),
            playlistItem(episode),
            playlistItem(SpotifyJSON.track("t2", "Two")),
        ]))

        let detail = try await provider.playlistDetail(spotifyID("p1"))
        #expect(detail.playlist.name == "Mine")
        #expect(detail.tracks.map(\.title) == ["One", "Two"])
        #expect(stub.calls("GET", "/playlists/p1/tracks").isEmpty)
    }

    @Test func aPlaylistFallsBackToTheOlderTracksEndpoint() async throws {
        fixture.route("/playlists/p1", SpotifyJSON.playlist("p1", "Mine"))
        fixture.route("/playlists/p1/items", "{}", status: 404)
        fixture.route("/playlists/p1/tracks", SpotifyJSON.page([oldPlaylistTrack(SpotifyJSON.track("t1", "One"))]))

        let detail = try await provider.playlistDetail(spotifyID("p1"))
        #expect(detail.tracks.map(\.title) == ["One"])
        #expect(stub.calls("GET", "/playlists/p1/items").count == 1)
        #expect(stub.calls("GET", "/playlists/p1/tracks").count == 1)
    }

    @Test func aPlaylistNeitherEndpointKnowsIsNotFound() async {
        let error = await providerError { _ = try await provider.playlistDetail(spotifyID("gone")) }
        #expect(error == .notFound)
    }

    @Test func someoneElsesPlaylistIsExplained() async {
        fixture.route("/playlists/p1", SpotifyJSON.playlist("p1", "Theirs", owner: "someone"))
        fixture.route("/playlists/p1/items", forbidden, status: 403)
        let error = await providerError { _ = try await provider.playlistDetail(spotifyID("p1")) }
        #expect(error == .service("Spotify only lets Fiber open playlists you own or collaborate on."))
        #expect(stub.calls("GET", "/playlists/p1/tracks").isEmpty)
    }

    // MARK: Artists

    @Test func anArtistShowsOnlySongsTheyAreCreditedOn() async throws {
        fixture.route("/artists/ar1", SpotifyJSON.artist("ar1", "The Artist"))
        // A re-release has the same name and year as the original.
        fixture.route("/artists/ar1/albums", SpotifyJSON.page([
            SpotifyJSON.album("al1", "Debut", year: "2001-01-01"),
            SpotifyJSON.album("al2", "debut", year: "2001-06-01"),
            SpotifyJSON.album("al3", "Second", year: "2005-01-01"),
        ]))
        fixture.route("/search") { request in
            if request.queryValues["offset"] == "10" {
                return .json(searchReply(tracks: [SpotifyJSON.track("t4", "Deep Cut")]))
            }
            return .json(searchReply(tracks: [
                SpotifyJSON.track("t1", "Hit"),
                SpotifyJSON.track("t2", "Cover Version", artist: "ar9"),
                SpotifyJSON.track("t3", "HIT"),
            ]))
        }

        let detail = try await provider.artistDetail(spotifyID("ar1"))
        #expect(detail.artist.name == "The Artist")
        #expect(detail.topTracks.map(\.id.raw) == ["t1", "t4"])
        #expect(detail.albums.map(\.id.raw) == ["al1", "al3"])
        #expect(stub.calls("GET", "/search").allSatisfy { $0.queryValues["q"] == #"artist:"The Artist""# })
    }

    @Test func anUnknownArtistIsNotFound() async {
        let error = await providerError { _ = try await provider.artistDetail(spotifyID("nope")) }
        #expect(error == .notFound)
    }
}
