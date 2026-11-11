import Foundation

// Spotify Web API reply shapes, cut down to what Fiber uses. Spotify's
// developer-mode rules have removed and renamed fields more than once, so
// nearly everything is optional and lists skip entries they can't read
// instead of failing the whole page.

/// Decodes an array and silently drops entries that are null or unreadable
/// (search results can contain `null` playlists).
nonisolated struct SpotifyLossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    var elements: [Element]

    private struct Skipped: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(Skipped.self)
            }
        }
        elements = result
    }
}

nonisolated struct SpotifyPage<Element: Decodable & Sendable>: Decodable, Sendable {
    var items: [Element]
    var next: String?
    var total: Int?

    private enum CodingKeys: String, CodingKey { case items, next, total }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent(SpotifyLossyArray<Element>.self, forKey: .items)?.elements ?? []
        next = try container.decodeIfPresent(String.self, forKey: .next)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
    }
}

nonisolated struct SpotifyImage: Decodable, Sendable {
    var url: String
    var width: Int?
    var height: Int?
}

/// An artist, either the short form inside tracks and albums or the full one.
nonisolated struct SpotifyArtistDTO: Decodable, Sendable {
    var id: String?
    var name: String
    var images: [SpotifyImage]?
    var genres: [String]?
}

nonisolated struct SpotifyAlbumDTO: Decodable, Sendable {
    var id: String?
    var name: String
    var albumType: String?
    var artists: [SpotifyArtistDTO]?
    var images: [SpotifyImage]?
    var releaseDate: String?
    var genres: [String]?
    var externalUrls: [String: String]?
    /// Only present when the whole album was requested.
    var tracks: SpotifyPage<SpotifyTrackDTO>?
}

nonisolated struct SpotifyTrackDTO: Decodable, Sendable {
    struct LinkedTrack: Decodable, Sendable { var id: String? }
    var linkedFrom: LinkedTrack? = nil

    /// Spotify can substitute another release of the same recording for this market.
    func matchesPlaybackID(_ requestedID: String) -> Bool {
        id == requestedID || linkedFrom?.id == requestedID
    }

    var id: String?
    var name: String
    var artists: [SpotifyArtistDTO]?
    var album: SpotifyAlbumDTO?
    var durationMs: Int?
    var explicit: Bool?
    var trackNumber: Int?
    var type: String?
    var isLocal: Bool?
}

nonisolated struct SpotifyPlaylistDTO: Decodable, Sendable {
    struct Owner: Decodable, Sendable {
        var id: String?
        var displayName: String?
    }

    var id: String?
    var name: String
    var description: String?
    var images: [SpotifyImage]?
    var owner: Owner?
    var collaborative: Bool?
}

/// One row of a playlist. Spotify's 2026 API calls the song `item`; older
/// replies call it `track`, so both are read.
nonisolated struct SpotifyPlaylistEntry: Decodable, Sendable {
    var item: SpotifyTrackDTO?
    var track: SpotifyTrackDTO?

    var song: SpotifyTrackDTO? { item ?? track }
}

nonisolated struct SpotifySavedAlbum: Decodable, Sendable {
    var album: SpotifyAlbumDTO
}

nonisolated struct SpotifySavedTrack: Decodable, Sendable {
    var track: SpotifyTrackDTO
}

nonisolated struct SpotifyPlayHistory: Decodable, Sendable {
    var track: SpotifyTrackDTO?
    var item: SpotifyTrackDTO?

    var song: SpotifyTrackDTO? { track ?? item }
}

nonisolated struct SpotifyProfile: Decodable, Sendable {
    var id: String
    var displayName: String?
}

nonisolated struct SpotifySearchReply: Decodable, Sendable {
    var tracks: SpotifyPage<SpotifyTrackDTO>?
    var albums: SpotifyPage<SpotifyAlbumDTO>?
    var artists: SpotifyPage<SpotifyArtistDTO>?
    var playlists: SpotifyPage<SpotifyPlaylistDTO>?
}

nonisolated struct SpotifyDevice: Decodable, Sendable, Equatable {
    var id: String?
    var name: String
    var type: String
    var isActive: Bool?
    var isRestricted: Bool?
}

nonisolated struct SpotifyDeviceList: Decodable, Sendable {
    var devices: [SpotifyDevice]
}

nonisolated struct SpotifyPlayerState: Decodable, Sendable {
    var device: SpotifyDevice?
    var isPlaying: Bool?
    var progressMs: Int?
    var item: SpotifyTrackDTO?
}

// MARK: - Mapping into Fiber's models

nonisolated enum SpotifyMapping {
    static func mediaID(_ raw: String) -> MediaID { MediaID(service: .spotify, raw: raw) }

    static func artwork(_ images: [SpotifyImage]?) -> Artwork {
        guard let images, let first = images.first else { return .none }
        // The biggest picture that is still reasonable to download (Spotify typically offers 640, 300 and 64 pixels).
        let sharp = images.filter { (1...800).contains($0.width ?? 0) }
        return .remote(template: (sharp.max { ($0.width ?? 0) < ($1.width ?? 0) } ?? first).url)
    }

    static func names(_ artists: [SpotifyArtistDTO]?) -> String {
        (artists ?? []).map(\.name).joined(separator: ", ")
    }

    static func year(_ releaseDate: String?) -> Int? {
        releaseDate.flatMap { Int($0.prefix(4)) }
    }

    static func album(_ dto: SpotifyAlbumDTO) -> Album? {
        guard let id = dto.id else { return nil }
        return Album(id: mediaID(id), title: dto.name, artistName: names(dto.artists),
                     artistID: dto.artists?.first?.id.map(mediaID), artwork: artwork(dto.images),
                     year: year(dto.releaseDate), genre: dto.genres?.first, isExplicit: false,
                     formatBadges: [], notes: nil, shareURL: dto.externalUrls?["spotify"].flatMap(URL.init(string:)))
    }

    static func artist(_ dto: SpotifyArtistDTO) -> Artist? {
        guard let id = dto.id else { return nil }
        return Artist(id: mediaID(id), name: dto.name, artwork: artwork(dto.images), genre: dto.genres?.first)
    }

    /// `album` fills in what Spotify leaves out of a track listed inside its own album.
    static func track(_ dto: SpotifyTrackDTO, in album: Album? = nil) -> Track? {
        guard let id = dto.id, dto.isLocal != true, dto.type == nil || dto.type == "track" else { return nil }
        let own = dto.album.flatMap { Self.album($0) } ?? album
        return Track(id: mediaID(id), title: dto.name, artistName: names(dto.artists), albumTitle: own?.title,
                     albumID: own?.id, artistID: dto.artists?.first?.id.map(mediaID),
                     duration: Double(dto.durationMs ?? 0) / 1000, trackNumber: dto.trackNumber,
                     isExplicit: dto.explicit ?? false, artwork: own?.artwork ?? .none)
    }

    static func playlist(_ dto: SpotifyPlaylistDTO) -> Playlist? {
        guard let id = dto.id else { return nil }
        let description = dto.description.flatMap { $0.isEmpty ? nil : $0 }
        return Playlist(id: mediaID(id), name: dto.name, curator: dto.owner?.displayName, artwork: artwork(dto.images),
                        notes: description.map(stripMarkup), isEditable: false)
    }

    /// Spotify playlist descriptions can contain links and HTML entities.
    static func stripMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    /// Spotify only returns the songs of playlists the user owns or collaborates on.
    static func isReadable(_ playlist: SpotifyPlaylistDTO, userID: String?) -> Bool {
        playlist.collaborative == true || (userID != nil && playlist.owner?.id == userID)
    }
}
