import Foundation

/// Turns YouTube Music's nested browse and search JSON into Fiber's models.
nonisolated enum YouTubeCatalog {
    private static let service = ServiceID.youtubeMusic

    static func shelves(in root: Any) -> [Shelf] {
        var shelves: [Shelf] = []
        for (index, carousel) in dictionaries(root, key: "musicCarouselShelfRenderer").enumerated() {
            let title = text(carousel["header"]) ?? "YouTube Music"
            let entries = items(in: carousel["contents"] ?? [:])
            guard !entries.isEmpty else { continue }
            let layout: ShelfLayout = entries.allSatisfy { if case .track = $0.item { true } else { false } } ? .songColumns : .squares
            shelves.append(Shelf(id: "yt-\(index)-\(title)", title: title, layout: layout, entries: entries))
        }
        if shelves.isEmpty {
            let entries = items(in: root)
            if !entries.isEmpty {
                shelves.append(Shelf(id: "yt-mixed", title: "YouTube Music", layout: .squares, entries: entries))
            }
        }
        return shelves
    }

    static func tracks(in root: Any) -> [Track] {
        dictionaries(root, key: "musicResponsiveListItemRenderer").compactMap(track(from:))
    }

    static func searchResults(in root: Any) -> SearchResults {
        var results = SearchResults()
        var seen = Set<String>()
        for entry in items(in: root) {
            guard seen.insert(entry.item.id.key).inserted else { continue }
            switch entry.item {
            case .track(let track): results.tracks.append(track)
            case .album(let album): results.albums.append(album)
            case .artist(let artist): results.artists.append(artist)
            case .playlist(let playlist): results.playlists.append(playlist)
            default: break
            }
        }
        return results
    }

    static func albumDetail(in pages: [Any], id: MediaID) -> AlbumDetail {
        let header = headerTitle(in: pages.first ?? [:])
        let parsed = pages.flatMap { tracks(in: $0) }
        let album = Album(id: id, title: header.title ?? parsed.first?.albumTitle ?? "Album",
                          artistName: header.subtitle ?? parsed.first?.artistName ?? "YouTube Music",
                          artwork: header.artwork ?? parsed.first?.artwork ?? .none)
        let tracks = parsed.map { track in
            var copy = track
            copy.albumTitle = album.title
            copy.albumID = id
            if copy.artistName.isEmpty { copy.artistName = album.artistName }
            return copy
        }
        return AlbumDetail(album: album, tracks: tracks)
    }

    static func playlistDetail(in pages: [Any], id: MediaID) -> PlaylistDetail {
        let header = headerTitle(in: pages.first ?? [:])
        let tracks = pages.flatMap { tracks(in: $0) }
        let playlist = Playlist(id: id, name: header.title ?? "Playlist", curator: header.subtitle,
                                artwork: header.artwork ?? tracks.first?.artwork ?? .none)
        return PlaylistDetail(playlist: playlist, tracks: tracks)
    }

    static func artistDetail(in root: Any, id: MediaID) -> ArtistDetail {
        let header = headerTitle(in: root)
        let artist = Artist(id: id, name: header.title ?? "Artist", artwork: header.artwork ?? .none)
        let songs = tracks(in: root)
        let albums = items(in: root).compactMap { entry -> Album? in
            if case .album(let album) = entry.item { return album }
            return nil
        }
        return ArtistDetail(artist: artist, topTracks: Array(songs.prefix(20)), albums: albums)
    }

    static func library(playlists: Any, albums: Any, songs: Any) -> RemoteLibrary {
        RemoteLibrary(
            albums: items(in: albums).compactMap { if case .album(let album) = $0.item { album } else { nil } },
            playlists: items(in: playlists).compactMap { if case .playlist(let playlist) = $0.item { playlist } else { nil } },
            songs: tracks(in: songs)
        )
    }

    static func continuationToken(in root: Any) -> String? {
        if let command = dictionaries(root, key: "continuationCommand").last, let token = command["token"] as? String, !token.isEmpty {
            return token
        }
        if let next = dictionaries(root, key: "nextContinuationData").last, let token = next["continuation"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    // MARK: Items

    private struct Header {
        var title: String?
        var subtitle: String?
        var artwork: Artwork?
    }

    private static func items(in root: Any) -> [ShelfEntry] {
        var entries: [ShelfEntry] = []
        var seen = Set<String>()
        for row in dictionaries(root, key: "musicResponsiveListItemRenderer") {
            guard let track = track(from: row) else { continue }
            guard seen.insert(track.id.key).inserted else { continue }
            entries.append(ShelfEntry(.track(track)))
        }
        for card in dictionaries(root, key: "musicTwoRowItemRenderer") {
            guard let entry = cardEntry(from: card), seen.insert(entry.item.id.key).inserted else { continue }
            entries.append(entry)
        }
        return entries
    }

    private static func track(from row: [String: Any]) -> Track? {
        let videoID = (row["playlistItemData"] as? [String: Any])?["videoId"] as? String
            ?? watchID(in: row)
        guard let videoID, !videoID.isEmpty else { return nil }
        let columns = dictionaries(row, key: "musicResponsiveListItemFlexColumnRenderer")
        let title = columns.first.flatMap { text($0["text"]) } ?? "Unknown song"
        let artist = columns.dropFirst().first.flatMap { text($0["text"]) } ?? "YouTube Music"
        let album = columns.dropFirst(2).first.flatMap { text($0["text"]) }
        let duration = dictionaries(row, key: "musicResponsiveListItemFixedColumnRenderer").first.flatMap { text($0["text"]) }
        return Track(id: MediaID(service: service, raw: videoID), title: title, artistName: artist,
                     albumTitle: album, duration: clock(duration), isExplicit: isExplicit(row), artwork: artwork(in: row))
    }

    private static func cardEntry(from card: [String: Any]) -> ShelfEntry? {
        let title = text(card["title"]) ?? "YouTube Music"
        let subtitle = text(card["subtitle"])
        let art = artwork(in: card)
        if let videoID = watchID(in: card) {
            let track = Track(id: MediaID(service: service, raw: videoID), title: title,
                              artistName: subtitle ?? "YouTube Music", duration: 0, artwork: art)
            return ShelfEntry(.track(track))
        }
        guard let browse = browseEndpoint(in: card), let browseID = browse["browseId"] as? String else { return nil }
        let id = MediaID(service: service, raw: browseID)
        let kind = pageType(browse)
        if kind == "MUSIC_PAGE_TYPE_ARTIST" || browseID.hasPrefix("UC") {
            return ShelfEntry(.artist(Artist(id: id, name: title, artwork: art)))
        }
        if kind == "MUSIC_PAGE_TYPE_ALBUM" || browseID.hasPrefix("MPRE") {
            return ShelfEntry(.album(Album(id: id, title: title, artistName: subtitle ?? "YouTube Music", artwork: art)))
        }
        return ShelfEntry(.playlist(Playlist(id: id, name: title, curator: subtitle, artwork: art)))
    }

    private static func headerTitle(in root: Any) -> Header {
        let header = dictionaries(root, key: "musicResponsiveHeaderRenderer").first
            ?? dictionaries(root, key: "musicDetailHeaderRenderer").first
            ?? dictionaries(root, key: "musicImmersiveHeaderRenderer").first
        return Header(title: header.flatMap { text($0["title"]) },
                      subtitle: header.flatMap { text($0["subtitle"]) },
                      artwork: header.map { artwork(in: $0) })
    }

    // MARK: JSON helpers

    private static func dictionaries(_ value: Any, key: String) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func visit(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let child = dict[key] as? [String: Any] { found.append(child) }
                for child in dict.values { visit(child) }
            } else if let list = node as? [Any] {
                for child in list { visit(child) }
            }
        }
        visit(value)
        return found
    }

    private static func text(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        let combined = runTexts(value).joined()
        let cleaned = combined.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.nilIfEmpty
    }

    private static func runTexts(_ value: Any) -> [String] {
        guard let dict = value as? [String: Any] else {
            if let list = value as? [Any] { return list.flatMap(runTexts) }
            return []
        }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }
        }
        if let simple = dict["simpleText"] as? String { return [simple] }
        return dict.values.flatMap(runTexts)
    }

    private static func artwork(in value: Any) -> Artwork {
        let thumbs = dictionaries(value, key: "thumbnails")
        let urls = thumbs.flatMap { thumb -> [String] in
            if let list = thumb["thumbnails"] as? [[String: Any]] {
                return list.compactMap { $0["url"] as? String }
            }
            return []
        }
        // The walker also finds each thumbnail object when the key is nested one level down.
        let nested = dictionaries(value, key: "thumbnail").flatMap { node -> [String] in
            guard let list = (node["thumbnails"] as? [[String: Any]]) ?? ((node["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) else { return [] }
            return list.compactMap { $0["url"] as? String }
        }
        guard let raw = (urls + nested).last else { return .none }
        return .remote(template: sized(raw))
    }

    /// YouTube thumbnail URLs accept a `w{width}-h{height}` suffix. `{w}` and `{h}`
    /// are filled in by the artwork loader.
    private static func sized(_ url: String) -> String {
        if url.contains("{w}") { return url }
        if let range = url.range(of: "=w\\d+-h\\d+", options: .regularExpression) {
            return url.replacingCharacters(in: range, with: "=w{w}-h{h}")
        }
        if url.contains("lh3.googleusercontent.com") || url.contains("yt3.googleusercontent.com") || url.contains("yt3.ggpht.com") {
            return url + "=w{w}-h{h}"
        }
        return url
    }

    private static func watchID(in value: Any) -> String? {
        dictionaries(value, key: "watchEndpoint").first?["videoId"] as? String
    }

    private static func browseEndpoint(in value: Any) -> [String: Any]? {
        dictionaries(value, key: "browseEndpoint").first
    }

    private static func pageType(_ browse: [String: Any]) -> String? {
        let configs = browse["browseEndpointContextSupportedConfigs"] as? [String: Any]
        let music = configs?["browseEndpointContextMusicConfig"] as? [String: Any]
        return music?["pageType"] as? String
    }

    private static func isExplicit(_ value: Any) -> Bool {
        dictionaries(value, key: "icon").contains { ($0["iconType"] as? String) == "MUSIC_EXPLICIT_BADGE" }
    }

    private static func clock(_ text: String?) -> TimeInterval {
        guard let text else { return 0 }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        case 2: return TimeInterval(parts[0] * 60 + parts[1])
        default: return 0
        }
    }
}
