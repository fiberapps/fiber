import Foundation
import Observation

/// Spotify through its Web API: sign-in, your library, search, your top music
/// and playback inside Fiber through Spotify's Web Playback SDK.
///
/// Written against Spotify's 2026 developer-mode rules: no recommendations,
/// radio, browse categories, top tracks per artist or per-user profile data,
/// song lists only for playlists the user owns or collaborates on, and search
/// pages of at most 10.
///
/// This object only exists while the Spotify switch is on in Settings.
@Observable
final class SpotifyProvider: MusicProvider {
    let service = ServiceID.spotify
    private(set) var connection = ConnectionState.disconnected

    let capabilities = ProviderCapabilities(
        browse: true, search: true, radio: false, playback: .inApp, seek: true, equalizer: false,
        backgroundAudio: true, syncedLyrics: false, libraryRead: true, libraryWrite: false,
        summary: "Your Spotify library, search and top music. Songs play inside Fiber through Spotify's player. Premium is required, and the first play asks you to enable audio. Reconnect once so Fiber can request Streaming permission. Spotify only shares playlists you own or collaborate on, and gives apps no radio or equalizer; Fiber adds synced lyrics itself.")

    private let session: SpotifySession?
    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var engine: SpotifyWebEngine?

    init(session: SpotifySession? = SpotifyConfig.load().map { SpotifySession(config: $0) }) {
        self.session = session
        if session == nil {
            connection = .unavailable("This build of Fiber has no Spotify app registration. Add SPOTIFY_CLIENT_ID to .env and rebuild.")
        }
    }

    // MARK: Connection

    /// Picks up an earlier sign-in without showing anything.
    func restore() async {
        guard let session, session.hasSavedSignIn else { return }
        connection = .connecting
        await loadAccount(session)
    }

