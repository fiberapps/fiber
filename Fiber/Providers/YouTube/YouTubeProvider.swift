import Foundation
import Observation

/// YouTube Music through the account's own Google sign-in.
///
/// Library, search and albums come from YouTube Music's browse API. Playback
/// asks the iOS player endpoint for an audio address and plays that address
/// inside Fiber, so the queue, lyrics and Lock Screen stay here.
@Observable
final class YouTubeProvider: MusicProvider {
    let service = ServiceID.youtubeMusic
    private(set) var connection = ConnectionState.disconnected
    var isSigningIn = false

    let capabilities = ProviderCapabilities(
        browse: true, search: true, radio: false, playback: .inApp, seek: true, equalizer: false,
        backgroundAudio: true, syncedLyrics: false, libraryRead: true, libraryWrite: false,
        summary: "Sign in with the Google account that has your YouTube Music library. Songs play inside Fiber, with Fiber's queue, lyrics and Lock Screen. YouTube only returns an audio stream for songs that account is allowed to play.")

    private let session: YouTubeSession
    private let engine = StreamAudioEngine()
    @ObservationIgnored private var signInWait: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var signInFinished = false

    init(session: YouTubeSession = YouTubeSession()) {
        self.session = session
        engine.resolver = { [session] track in try await session.audioURL(for: track.id.raw) }
    }

    func restore() async {
        guard session.hasCookies else { return }
        connection = .connecting
        await loadAccount()
    }

    func connect() async {
        if session.hasCookies {
            connection = .connecting
            await loadAccount()
            if connection.isUsable { return }
        }
        isSigningIn = true
        signInFinished = false
        await withCheckedContinuation { signInWait = $0 }
        signInWait = nil
        guard session.hasCookies else {
            if !connection.isUsable { connection = .disconnected }
            return
        }
        connection = .connecting
        await loadAccount()
    }

    func completeSignIn(cookieHeader: String, account: String?) {
        guard !signInFinished else { return }
        signInFinished = true
        session.store(cookieHeader: cookieHeader, account: account)
        isSigningIn = false
        signInWait?.resume()
    }

    func cancelSignIn() {
        guard !signInFinished else { return }
        signInFinished = true
        isSigningIn = false
        signInWait?.resume()
    }

    func disconnect() async {
        engine.stop()
        session.signOut()
        connection = .disconnected
    }

    func makeEngine() throws -> any PlaybackEngine {
        guard session.hasCookies, connection.isUsable else { throw ProviderError.notConnected(.youtubeMusic) }
        return engine
    }

    func homeShelves() async throws -> [Shelf] { try YouTubeCatalog.shelves(in: try await api { try await $0.browse("FEmusic_home") }) }
    func newShelves() async throws -> [Shelf] { try YouTubeCatalog.shelves(in: try await api { try await $0.browse("FEmusic_new_releases") }) }
    func search(_ term: String) async throws -> SearchResults {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SearchResults() }
        return try YouTubeCatalog.searchResults(in: try await api { try await $0.search(query) })
    }

    func albumDetail(_ id: MediaID) async throws -> AlbumDetail {
        try YouTubeCatalog.albumDetail(in: try await api { try await $0.pages(for: id.raw) }, id: id)
    }

    func playlistDetail(_ id: MediaID) async throws -> PlaylistDetail {
        try YouTubeCatalog.playlistDetail(in: try await api { try await $0.pages(for: id.raw) }, id: id)
    }

    func artistDetail(_ id: MediaID) async throws -> ArtistDetail {
        try YouTubeCatalog.artistDetail(in: try await api { try await $0.browse(id.raw) }, id: id)
    }

    func library() async throws -> RemoteLibrary {
        try await api { session in
            let playlists = try await session.browse("FEmusic_liked_playlists")
            let albums = try await session.browse("FEmusic_liked_albums")
            let songs = try await session.browse("FEmusic_liked_videos")
            return YouTubeCatalog.library(playlists: playlists, albums: albums, songs: songs)
        }
    }

    private func loadAccount() async {
        do {
            _ = try await session.browse("FEmusic_library_landing")
            connection = .connected(account: session.accountName ?? "Google account")
        } catch is CancellationError {
            connection = .disconnected
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    private func api<T>(_ work: (YouTubeSession) async throws -> T) async throws -> T {
        guard session.hasCookies, connection.isUsable else { throw ProviderError.notConnected(.youtubeMusic) }
        do { return try await work(session) }
        catch is CancellationError { throw CancellationError() }
        catch let error as ProviderError { throw error }
        catch { throw ProviderError.network(error.localizedDescription) }
    }
}
