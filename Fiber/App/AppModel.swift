import SwiftUI

/// Where a tap can lead inside a tab's navigation stack.
nonisolated enum Route: Hashable, Sendable {
    case album(Album)
    case playlist(Playlist)
    case artist(Artist)
    case category(BrowseCategory)
    case shelf(Shelf)
    case library(LibrarySection)
    case artistName(String)
}

/// What Settings shows for one streaming service.
struct ServiceRow: Identifiable {
    var id: ServiceID
    var connection: ConnectionState
    var capabilities: ProviderCapabilities
}

/// The composition root: builds the stores, the providers and the playback
/// controller, and decides which service the browsing tabs show.
@Observable
final class AppModel {
    let settings: SettingsStore
    let library: LibraryStore
    let playback: PlaybackController
    let audio: FileAudioEngine
    let local: LocalProvider

    var isSettingsPresented = false
    var isPlayerPresented = false
    /// A short confirmation shown at the top of the screen ("Added to Library").
    var toast: String?
    /// The user's collection on connected streaming services, merged into the Library tab.
    private(set) var remoteLibrary = RemoteLibrary()
    private(set) var isLoadingRemoteLibrary = false
    /// Why a service's library couldn't be read, shown at the top of the Library tab.
    private(set) var remoteLibraryProblem: String?
    /// Changes whenever a service is added or removed, so screens re-read the providers.
    private(set) var servicesRevision = 0

    @ObservationIgnored private var providers: [ServiceID: any MusicProvider] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsCache: [MediaID: Lyrics?] = [:]

    /// Streaming services listed under Settings → Music Services, in display order.
    static let streamingServices: [ServiceID] = [.youtubeMusic, .appleMusic, .spotify]

    init(settings: SettingsStore = SettingsStore(), library: LibraryStore = LibraryStore()) {
        self.settings = settings
        self.library = library
        let audio = FileAudioEngine()
        self.audio = audio
        let demo = DemoProvider(audio: audio)
        let local = LocalProvider(library: library, audio: audio)
        self.local = local
        providers = [.demo: demo, .local: local]
        audio.resolvers = [
            .demo: { try await demo.audioURL(for: $0) },
            .local: { try await local.audioURL(for: $0) },
        ]
        audio.apply(settings.equalizer)

        // Captured weakly below once `self` exists.
        var resolve: ((ServiceID) throws -> any PlaybackEngine)?
        playback = PlaybackController { service in
            guard let resolve else { throw ProviderError.notConnected(service) }
            return try resolve(service)
        }
        resolve = { [weak self] service in
            guard let self, let provider = self.providers[service], self.settings.isEnabled(service) else {
                throw ProviderError.notConnected(service)
            }
            return try provider.makeEngine()
        }
        playback.onStarted = { [weak self] track, context in
            self?.library.recordPlayed(context ?? .track(track))
        }
        syncStreamingProviders()
    }

    // MARK: Services

    func provider(for service: ServiceID) -> (any MusicProvider)? {
        _ = servicesRevision
        return settings.isEnabled(service) ? providers[service] : nil
    }

    /// Prefer the saved choice, then another connected streaming service, then demo.
    static func selectBrowsingService(defaultService: ServiceID, candidates: [ServiceRow]) -> ServiceID? {
        let usable = candidates.filter { $0.connection.isUsable && $0.capabilities.browse }
        return usable.first { $0.id == defaultService }?.id
            ?? usable.first { $0.id != .demo }?.id
            ?? usable.first?.id
    }

    private var browsingCandidates: [ServiceRow] {
        (Self.streamingServices + [.demo]).compactMap { service in
            guard let provider = provider(for: service) else { return nil }
            return ServiceRow(id: service, connection: provider.connection, capabilities: provider.capabilities)
        }
    }

    var browsingProvider: (any MusicProvider)? {
        guard let service = Self.selectBrowsingService(defaultService: settings.defaultService,
                                                       candidates: browsingCandidates) else { return nil }
        return provider(for: service)
    }

