import Foundation
@preconcurrency import MusicKit
import Observation

// MusicKit has its own Album, Song, Playlist… so Fiber's models are spelled out here.
private typealias AppTrack = Fiber.Track
private typealias AppAlbum = Fiber.Album
private typealias AppArtist = Fiber.Artist
private typealias AppPlaylist = Fiber.Playlist
private typealias AppStation = Fiber.Station
private typealias AppArtwork = Fiber.Artwork

/// Apple Music through Apple's MusicKit framework: catalog, recommendations,
/// charts, search and playback by the system music player.
///
/// This object only exists while the Apple Music switch is on in Settings, so
/// nothing here runs, and no permission is requested, when it is off.
@Observable
final class AppleMusicProvider: MusicProvider {
    let service = ServiceID.appleMusic
    private(set) var connection = ConnectionState.disconnected

    let capabilities = ProviderCapabilities(
        browse: true, search: true, radio: true, playback: .systemPlayer, seek: true, equalizer: false,
        backgroundAudio: true, syncedLyrics: false, libraryRead: true, libraryWrite: false,
        summary: "Your Apple Music library, the catalog, recommendations, charts, radio and playback through the system music player. Playing needs an Apple Music subscription. Apple does not give other apps its lyrics, and the equalizer can't process its audio.")

    @ObservationIgnored private lazy var engine = AppleMusicEngine()

    init() {
        if Bundle.main.url(forResource: "AppleMusicToken", withExtension: "json") != nil {
            MusicDataRequest.tokenProvider = FiberMusicTokenProvider()
        }
    }

    static func stationTrackID(_ station: MediaID) -> MediaID { MediaID(service: .appleMusic, raw: "station:" + station.raw) }

    /// Picks up an earlier approval without showing a prompt.
    func restore() async {
        guard MusicAuthorization.currentStatus == .authorized else { return }
        connection = .connecting
        await refreshSubscription()
    }

    func connect() async {
        connection = .connecting
        switch await MusicAuthorization.request() {
        case .authorized:
            await refreshSubscription()
        case .denied:
            connection = .failed("Access was denied. Allow Media & Apple Music for Fiber in the Settings app.")
        case .restricted:
            connection = .failed("Apple Music is restricted on this iPhone.")
        case .notDetermined:
            connection = .disconnected
        @unknown default:
            connection = .failed("Apple Music returned an unknown authorization state.")
        }
    }

    private func refreshSubscription() async {
        do {
            let subscription = try await MusicSubscription.current
            connection = subscription.canPlayCatalogContent
                ? .connected(account: nil)
                : .limited("Connected, but this Apple Account has no Apple Music subscription, so songs can't be played.")
        } catch {
            connection = .failed("Couldn't check the Apple Music subscription (\(error.localizedDescription)).")
        }
    }

    /// iOS has no API to revoke the permission, so this stops playback and
    /// stops using the service. The permission itself is changed in the Settings app.
    func disconnect() async {
        engine.stop()
        connection = .disconnected
    }

    func makeEngine() throws -> any PlaybackEngine {
        guard connection.isUsable else { throw ProviderError.notConnected(.appleMusic) }
        if case .limited = connection { throw ProviderError.subscriptionRequired }
        return engine
    }

    private func requireConnection() throws {
        guard connection.isUsable else { throw ProviderError.notConnected(.appleMusic) }
    }

    // MARK: Mapping

    private func id(_ item: MusicItemID) -> MediaID { MediaID(service: .appleMusic, raw: item.rawValue) }

    private func art(_ artwork: MusicKit.Artwork?) -> AppArtwork {
        guard let url = artwork?.url(width: 700, height: 700) else { return .none }
        return .remote(template: url.absoluteString)
    }

    private func track(_ song: Song) -> AppTrack {
        AppTrack(id: id(song.id), title: song.title, artistName: song.artistName, albumTitle: song.albumTitle,
                 albumID: nil, artistID: nil, duration: song.duration ?? 0, trackNumber: song.trackNumber,
                 isExplicit: song.contentRating == .explicit, artwork: art(song.artwork))
    }

