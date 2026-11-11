import Foundation

/// What a service can really do. The interface reads this instead of assuming,
/// so a control only appears when the service behind it supports the action.
nonisolated struct ProviderCapabilities: Equatable, Sendable {
    var browse = false
    var search = false
    var radio = false
    var playback: PlaybackMode? = nil
    var seek = false
    var equalizer = false
    var backgroundAudio = false
    var syncedLyrics = false
    var libraryRead = false
    var libraryWrite = false
    /// A short, honest description shown in Settings.
    var summary = ""
}

nonisolated enum ConnectionState: Equatable, Sendable {
    /// The service needs no account (demo catalog, local files).
    case notRequired
    case disconnected
    case connecting
    case connected(account: String?)
    /// Connected to the account, but something is missing (for example no subscription).
    case limited(String)
    case failed(String)
    /// The integration is not available in this build or on this device.
    case unavailable(String)

    var isUsable: Bool {
        switch self {
        case .notRequired, .connected, .limited: true
        default: false
        }
    }

    var statusText: String {
        switch self {
        case .notRequired: "Ready"
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected(let account): account.map { "Connected as \($0)" } ?? "Connected"
        case .limited(let reason): reason
        case .failed(let reason): reason
        case .unavailable(let reason): reason
        }
    }
}

nonisolated enum ProviderError: LocalizedError, Equatable {
    case unsupported(String)
    case notConnected(ServiceID)
    case notFound
    case subscriptionRequired
    case permissionDenied
    case network(String)
    /// A message from the service itself, shown as written.
    case service(String)
    case playback(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let what): "\(what) isn't supported by this service."
        case .notConnected(let service): "\(service.displayName) isn't connected. Connect it in Settings."
        case .notFound: "That item couldn't be found."
        case .subscriptionRequired: "An active subscription is needed to play this."
        case .permissionDenied: "Access was denied. You can change this in the Settings app."
        case .network(let detail): "Network problem: \(detail)"
        case .service(let message): message
        case .playback(let detail): "Couldn't play: \(detail)"
        }
    }
}

/// The user's own collection on a streaming service.
nonisolated struct RemoteLibrary: Equatable, Sendable {
    /// Most recently added first.
    var albums: [Album] = []
    var playlists: [Playlist] = []
    var songs: [Track] = []

    var isEmpty: Bool { albums.isEmpty && playlists.isEmpty && songs.isEmpty }
}

/// One music service. Everything service-specific stays behind this protocol.
/// Methods a service can't support keep the default, which throws `unsupported`.
protocol MusicProvider: AnyObject {
    var service: ServiceID { get }
    var capabilities: ProviderCapabilities { get }
    var connection: ConnectionState { get }

    func connect() async
    func disconnect() async

    func homeShelves() async throws -> [Shelf]
    func newShelves() async throws -> [Shelf]
    func radioShelves() async throws -> [Shelf]
    func browseCategories() async throws -> [BrowseCategory]
    func categoryShelves(_ id: MediaID) async throws -> [Shelf]
    func search(_ term: String) async throws -> SearchResults

    func albumDetail(_ id: MediaID) async throws -> AlbumDetail
    func playlistDetail(_ id: MediaID) async throws -> PlaylistDetail
    func artistDetail(_ id: MediaID) async throws -> ArtistDetail
    func stationTracks(_ id: MediaID) async throws -> [Track]

    /// The user's saved albums, playlists and songs on this service.
    func library() async throws -> RemoteLibrary

    func lyrics(for track: Track) async throws -> Lyrics?
    func makeEngine() throws -> any PlaybackEngine
}

extension MusicProvider {
    func connect() async {}
    func disconnect() async {}

    func homeShelves() async throws -> [Shelf] { throw ProviderError.unsupported("Home") }
    func newShelves() async throws -> [Shelf] { throw ProviderError.unsupported("New") }
    func radioShelves() async throws -> [Shelf] { throw ProviderError.unsupported("Radio") }
    func browseCategories() async throws -> [BrowseCategory] { [] }
    func categoryShelves(_ id: MediaID) async throws -> [Shelf] { throw ProviderError.unsupported("Browsing categories") }
    func search(_ term: String) async throws -> SearchResults { throw ProviderError.unsupported("Search") }

    func albumDetail(_ id: MediaID) async throws -> AlbumDetail { throw ProviderError.unsupported("Albums") }
    func playlistDetail(_ id: MediaID) async throws -> PlaylistDetail { throw ProviderError.unsupported("Playlists") }
    func artistDetail(_ id: MediaID) async throws -> ArtistDetail { throw ProviderError.unsupported("Artists") }
    func stationTracks(_ id: MediaID) async throws -> [Track] { throw ProviderError.unsupported("Radio") }

    func library() async throws -> RemoteLibrary { RemoteLibrary() }
    func lyrics(for track: Track) async throws -> Lyrics? { nil }
}

/// Plays one track at a time. The queue lives in `PlaybackController`, so every
/// service gets the same queue, shuffle and repeat behaviour.
protocol PlaybackEngine: AnyObject {
    var mode: PlaybackMode { get }
    /// Seconds into the current track. Read every frame by the lyrics view.
    var currentTime: TimeInterval { get }
    var onFinish: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    /// For players Fiber doesn't own: reports play or pause that happened elsewhere.
    var onPlayingChanged: ((Bool) -> Void)? { get set }

    /// Loads a track and returns its real duration.
    func prepare(_ track: Track) async throws -> TimeInterval
    func play() throws
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}