    /// Includes connection changes even when no usable provider exists yet.
    var browsingLoadKey: String {
        "\(settings.defaultService.rawValue):\(servicesRevision):" + browsingCandidates.map {
            "\($0.id.rawValue):\($0.connection.statusText)"
        }.joined(separator: "|")
    }

    var browsingProblem: String {
        let enabled = Self.streamingServices.filter { settings.isEnabled($0) }
        guard !enabled.isEmpty else {
            return "No music service is turned on. Open Settings from the account button to choose one."
        }
        return enabled.map { service in
            let row = serviceRow(service)
            if row.connection == .disconnected {
                return "\(service.displayName) is enabled but not connected. Open Settings and tap Connect."
            }
            return "\(service.displayName): \(row.connection.statusText)"
        }.joined(separator: "\n")
    }

    /// Services that can be picked as the default right now.
    var defaultServiceChoices: [ServiceID] {
        ([.demo] + Self.streamingServices).filter { service in
            guard let provider = provider(for: service) else { return false }
            return provider.capabilities.browse
        }
    }

    func serviceRow(_ service: ServiceID) -> ServiceRow {
        _ = servicesRevision
        if let provider = providers[service] {
            return ServiceRow(id: service, connection: provider.connection, capabilities: provider.capabilities)
        }
        return ServiceRow(id: service, connection: .unavailable("Not built yet in this version of Fiber"),
                          capabilities: ProviderCapabilities())
    }

    /// Creates the provider for each streaming service that is switched on and
    /// removes it when switched off, so a disabled service runs no code at all.
    func syncStreamingProviders() {
        if settings.enabledServices.contains(.appleMusic) {
            if providers[.appleMusic] == nil {
                let appleMusic = AppleMusicProvider()
                providers[.appleMusic] = appleMusic
                Task {
                    await appleMusic.restore()
                    await refreshRemoteLibrary()
                }
            }
        } else {
            providers[.appleMusic] = nil
            Task { await refreshRemoteLibrary() }
        }
        if settings.enabledServices.contains(.spotify) {
            if providers[.spotify] == nil {
                let spotify = SpotifyProvider()
                providers[.spotify] = spotify
                Task {
                    await spotify.restore()
                    await refreshRemoteLibrary()
                }
            }
        } else {
            providers[.spotify] = nil
            Task { await refreshRemoteLibrary() }
        }
        if settings.enabledServices.contains(.youtubeMusic) {
            if providers[.youtubeMusic] == nil {
                let youtube = YouTubeProvider()
                providers[.youtubeMusic] = youtube
                Task {
                    await youtube.restore()
                    await refreshRemoteLibrary()
                }
            }
        } else {
            providers[.youtubeMusic] = nil
            Task { await refreshRemoteLibrary() }
        }
        servicesRevision += 1
    }

    func connect(_ service: ServiceID) async {
        await providers[service]?.connect()
        await refreshRemoteLibrary()
    }

    func disconnect(_ service: ServiceID) async {
        if playback.current?.id.service == service { playback.pause() }
        await providers[service]?.disconnect()
        await refreshRemoteLibrary()
    }