    private func album(_ album: MusicKit.Album) -> AppAlbum {
        let badges = (album.audioVariants ?? []).compactMap { variant -> String? in
            switch variant {
            case .dolbyAtmos: "Dolby Atmos"
            case .lossless: "Lossless"
            case .highResolutionLossless: "Hi-Res Lossless"
            default: nil
            }
        }
        return AppAlbum(
            id: id(album.id), title: album.title, artistName: album.artistName, artistID: nil, artwork: art(album.artwork),
            year: album.releaseDate.map { Calendar.current.component(.year, from: $0) }, genre: album.genreNames.first,
            isExplicit: album.contentRating == .explicit, formatBadges: badges,
            notes: album.editorialNotes?.standard ?? album.editorialNotes?.short, shareURL: album.url)
    }

    private func playlist(_ playlist: MusicKit.Playlist) -> AppPlaylist {
        AppPlaylist(id: id(playlist.id), name: playlist.name, curator: playlist.curatorName, artwork: art(playlist.artwork),
                    notes: playlist.standardDescription ?? playlist.shortDescription, isEditable: false)
    }

    private func artist(_ artist: MusicKit.Artist) -> AppArtist {
        AppArtist(id: id(artist.id), name: artist.name, artwork: art(artist.artwork), genre: nil)
    }

    private func station(_ station: MusicKit.Station) -> AppStation {
        AppStation(id: id(station.id), name: station.name, tagline: station.editorialNotes?.short, artwork: art(station.artwork))
    }

    private func wrap(_ error: Error) -> Error {
        if error is ProviderError { return error }
        return ProviderError.network(error.localizedDescription)
    }

    // MARK: Library

    /// Items from the user's library carry this prefix, because library IDs
    /// are different from catalog IDs and must be looked up in the library.
    static let libraryPrefix = "lib:"

    private func libraryID(_ item: MusicItemID) -> MediaID {
        MediaID(service: .appleMusic, raw: Self.libraryPrefix + item.rawValue)
    }

    private func libraryTrack(_ song: Song) -> AppTrack {
        var mapped = track(song)
        mapped.id = libraryID(song.id)
        return mapped
    }

    func library() async throws -> RemoteLibrary {
        try requireConnection()
        do {
            var albumRequest = MusicLibraryRequest<MusicKit.Album>()
            var playlistRequest = MusicLibraryRequest<MusicKit.Playlist>()
            var songRequest = MusicLibraryRequest<Song>()
            #if !targetEnvironment(macCatalyst)
            albumRequest.sort(by: \.libraryAddedDate, ascending: false)
            playlistRequest.sort(by: \.libraryAddedDate, ascending: false)
            songRequest.sort(by: \.libraryAddedDate, ascending: false)
            songRequest.limit = 3000
            #endif
            // Catalyst's MediaPlayer backend crashes converting sort descriptors.
            // Fetch without descriptors there and order the returned values ourselves.
            let albumItems = try await albumRequest.response().items.sorted {
                ($0.libraryAddedDate ?? .distantPast) > ($1.libraryAddedDate ?? .distantPast)
            }
            let playlistItems = try await playlistRequest.response().items.sorted {
                ($0.libraryAddedDate ?? .distantPast) > ($1.libraryAddedDate ?? .distantPast)
            }
            let songItems = try await songRequest.response().items.sorted {
                ($0.libraryAddedDate ?? .distantPast) > ($1.libraryAddedDate ?? .distantPast)
            }

            let albums = albumItems.map { item -> AppAlbum in
                var mapped = album(item)
                mapped.id = libraryID(item.id)
                mapped.shareURL = nil
                return mapped
            }
            let playlists = playlistItems.map { item -> AppPlaylist in
                var mapped = playlist(item)
                mapped.id = libraryID(item.id)
                return mapped
            }
            let songs = songItems.prefix(3000).map(libraryTrack)
            return RemoteLibrary(albums: albums, playlists: playlists, songs: songs)
        } catch {
            throw wrap(error)
        }
    }

    private func libraryAlbumDetail(_ albumID: MediaID) async throws -> AlbumDetail {
        var request = MusicLibraryRequest<MusicKit.Album>()
        request.filter(matching: \.id, equalTo: MusicItemID(String(albumID.raw.dropFirst(Self.libraryPrefix.count))))
        guard let found = try await request.response().items.first else { throw ProviderError.notFound }
        let full = try await found.with([.tracks], preferredSource: .library)
        var mapped = album(full)
        mapped.id = albumID
        mapped.shareURL = nil
        let tracks = (full.tracks ?? []).compactMap { item -> AppTrack? in
            guard case .song(let song) = item else { return nil }
            var copy = libraryTrack(song)
            copy.albumID = albumID
            if case .none = copy.artwork { copy.artwork = mapped.artwork }
            return copy
        }
        return AlbumDetail(album: mapped, tracks: tracks)
    }

