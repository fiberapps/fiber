import Foundation

/// A self-contained catalog for development and for trying the app without an
/// account. It is always labelled as a demo and never stands in for a real service.
final class DemoProvider: MusicProvider {
    let service = ServiceID.demo
    let connection = ConnectionState.notRequired
    let capabilities = ProviderCapabilities(
        browse: true, search: true, radio: true, playback: .inApp, seek: true, equalizer: true,
        backgroundAudio: true, syncedLyrics: true, libraryRead: false, libraryWrite: false,
        summary: "Invented songs, synthesized on this iPhone. For trying Fiber without an account.")

    let catalog = DemoCatalog()
    private let audio: FileAudioEngine

    init(audio: FileAudioEngine) {
        self.audio = audio
    }

    func makeEngine() throws -> any PlaybackEngine { audio }

    /// Renders the song on first play, then reuses the cached file.
    func audioURL(for track: Track) async throws -> URL {
        guard let song = catalog.songs[track.id] else { throw ProviderError.notFound }
        let trackID = track.id.raw
        return try await Task.detached(priority: .userInitiated) {
            try DemoSynth.renderIfNeeded(song, trackID: trackID)
        }.value
    }

    // MARK: Shelves

    private func entries(_ albums: [Album]) -> [ShelfEntry] { albums.map { ShelfEntry(.album($0)) } }

    func homeShelves() async throws -> [Shelf] {
        let albums = catalog.albums
        let mix = catalog.playlists[0]
        let picks: [ShelfEntry] = [
            ShelfEntry(.album(albums[0]), kicker: "New Release"),
            ShelfEntry(.playlist(mix), kicker: "Made for You"),
            ShelfEntry(.album(albums[3]), kicker: "Trending in K-Pop"),
            ShelfEntry(.album(albums[6]), kicker: "Because you played Glasshouse"),
            ShelfEntry(.album(albums[2]), kicker: "Novo em MPB"),
        ]
        return [
            Shelf(id: "home-picks", title: "Top Picks for You", layout: .heroCards, entries: picks),
            Shelf(id: "home-new", title: "New Releases for You", layout: .squares, entries: entries(albums.filter { $0.year == 2026 }), canExpand: true),
            Shelf(id: "home-made", title: "Made for You", layout: .squares, entries: catalog.playlists.map { ShelfEntry(.playlist($0)) }, canExpand: true),
            Shelf(id: "home-stations", title: "Stations for You", layout: .squares, entries: catalog.stations.map { ShelfEntry(.station($0)) }),
            Shelf(id: "home-more", title: "More to Explore", layout: .squares, entries: entries(albums.filter { ($0.year ?? 0) < 2025 }), canExpand: true),
        ]
    }