    func connect() async {
        guard let session else { return }
        connection = .connecting
        do {
            try await session.signIn()
            await loadAccount(session)
        } catch is CancellationError {
            connection = .disconnected
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        engine?.disconnect()
        session?.signOut()
        userID = nil
        if session != nil { connection = .disconnected }
    }

    private func loadAccount(_ session: SpotifySession) async {
        do {
            let profile: SpotifyProfile = try await session.get("/me")
            userID = profile.id
            connection = .connected(account: profile.displayName ?? profile.id)
        } catch is CancellationError {
            connection = .disconnected
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func makeEngine() throws -> any PlaybackEngine {
        let api = try api()
        if let engine { return engine }
        let created = SpotifyWebEngine.shared
        created.configure(session: api)
        engine = created
        return created
    }

    private func api() throws -> SpotifySession {
        guard let session, connection.isUsable else { throw ProviderError.notConnected(.spotify) }
        return session
    }

    private func wrap(_ error: Error) -> Error {
        switch error {
        case is CancellationError:
            return error
        case ProviderError.permissionDenied:
            return ProviderError.service("Spotify refused this request. If it keeps happening, disconnect Spotify in Settings and connect again.")
        case is ProviderError:
            return error
        default:
            return ProviderError.network(error.localizedDescription)
        }
    }

    // MARK: Paging

    private static func page<Element: Decodable & Sendable>(
        _ api: SpotifySession, _ path: String, _ query: [String: String] = [:], as type: Element.Type = Element.self
    ) async throws -> [Element] {
        let page: SpotifyPage<Element> = try await api.get(path, query: query)
        return page.items
    }

    /// Reads a whole list. Once the first page says how long it is, the rest
    /// are fetched a few at a time, because a big library is many pages.
    static func fetchAll<Element: Decodable & Sendable>(
        _ api: SpotifySession, _ path: String, query: [String: String] = [:], limit: Int = 50, maxItems: Int,
        as type: Element.Type = Element.self
    ) async throws -> [Element] {
        var firstQuery = query
        firstQuery["limit"] = String(limit)
        let first: SpotifyPage<Element> = try await api.get(path, query: firstQuery)
        var items = first.items
        guard first.next != nil, items.count < maxItems else { return Array(items.prefix(maxItems)) }

        if let total = first.total {
            let offsets = Array(stride(from: limit, to: min(total, maxItems), by: limit))
            for start in stride(from: 0, to: offsets.count, by: 4) {
                let batch = Array(offsets[start..<min(start + 4, offsets.count)])
                let pages = try await withThrowingTaskGroup(of: (Int, [Element]).self) { group in
                    for offset in batch {
                        group.addTask {
                            var pageQuery = query
                            pageQuery["limit"] = String(limit)
                            pageQuery["offset"] = String(offset)
                            let page: SpotifyPage<Element> = try await api.get(path, query: pageQuery)
                            return (offset, page.items)
                        }
                    }
                    var collected: [(Int, [Element])] = []
                    for try await page in group { collected.append(page) }
                    return collected.sorted { $0.0 < $1.0 }
                }
                for (_, page) in pages { items += page }
            }
        } else {
            var next = first.next
            while let url = next, items.count < maxItems {
                let page: SpotifyPage<Element> = try await api.get(url)
                items += page.items
                next = page.next
            }
        }
        return Array(items.prefix(maxItems))
    }

    private static func attempt<Value: Sendable>(_ work: () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    // MARK: Library

    func library() async throws -> RemoteLibrary {
        let api = try api()
        do {
            async let albums = Self.fetchAll(api, "/me/albums", maxItems: 500, as: SpotifySavedAlbum.self)
            async let songs = Self.fetchAll(api, "/me/tracks", maxItems: 1000, as: SpotifySavedTrack.self)
            async let playlists = Self.fetchAll(api, "/me/playlists", maxItems: 300, as: SpotifyPlaylistDTO.self)
            let found = try await (albums: albums, songs: songs, playlists: playlists)
            let userID = self.userID
            return RemoteLibrary(
                albums: found.albums.compactMap { SpotifyMapping.album($0.album) },
                playlists: found.playlists.filter { SpotifyMapping.isReadable($0, userID: userID) }.compactMap(SpotifyMapping.playlist),
                songs: found.songs.compactMap { SpotifyMapping.track($0.track) })
        } catch {
            throw wrap(error)
        }
    }

    // MARK: Browsing

    func homeShelves() async throws -> [Shelf] {
        let api = try api()
        async let recentResult = Self.attempt { try await Self.page(api, "/me/player/recently-played", ["limit": "50"], as: SpotifyPlayHistory.self) }
        async let playlistResult = Self.attempt { try await Self.fetchAll(api, "/me/playlists", maxItems: 100, as: SpotifyPlaylistDTO.self) }
        async let albumResult = Self.attempt { try await Self.page(api, "/me/albums", ["limit": "20"], as: SpotifySavedAlbum.self) }
        async let artistResult = Self.attempt { try await Self.page(api, "/me/top/artists", ["limit": "20", "time_range": "medium_term"], as: SpotifyArtistDTO.self) }
        async let songResult = Self.attempt { try await Self.page(api, "/me/top/tracks", ["limit": "20", "time_range": "medium_term"], as: SpotifyTrackDTO.self) }
        let results = await (recentResult, playlistResult, albumResult, artistResult, songResult)

        var firstError: Error?
        func values<Element>(_ result: Result<[Element], Error>) -> [Element] {
            switch result {
            case .success(let items):
                return items
            case .failure(let error):
                if firstError == nil { firstError = error }
                return []
            }
        }

        let userID = self.userID
        var seenAlbums = Set<String>()
        let recentAlbums = values(results.0).compactMap(\.song).compactMap { $0.album.flatMap(SpotifyMapping.album) }
            .filter { seenAlbums.insert($0.id.raw).inserted }
        let playlists = values(results.1).filter { SpotifyMapping.isReadable($0, userID: userID) }.compactMap(SpotifyMapping.playlist)
        let savedAlbums = values(results.2).compactMap { SpotifyMapping.album($0.album) }
        let topArtists = values(results.3).compactMap(SpotifyMapping.artist)
        let topSongs = values(results.4).compactMap { SpotifyMapping.track($0) }

        var shelves: [Shelf] = []
        if !recentAlbums.isEmpty {
            shelves.append(Shelf(id: "sp-home-recent", title: "Jump Back In", layout: .heroCards,
                                 entries: recentAlbums.prefix(10).map { ShelfEntry(.album($0), kicker: "Recently Played") }))
        }
        if !playlists.isEmpty {
            shelves.append(Shelf(id: "sp-home-playlists", title: "Your Playlists", layout: .squares,
                                 entries: playlists.prefix(20).map { ShelfEntry(.playlist($0)) }, canExpand: true))
        }
        if !savedAlbums.isEmpty {
            shelves.append(Shelf(id: "sp-home-albums", title: "Saved Albums", layout: .squares,
                                 entries: savedAlbums.map { ShelfEntry(.album($0)) }, canExpand: true))
        }
        if !topSongs.isEmpty {
            shelves.append(Shelf(id: "sp-home-songs", title: "Your Top Songs", layout: .songColumns,
                                 entries: topSongs.map { ShelfEntry(.track($0)) }, canExpand: true))
        }
        if !topArtists.isEmpty {
            shelves.append(Shelf(id: "sp-home-artists", title: "Your Top Artists", layout: .squares,
                                 entries: topArtists.map { ShelfEntry(.artist($0)) }, canExpand: true))
        }
        if shelves.isEmpty {
            if let firstError { throw wrap(firstError) }
            // A brand-new account has no history yet; new releases still make a useful Home.
            return try await newShelves()
        }
        return shelves
    }

    func newShelves() async throws -> [Shelf] {
        let api = try api()
        do {
            // Search pages are capped at 10, so three pages make a useful shelf.
            async let first: SpotifySearchReply = api.get("/search", query: ["q": "tag:new", "type": "album", "limit": "10"])
            async let second: SpotifySearchReply? = try? await api.get("/search", query: ["q": "tag:new", "type": "album", "limit": "10", "offset": "10"])
            async let third: SpotifySearchReply? = try? await api.get("/search", query: ["q": "tag:new", "type": "album", "limit": "10", "offset": "20"])
            let replies = [try await first] + [await second, await third].compactMap { $0 }

            var seen = Set<String>()
            let found = replies.flatMap { $0.albums?.items ?? [] }.compactMap { dto -> (Album, String?)? in
                guard let album = SpotifyMapping.album(dto), seen.insert(album.id.raw).inserted else { return nil }
                return (album, dto.albumType)
            }
            guard !found.isEmpty else { return [] }

            var shelves = [Shelf(id: "sp-new-feature", title: nil, layout: .editorial, entries: found.prefix(6).map { album, type in
                ShelfEntry(.album(album), kicker: type == "single" ? "New Single" : "New Release", headline: album.title)
            })]
            if found.count > 6 {
                shelves.append(Shelf(id: "sp-new-albums", title: "New Releases", layout: .squares,
                                     entries: found.dropFirst(6).map { ShelfEntry(.album($0.0)) }, canExpand: true))
            }
            return shelves
        } catch {
            throw wrap(error)
        }
    }

    func search(_ term: String) async throws -> SearchResults {
        let api = try api()
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return SearchResults() }
        do {
            async let main: SpotifySearchReply = api.get("/search", query: ["q": text, "type": "track,album,artist,playlist", "limit": "10"])
            // A second page of songs, since songs are what people search for most.
            async let moreSongs: SpotifySearchReply? = try? await api.get("/search", query: ["q": text, "type": "track", "limit": "10", "offset": "10"])
            let reply = try await main
            let extra = await moreSongs

            let userID = self.userID
            var seenTracks = Set<String>()
            let tracks = ((reply.tracks?.items ?? []) + (extra?.tracks?.items ?? [])).compactMap { SpotifyMapping.track($0) }
                .filter { seenTracks.insert($0.id.raw).inserted }
            return SearchResults(
                tracks: tracks,
                albums: (reply.albums?.items ?? []).compactMap(SpotifyMapping.album),
                artists: (reply.artists?.items ?? []).compactMap(SpotifyMapping.artist),
                // Songs of other people's playlists can't be read, so only the openable ones are offered.
                playlists: (reply.playlists?.items ?? []).filter { SpotifyMapping.isReadable($0, userID: userID) }.compactMap(SpotifyMapping.playlist))
        } catch {
            throw wrap(error)
        }
    }

    // MARK: Details

    func albumDetail(_ id: MediaID) async throws -> AlbumDetail {
        let api = try api()
        do {
            let dto: SpotifyAlbumDTO = try await api.get("/albums/\(id.raw)", query: ["market": "from_token"])
            guard let album = SpotifyMapping.album(dto) else { throw ProviderError.notFound }

            var songs = dto.tracks?.items ?? []
            var next = dto.tracks?.next
            while let url = next, songs.count < 500 {
                let more: SpotifyPage<SpotifyTrackDTO> = try await api.get(url)
                songs += more.items
                next = more.next
            }

            var others: [Album] = []
            if let artistID = album.artistID {
                let reply: SpotifyPage<SpotifyAlbumDTO>? = try? await api.get(
                    "/artists/\(artistID.raw)/albums", query: ["include_groups": "album,single", "limit": "20"])
                others = Array((reply?.items ?? []).compactMap(SpotifyMapping.album).filter { $0.id != album.id }.prefix(10))
            }
            return AlbumDetail(album: album, tracks: songs.compactMap { SpotifyMapping.track($0, in: album) }, moreByArtist: others)
        } catch {
            throw wrap(error)
        }
    }

    func playlistDetail(_ id: MediaID) async throws -> PlaylistDetail {
        let api = try api()
        do {
            async let meta: SpotifyPlaylistDTO = api.get(
                "/playlists/\(id.raw)", query: ["fields": "id,name,description,images,owner,collaborative"])
            let entries = try await playlistEntries(api, id.raw)
            guard let playlist = SpotifyMapping.playlist(try await meta) else { throw ProviderError.notFound }
            return PlaylistDetail(playlist: playlist, tracks: entries.compactMap(\.song).compactMap { SpotifyMapping.track($0) })
        } catch ProviderError.permissionDenied {
            throw ProviderError.service("Spotify only lets Fiber open playlists you own or collaborate on.")
        } catch {
            throw wrap(error)
        }
    }

    /// Spotify renamed the playlist songs endpoint from `/tracks` to `/items`; ask for the new one first.
    private func playlistEntries(_ api: SpotifySession, _ id: String) async throws -> [SpotifyPlaylistEntry] {
        do {
            return try await Self.fetchAll(api, "/playlists/\(id)/items", maxItems: 1000, as: SpotifyPlaylistEntry.self)
        } catch ProviderError.notFound {
            return try await Self.fetchAll(api, "/playlists/\(id)/tracks", maxItems: 1000, as: SpotifyPlaylistEntry.self)
        }
    }

    func artistDetail(_ id: MediaID) async throws -> ArtistDetail {
        let api = try api()
        do {
            async let profile: SpotifyArtistDTO = api.get("/artists/\(id.raw)")
            async let albumPage: SpotifyPage<SpotifyAlbumDTO>? = try? await api.get(
                "/artists/\(id.raw)/albums", query: ["include_groups": "album,single", "limit": "50"])
            let dto = try await profile
            guard let artist = SpotifyMapping.artist(dto) else { throw ProviderError.notFound }
            let songs = await topSongs(api, artistID: id.raw, name: dto.name)

            // Re-releases show up as separate albums with the same name.
            var seen = Set<String>()
            let albums = (await albumPage)?.items.compactMap(SpotifyMapping.album)
                .filter { seen.insert($0.title.lowercased() + "|" + String($0.year ?? 0)).inserted } ?? []
            return ArtistDetail(artist: artist, topTracks: songs, albums: albums)
        } catch {
            throw wrap(error)
        }
    }

    /// Spotify no longer offers an artist's top tracks, so this is the best
    /// matches of a search for the artist, kept to songs they are credited on.
    private func topSongs(_ api: SpotifySession, artistID: String, name: String) async -> [Track] {
        let query = "artist:\"\(name.replacingOccurrences(of: "\"", with: ""))\""
        async let first: SpotifySearchReply? = try? await api.get("/search", query: ["q": query, "type": "track", "limit": "10"])
        async let second: SpotifySearchReply? = try? await api.get("/search", query: ["q": query, "type": "track", "limit": "10", "offset": "10"])
        var seen = Set<String>()
        return [await first, await second].compactMap { $0 }
            .flatMap { $0.tracks?.items ?? [] }
            .filter { $0.artists?.contains { $0.id == artistID } == true }
            .compactMap { SpotifyMapping.track($0) }
            .filter { seen.insert($0.title.lowercased()).inserted }
    }
}