    private func libraryPlaylistDetail(_ playlistID: MediaID) async throws -> PlaylistDetail {
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(String(playlistID.raw.dropFirst(Self.libraryPrefix.count))))
        guard let found = try await request.response().items.first else { throw ProviderError.notFound }
        let full = try await found.with([.tracks], preferredSource: .library)
        var mapped = playlist(full)
        mapped.id = playlistID
        let tracks = (full.tracks ?? []).compactMap { item -> AppTrack? in
            guard case .song(let song) = item else { return nil }
            return libraryTrack(song)
        }
        return PlaylistDetail(playlist: mapped, tracks: tracks)
    }

    // MARK: Browsing

    func homeShelves() async throws -> [Shelf] {
        try requireConnection()
        do {
            let response = try await MusicPersonalRecommendationsRequest().response()
            let shelves = response.recommendations.enumerated().compactMap { index, recommendation -> Shelf? in
                let entries = recommendation.albums.map { ShelfEntry(.album(album($0)), kicker: recommendation.reason) }
                    + recommendation.playlists.map { ShelfEntry(.playlist(playlist($0)), kicker: recommendation.reason) }
                    + recommendation.stations.map { ShelfEntry(.station(station($0)), kicker: recommendation.reason) }
                guard !entries.isEmpty else { return nil }
                return Shelf(id: "am-home-\(recommendation.id.rawValue)", title: recommendation.title ?? "For You",
                             layout: index == 0 ? .heroCards : .squares, entries: entries, canExpand: index != 0)
            }
            if !shelves.isEmpty { return shelves }
        } catch {
            // Recommendations need a subscription; without one the charts still make a useful Home.
            if case .connected = connection { throw wrap(error) }
        }
        return try await newShelves()
    }

    func newShelves() async throws -> [Shelf] {
        try requireConnection()
        do {
            return try await chartShelves(genre: nil, prefix: "am-new")
        } catch {
            throw wrap(error)
        }
    }

    private func chartShelves(genre: Genre?, prefix: String) async throws -> [Shelf] {
        var request = MusicCatalogChartsRequest(genre: genre, kinds: [.mostPlayed], types: [Song.self, MusicKit.Album.self, MusicKit.Playlist.self])
        request.limit = 24
        let response = try await request.response()
        var shelves: [Shelf] = []
        for chart in response.albumCharts where !chart.items.isEmpty {
            shelves.append(Shelf(id: "\(prefix)-albums-\(chart.id)", title: chart.title, layout: .squares,
                                 entries: chart.items.map { ShelfEntry(.album(album($0))) }, canExpand: true))
        }
        for chart in response.songCharts where !chart.items.isEmpty {
            shelves.append(Shelf(id: "\(prefix)-songs-\(chart.id)", title: chart.title, layout: .songColumns,
                                 entries: chart.items.map { ShelfEntry(.track(track($0))) }, canExpand: true))
        }
        for chart in response.playlistCharts where !chart.items.isEmpty {
            shelves.append(Shelf(id: "\(prefix)-playlists-\(chart.id)", title: chart.title, layout: .squares,
                                 entries: chart.items.map { ShelfEntry(.playlist(playlist($0))) }, canExpand: true))
        }
        return shelves
    }

    private func catalogCollection<Item: MusicItem & Decodable>(_ path: String, as type: Item.Type) async throws -> [Item] {
        let storefront = try await MusicDataRequest.currentCountryCode
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/\(path)") else { throw ProviderError.notFound }
        let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        return Array(try JSONDecoder().decode(MusicItemCollection<Item>.self, from: response.data))
    }

    func radioShelves() async throws -> [Shelf] {
        try requireConnection()
        do {
            let live = try await catalogCollection("stations?filter[featured]=apple-music-live-radio", as: MusicKit.Station.self)
            var shelves = [Shelf(id: "am-radio-live", title: nil, layout: .stationGrid, entries: live.map { ShelfEntry(.station(station($0))) })]
            var search = MusicCatalogSearchRequest(term: "radio", types: [MusicKit.Station.self])
            search.limit = 20
            let more = try await search.response().stations.filter { found in !live.contains { $0.id == found.id } }
            if !more.isEmpty {
                shelves.append(Shelf(id: "am-radio-more", title: "More Stations", layout: .squares, entries: more.map { ShelfEntry(.station(station($0))) }))
            }
            return shelves
        } catch {
            throw wrap(error)
        }
    }

    func browseCategories() async throws -> [BrowseCategory] {
        try requireConnection()
        let styles: [ArtStyle] = [.bloom, .horizon, .rings, .stripes, .chevrons, .halftone]
        let genres = try await catalogCollection("genres", as: Genre.self)
        return genres.enumerated().map { index, genre in
            BrowseCategory(id: id(genre.id), name: genre.name,
                           artwork: .generated(seed: DemoCatalog.seed(genre.name), style: styles[index % styles.count], label: nil))
        }
    }

    func categoryShelves(_ category: MediaID) async throws -> [Shelf] {
        try requireConnection()
        do {
            let request = MusicCatalogResourceRequest<Genre>(matching: \.id, equalTo: MusicItemID(category.raw))
            guard let genre = try await request.response().items.first else { throw ProviderError.notFound }
            return try await chartShelves(genre: genre, prefix: "am-genre-\(category.raw)")
        } catch {
            throw wrap(error)
        }
    }

    func search(_ term: String) async throws -> SearchResults {
        try requireConnection()
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self, MusicKit.Album.self, MusicKit.Artist.self, MusicKit.Playlist.self])
            request.limit = 20
            let response = try await request.response()
            return SearchResults(tracks: response.songs.map(track), albums: response.albums.map(album),
                                 artists: response.artists.map(artist), playlists: response.playlists.map(playlist))
        } catch {
            throw wrap(error)
        }
    }

    // MARK: Details

    private func songs(in tracks: MusicItemCollection<MusicKit.Track>?) -> [AppTrack] {
        (tracks ?? []).compactMap { if case .song(let song) = $0 { track(song) } else { nil } }
    }

    func albumDetail(_ albumID: MediaID) async throws -> AlbumDetail {
        try requireConnection()
        do {
            if albumID.raw.hasPrefix(Self.libraryPrefix) { return try await libraryAlbumDetail(albumID) }
            var request = MusicCatalogResourceRequest<MusicKit.Album>(matching: \.id, equalTo: MusicItemID(albumID.raw))
            request.properties = [.tracks]
            guard let found = try await request.response().items.first else { throw ProviderError.notFound }
            let mapped = album(found)
            let tracks = songs(in: found.tracks).map { song -> AppTrack in
                var copy = song
                copy.albumID = albumID
                if case .none = copy.artwork { copy.artwork = mapped.artwork }
                return copy
            }
            return AlbumDetail(album: mapped, tracks: tracks)
        } catch {
            throw wrap(error)
        }
    }

    func playlistDetail(_ playlistID: MediaID) async throws -> PlaylistDetail {
        try requireConnection()
        do {
            if playlistID.raw.hasPrefix(Self.libraryPrefix) { return try await libraryPlaylistDetail(playlistID) }
            var request = MusicCatalogResourceRequest<MusicKit.Playlist>(matching: \.id, equalTo: MusicItemID(playlistID.raw))
            request.properties = [.tracks]
            guard let found = try await request.response().items.first else { throw ProviderError.notFound }
            return PlaylistDetail(playlist: playlist(found), tracks: songs(in: found.tracks))
        } catch {
            throw wrap(error)
        }
    }

    func artistDetail(_ artistID: MediaID) async throws -> ArtistDetail {
        try requireConnection()
        do {
            var request = MusicCatalogResourceRequest<MusicKit.Artist>(matching: \.id, equalTo: MusicItemID(artistID.raw))
            request.properties = [.topSongs, .albums]
            guard let found = try await request.response().items.first else { throw ProviderError.notFound }
            return ArtistDetail(artist: artist(found), topTracks: (found.topSongs ?? []).map(track), albums: (found.albums ?? []).map(album))
        } catch {
            throw wrap(error)
        }
    }

    /// A station is a live stream, not a list of songs, so it is queued as a
    /// single item that the system player expands itself.
    func stationTracks(_ stationID: MediaID) async throws -> [Fiber.Track] {
        try requireConnection()
        let request = MusicCatalogResourceRequest<MusicKit.Station>(matching: \.id, equalTo: MusicItemID(stationID.raw))
        guard let found = try await request.response().items.first else { throw ProviderError.notFound }
        return [AppTrack(id: Self.stationTrackID(stationID), title: found.name, artistName: "Apple Music Radio",
                         duration: 0, artwork: art(found.artwork))]
    }
}