    func newShelves() async throws -> [Shelf] {
        let albums = catalog.albums
        let editorial: [ShelfEntry] = [
            ShelfEntry(.album(albums[1]), kicker: "The record we needed", headline: "Paper Tigers Club made the brightest pop album of 2026."),
            ShelfEntry(.album(albums[9]), kicker: "Barulho bom", headline: "Os Satélites voltam mais altos do que nunca."),
            ShelfEntry(.album(albums[10]), kicker: "On the floor", headline: "Lumi Park turns a greenhouse into a club."),
        ]
        let songs = Array(catalog.allTracks.filter { $0.trackNumber == 1 || $0.trackNumber == 2 }.prefix(16))
        return [
            Shelf(id: "new-editorial", title: nil, layout: .editorial, entries: editorial),
            Shelf(id: "new-best", title: "Best of 2026", layout: .squares, entries: catalog.playlists.dropFirst().map { ShelfEntry(.playlist($0)) }, canExpand: true),
            Shelf(id: "new-songs", title: "Best New Songs", layout: .songColumns, entries: songs.map { ShelfEntry(.track($0)) }, canExpand: true),
            Shelf(id: "new-releases", title: "New Releases", layout: .squares, entries: entries(albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }), canExpand: true),
        ]
    }

    func radioShelves() async throws -> [Shelf] {
        let stations = catalog.stations
        // On-air cards use wide show artwork rather than the square station tile.
        func show(_ station: Station, _ style: ArtStyle, _ title: String) -> MediaItem {
            var copy = station
            copy.artwork = .generated(seed: DemoCatalog.seed(title), style: style, label: title)
            return .station(copy)
        }
        let onAir: [ShelfEntry] = [
            ShelfEntry(show(stations[0], .rings, "THE DEMO\nCHART SHOW"), kicker: "Fiber One · Live", headline: "The Demo Chart Show", caption: "The most played songs in the demo catalog."),
            ShelfEntry(show(stations[5], .horizon, "SLOW\nWATER"), kicker: "Fiber Chill · Live", headline: "Slow Water", caption: "Ambient and quiet jazz, all evening."),
            ShelfEntry(show(stations[4], .bloom, "GREENHOUSE\nSESSIONS"), kicker: "Fiber Club · Live", headline: "Greenhouse Sessions", caption: "Dance music from the demo catalog."),
        ]
        return [
            Shelf(id: "radio-grid", title: nil, layout: .stationGrid, entries: stations.map { ShelfEntry(.station($0)) }),
            Shelf(id: "radio-onair", title: "On Air Now", layout: .onAir, entries: onAir),
            Shelf(id: "radio-playlists", title: "Hear It Again", layout: .squares, entries: catalog.playlists.map { ShelfEntry(.playlist($0)) }),
        ]
    }

    func browseCategories() async throws -> [BrowseCategory] { catalog.categories }

    func categoryShelves(_ id: MediaID) async throws -> [Shelf] {
        guard let category = catalog.categories.first(where: { $0.id == id }) else { throw ProviderError.notFound }
        let albums = catalog.albums.filter { $0.genre == category.name }
        let songs = albums.flatMap { catalog.tracksByAlbum[$0.id] ?? [] }
        return [
            Shelf(id: "category-albums", title: "Albums", layout: .squares, entries: entries(albums)),
            Shelf(id: "category-songs", title: "Songs", layout: .songColumns, entries: songs.map { ShelfEntry(.track($0)) }),
        ]
    }

    func search(_ term: String) async throws -> SearchResults {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return SearchResults() }
        func matches(_ text: String?) -> Bool { text?.localizedStandardContains(needle) ?? false }
        return SearchResults(
            tracks: catalog.allTracks.filter { matches($0.title) || matches($0.artistName) },
            albums: catalog.albums.filter { matches($0.title) || matches($0.artistName) || matches($0.genre) },
            artists: catalog.artists.filter { matches($0.name) },
            playlists: catalog.playlists.filter { matches($0.name) })
    }

    // MARK: Details

    func albumDetail(_ id: MediaID) async throws -> AlbumDetail {
        guard let album = catalog.albums.first(where: { $0.id == id }) else { throw ProviderError.notFound }
        return AlbumDetail(album: album, tracks: catalog.tracksByAlbum[id] ?? [],
                           moreByArtist: catalog.albums.filter { $0.artistID == album.artistID && $0.id != id })
    }

    func playlistDetail(_ id: MediaID) async throws -> PlaylistDetail {
        guard let playlist = catalog.playlists.first(where: { $0.id == id }) else { throw ProviderError.notFound }
        return PlaylistDetail(playlist: playlist, tracks: catalog.playlistTracks[id] ?? [])
    }

    func artistDetail(_ id: MediaID) async throws -> ArtistDetail {
        guard let artist = catalog.artists.first(where: { $0.id == id }) else { throw ProviderError.notFound }
        let albums = catalog.albums.filter { $0.artistID == id }
        return ArtistDetail(artist: artist, topTracks: albums.flatMap { catalog.tracksByAlbum[$0.id] ?? [] }, albums: albums)
    }

    func stationTracks(_ id: MediaID) async throws -> [Track] {
        guard catalog.stations.contains(where: { $0.id == id }) else { throw ProviderError.notFound }
        return catalog.tracks(forStation: id)
    }

    func lyrics(for track: Track) async throws -> Lyrics? {
        guard let sheet = catalog.lyricSheets[track.id], let song = catalog.songs[track.id] else { return nil }
        return sheet.lyrics(for: song)
    }
}
