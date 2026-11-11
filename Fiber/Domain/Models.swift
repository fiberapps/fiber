import Foundation

// Shared, provider-neutral models. Every service maps its own data into these,
// so the interface never needs to know which service an item came from.

nonisolated enum ServiceID: String, Codable, CaseIterable, Sendable, Identifiable {
    case demo, local, appleMusic, spotify, youtubeMusic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .demo: "Demo Catalog"
        case .local: "Local Files"
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .youtubeMusic: "YouTube Music"
        }
    }
}

nonisolated struct MediaID: Hashable, Codable, Sendable {
    var service: ServiceID
    var raw: String

    var key: String { "\(service.rawValue):\(raw)" }
}

nonisolated enum ArtStyle: String, Codable, Sendable, CaseIterable {
    case bloom, rings, chevrons, stripes, halftone, horizon, tile
}

nonisolated enum Artwork: Hashable, Codable, Sendable {
    /// Drawn on the device from a seed. Used by the demo catalog and as a fallback.
    case generated(seed: UInt64, style: ArtStyle, label: String?)
    /// A remote image. `{w}` and `{h}` in the template are replaced with pixel sizes.
    case remote(template: String)
    /// A file name inside the app's artwork folder.
    case file(name: String)
    case none
}

nonisolated struct Track: Identifiable, Hashable, Codable, Sendable {
    var id: MediaID
    var title: String
    var artistName: String
    var albumTitle: String?
    var albumID: MediaID?
    var artistID: MediaID?
    var duration: TimeInterval
    var trackNumber: Int?
    var isExplicit = false
    var artwork: Artwork = .none
}

nonisolated struct Album: Identifiable, Hashable, Codable, Sendable {
    var id: MediaID
    var title: String
    var artistName: String
    var artistID: MediaID?
    var artwork: Artwork = .none
    var year: Int?
    var genre: String?
    var isExplicit = false
    /// Extra format labels a service reports, such as "Lossless".
    var formatBadges: [String] = []
    var notes: String?
    var shareURL: URL?
}

nonisolated struct Artist: Identifiable, Hashable, Codable, Sendable {
    var id: MediaID
    var name: String
    var artwork: Artwork = .none
    var genre: String?
}

nonisolated struct Playlist: Identifiable, Hashable, Codable, Sendable {
    var id: MediaID
    var name: String
    var curator: String?
    var artwork: Artwork = .none
    var notes: String?
    var isEditable = false
}

nonisolated struct Station: Identifiable, Hashable, Codable, Sendable {
    var id: MediaID
    var name: String
    var tagline: String?
    var artwork: Artwork = .none
}

nonisolated struct BrowseCategory: Identifiable, Hashable, Codable, Sendable {
    var id: MediaID
    var name: String
    var artwork: Artwork = .none
}

nonisolated enum MediaItem: Hashable, Codable, Sendable, Identifiable {
    case track(Track)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case station(Station)
    case category(BrowseCategory)

    var id: MediaID {
        switch self {
        case .track(let v): v.id
        case .album(let v): v.id
        case .artist(let v): v.id
        case .playlist(let v): v.id
        case .station(let v): v.id
        case .category(let v): v.id
        }
    }

    var title: String {
        switch self {
        case .track(let v): v.title
        case .album(let v): v.title
        case .artist(let v): v.name
        case .playlist(let v): v.name
        case .station(let v): v.name
        case .category(let v): v.name
        }
    }

    var subtitle: String? {
        switch self {
        case .track(let v): v.artistName
        case .album(let v): v.artistName
        case .artist: nil
        case .playlist(let v): v.curator
        case .station(let v): v.tagline
        case .category: nil
        }
    }

    var artwork: Artwork {
        switch self {
        case .track(let v): v.artwork
        case .album(let v): v.artwork
        case .artist(let v): v.artwork
        case .playlist(let v): v.artwork
        case .station(let v): v.artwork
        case .category(let v): v.artwork
        }
    }

    var isExplicit: Bool {
        switch self {
        case .track(let v): v.isExplicit
        case .album(let v): v.isExplicit
        default: false
        }
    }
}

// MARK: - Shelves

nonisolated enum ShelfLayout: String, Codable, Sendable {
    /// Tall portrait cards with a caption over the artwork (Home, "Top Picks").
    case heroCards
    /// Square artwork with a title and subtitle underneath.
    case squares
    /// Wide editorial cards with a kicker and headline above the picture (New).
    case editorial
    /// Paged columns of four song rows (New, "Best New Songs").
    case songColumns
    /// Three-column grid of station tiles (Radio).
    case stationGrid
    /// Large cards with a caption band (Radio, "On Air Now").
    case onAir
}

nonisolated struct ShelfEntry: Identifiable, Hashable, Codable, Sendable {
    var item: MediaItem
    var kicker: String?
    var headline: String?
    var caption: String?

    var id: MediaID { item.id }

    init(_ item: MediaItem, kicker: String? = nil, headline: String? = nil, caption: String? = nil) {
        self.item = item
        self.kicker = kicker
        self.headline = headline
        self.caption = caption
    }
}

nonisolated struct Shelf: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String?
    var layout: ShelfLayout
    var entries: [ShelfEntry]
    /// When true the title gets a chevron and opens the full list.
    var canExpand = false
}

// MARK: - Details and search

nonisolated struct AlbumDetail: Hashable, Sendable {
    var album: Album
    var tracks: [Track]
    var moreByArtist: [Album] = []
}

nonisolated struct PlaylistDetail: Hashable, Sendable {
    var playlist: Playlist
    var tracks: [Track]
}

nonisolated struct ArtistDetail: Hashable, Sendable {
    var artist: Artist
    var topTracks: [Track]
    var albums: [Album]
}

nonisolated struct SearchResults: Hashable, Sendable {
    var tracks: [Track] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []

    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

// MARK: - Playback

nonisolated enum RepeatMode: String, Codable, Sendable {
    case off, all, one
}

nonisolated enum PlaybackStatus: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case failed(String)

    var isPlaying: Bool { self == .playing }
}

/// Where the sound is actually produced.
nonisolated enum PlaybackMode: Equatable, Sendable {
    /// Fiber decodes and plays the audio itself.
    case inApp
    /// The system music player plays it on Fiber's behalf (Apple Music).
    case systemPlayer
    /// Another app or device plays it and Fiber only sends commands (Spotify).
    case remote(device: String?)
}

extension TimeInterval {
    /// "3:07" style clock text.
    nonisolated var clockText: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, seconds)
        }
        return "\(minutes):" + String(format: "%02d", seconds)
    }
}