/// Controls Apple's Music app through the official system player. Music owns
/// the audio, shared queue, Lock Screen metadata and available catalog artwork.
/// Motion presentation remains controlled by iOS and the album's availability.
final class AppleMusicEngine: PlaybackEngine {
    let mode = PlaybackMode.systemPlayer
    var onFinish: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?

    #if targetEnvironment(macCatalyst)
    // Independent playback on Mac; SystemMusicPlayer controls/opens Music.app.
    private let player = ApplicationMusicPlayer.shared
    #else
    private let player = SystemMusicPlayer.shared
    #endif
    private var watcher: Task<Void, Never>?
    private var duration: TimeInterval = 0
    private var request = 0

    private var lastReported: TimeInterval = -1
    private var lastReportedAt = ProcessInfo.processInfo.systemUptime

    /// The system player can report its position in steps. While it is playing,
    /// time between two reports is filled in from the clock so lyrics move smoothly.
    var currentTime: TimeInterval {
        let reported = player.playbackTime
        let now = ProcessInfo.processInfo.systemUptime
        if reported != lastReported || player.state.playbackStatus != .playing {
            lastReported = reported
            lastReportedAt = now
            return reported
        }
        guard player.state.playbackStatus == .playing else { return reported }
        return reported + min(now - lastReportedAt, 1)
    }