    /// Re-reads the library of every connected streaming service.
    func refreshRemoteLibrary() async {
        guard !isLoadingRemoteLibrary else { return }
        isLoadingRemoteLibrary = true
        defer { isLoadingRemoteLibrary = false }
        var merged = RemoteLibrary()
        var problems: [String] = []
        for service in Self.streamingServices {
            guard let provider = provider(for: service), provider.connection.isUsable, provider.capabilities.libraryRead else { continue }
            do {
                let found = try await provider.library()
                merged.albums += found.albums
                merged.playlists += found.playlists
                merged.songs += found.songs
            } catch {
                problems.append("\(service.displayName): \(error.localizedDescription)")
            }
        }
        remoteLibrary = merged
        remoteLibraryProblem = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    // MARK: Library across Fiber and connected services

    var libraryAlbums: [Album] { library.albums + remoteLibrary.albums }
    var librarySongs: [Track] { library.songs + remoteLibrary.songs }
    var libraryPlaylists: [Playlist] { library.playlists.map(\.playlist) + library.savedPlaylists + remoteLibrary.playlists }

    var libraryArtistNames: [String] {
        Array(Set(librarySongs.map(\.artistName) + libraryAlbums.map(\.artistName)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var libraryRecentlyAdded: [MediaItem] {
        library.recentlyAdded + remoteLibrary.albums.prefix(60).map { .album($0) }
    }

    /// Called when a service is switched off: stop using it everywhere.
    func serviceDisabled(_ service: ServiceID) async {
        if playback.current?.id.service == service { playback.pause() }
        await providers[service]?.disconnect()
        if settings.defaultService == service { settings.defaultService = .demo }
        syncStreamingProviders()
    }

    /// Prefer supplied word timestamps, then community word timing, then line timing.
    func lyrics(for track: Track) async throws -> Lyrics? {
        if let cached = lyricsCache[track.id] { return cached }
        var found = try await provider(for: track.id.service)?.lyrics(for: track)
        if settings.usesOnlineLyrics, track.id.service != .demo, track.duration > 0, found?.timing != .word {
            var failures: [String] = []
            do {
                if let community = try await UnisonClient().lyrics(title: track.title, artist: track.artistName, duration: track.duration),
                   community.timing == .word || found == nil {
                    found = community
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failures.append("Unison: \(error.localizedDescription)")
            }
            if found?.timing != .word {
                do {
                    if let fallback = try await LRCLibClient().lyrics(title: track.title, artist: track.artistName,
                                                                      album: track.albumTitle, duration: track.duration),
                       found == nil || fallback.timing == .word || (found?.timing == .unsynced && fallback.timing != .unsynced) {
                        found = fallback
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    failures.append("LRCLIB: \(error.localizedDescription)")
                }
            }
            if found == nil, !failures.isEmpty { throw ProviderError.network(failures.joined(separator: "\n")) }
        }
        #if DEBUG
        // Exercise the line-only fallback using original demo lyrics, without network data.
        if track.id.service == .demo, ProcessInfo.processInfo.arguments.contains("-line-lyrics"), found != nil {
            found?.timing = .line
            for index in found!.lines.indices { found?.lines[index].words = nil }
        }
        #endif
        found = found?.fillingMissingWordTiming()
        // A miss must not persist for the entire session; new lyrics can appear.
        if let found { lyricsCache[track.id] = .some(found) }
        return found
    }

    /// The first demo album, for scripted screenshots.
    var demoAlbumRoute: Route? {
        (providers[.demo] as? DemoProvider)?.catalog.albums.first.map(Route.album)
    }

    func applyEqualizer() {
        audio.apply(settings.equalizer)
    }

    // MARK: Actions shared by many screens

    func play(_ tracks: [Track], at index: Int = 0, shuffled: Bool = false, context: MediaItem? = nil) {
        playback.play(tracks, startingAt: index, shuffled: shuffled, context: context)
    }

    func play(station: Station) {
        Task {
            do {
                guard let provider = provider(for: station.id.service) else { throw ProviderError.notConnected(station.id.service) }
                let tracks = try await provider.stationTracks(station.id)
                play(tracks, context: .station(station))
            } catch {
                playback.problem = error.localizedDescription
            }
        }
    }

    func toggleSaved(_ media: MediaItem) {
        let wasSaved = library.isSaved(media.id)
        library.toggleSaved(media)
        showToast(wasSaved ? "Removed from Library" : "Added to Library")
    }

    func toggleFavorite(_ track: Track) {
        let wasFavorite = library.isFavorite(track.id)
        library.toggleFavorite(track)
        showToast(wasFavorite ? "Removed from Favorites" : "Added to Favorites")
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.toast = nil }
        }
    }
}
