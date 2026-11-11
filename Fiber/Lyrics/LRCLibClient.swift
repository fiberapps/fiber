import Foundation

/// Looks up lyrics on LRCLIB (lrclib.net), a free public lyrics database with
/// a documented API. Only the song title, artist, album and length are sent.
/// Most entries are timed per line, so word-by-word fill appears only where
/// the entry really has word timing.
nonisolated struct LRCLibClient: Sendable {
    private struct Entry: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    static let sourceName = "Lyrics from LRCLIB"

    func lyrics(title: String, artist: String, album: String?, duration: TimeInterval) async throws -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album, !album.isEmpty { components.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { components.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        if let data = try await fetch(components), let exact = try Self.lyrics(from: data) { return exact }
        // Album editions and duration rounding often differ across services.
        // Search without album, but validate title, artist and recording length locally.
        components.path = "/api/search"
        components.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        guard let data = try await fetch(components) else { return nil }
        return try Self.bestMatch(from: data, title: title, artist: artist, album: album, duration: duration)
    }

    private func fetch(_ components: URLComponents) async throws -> Data? {
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Fiber music player", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw ProviderError.network("LRCLIB answered with status \(status).") }
        return data
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func bestMatch(from data: Data, title: String, artist: String, album: String?, duration: TimeInterval) throws -> Lyrics? {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let matches = entries.filter {
            normalized($0.trackName ?? "") == normalized(title) && normalized($0.artistName ?? "") == normalized(artist)
                && (duration <= 0 || ($0.duration.map { abs($0 - duration) <= 3 } ?? false))
        }.sorted { lhs, rhs in
            func score(_ entry: Entry) -> Int {
                (entry.syncedLyrics?.isEmpty == false ? 10 : 0)
                    + (normalized(entry.albumName ?? "") == normalized(album ?? "") ? 2 : 0)
            }
            return score(lhs) > score(rhs)
        }
        for entry in matches {
            if entry.instrumental == true { return nil }
            if let result = parsed(entry) { return result }
        }
        return nil
    }

    static func lyrics(from data: Data) throws -> Lyrics? {
        let entry: Entry
        do {
            entry = try JSONDecoder().decode(Entry.self, from: data)
        } catch {
            throw ProviderError.network("LRCLIB sent a reply Fiber couldn't read.")
        }
        return parsed(entry)
    }

    private static func parsed(_ entry: Entry) -> Lyrics? {
        if entry.instrumental == true { return nil }
        if let synced = entry.syncedLyrics, let parsed = LRCParser.parse(synced, source: sourceName) { return parsed }
        if let plain = entry.plainLyrics { return LRCParser.parse(plain, source: sourceName) }
        return nil
    }
}