    func prepare(_ track: Fiber.Track) async throws -> TimeInterval {
        watcher?.cancel()
        lastReported = -1
        request += 1
        let current = request
        let raw = track.id.raw
        if raw.hasPrefix("station:") {
            let lookup = MusicCatalogResourceRequest<MusicKit.Station>(matching: \.id, equalTo: MusicItemID(String(raw.dropFirst(8))))
            guard let station = try await lookup.response().items.first else { throw ProviderError.notFound }
            guard current == request else { throw CancellationError() }
            player.queue = [station]
            duration = 0
        } else if raw.hasPrefix(AppleMusicProvider.libraryPrefix) {
            var lookup = MusicLibraryRequest<Song>()
            lookup.filter(matching: \.id, equalTo: MusicItemID(String(raw.dropFirst(AppleMusicProvider.libraryPrefix.count))))
            guard let song = try await lookup.response().items.first else { throw ProviderError.notFound }
            guard current == request else { throw CancellationError() }
            player.queue = [song]
            duration = song.duration ?? track.duration
        } else {
            let lookup = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(raw))
            guard let song = try await lookup.response().items.first else { throw ProviderError.notFound }
            guard current == request else { throw CancellationError() }
            player.queue = [song]
            duration = song.duration ?? track.duration
        }
        try await player.prepareToPlay()
        return duration
    }

    func play() throws {
        Task {
            do {
                try await player.play()
                lastReported = -1
                watch()
            } catch {
                onFailure?("Apple Music couldn't start playback (\(error.localizedDescription)).")
            }
        }
    }

    func pause() {
        player.pause()
        lastReported = -1
    }

    func seek(to time: TimeInterval) {
        player.playbackTime = time
        lastReported = -1
    }

    func stop() {
        watcher?.cancel()
        lastReported = -1
        request += 1
        player.stop()
    }

    /// The system player reports changes made elsewhere (Control Center, a
    /// headset, the song ending). This keeps Fiber's own state in step.
    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var wasPlaying = true
            var lastTime: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled else { return }
                let isPlaying = self.player.state.playbackStatus == .playing
                let time = self.player.playbackTime
                if !isPlaying, wasPlaying, self.duration > 0, lastTime >= self.duration - 1.5 {
                    self.onFinish?()
                    return
                }
                if isPlaying != wasPlaying { self.onPlayingChanged?(isPlaying) }
                wasPlaying = isPlaying
                if isPlaying { lastTime = time }
            }
        }
    }
}
