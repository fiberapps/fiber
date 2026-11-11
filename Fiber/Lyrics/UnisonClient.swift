import Foundation

/// Public community submissions only; no private music-service endpoints.
nonisolated struct UnisonClient: Sendable {
    private struct Reply: Decodable {
        var success: Bool
        var data: Entry?
    }
    private struct Entry: Decodable {
        var videoId: String
        var song: String
        var artist: String
        var format: String
        var lyrics: String
        var submitter: Submitter?
    }
    private struct Submitter: Decodable {
        var keyId: String
        var displayName: String
    }

    func lyrics(title: String, artist: String, duration: TimeInterval) async throws -> Lyrics? {
        var components = URLComponents(string: "https://unison.betterlyrics.org/lyrics")!
        components.queryItems = [.init(name: "song", value: title), .init(name: "artist", value: artist)]
        if duration > 0 { components.queryItems?.append(.init(name: "duration", value: String(Int(duration.rounded())))) }
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Fiber/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw ProviderError.network("Unison answered with status \(status).") }
        return try Self.lyrics(from: data, title: title, artist: artist)
    }

    static func lyrics(from data: Data, title: String, artist: String) throws -> Lyrics? {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.success, let entry = reply.data,
              LRCLibClient.normalized(entry.song) == LRCLibClient.normalized(title),
              LRCLibClient.normalized(entry.artist) == LRCLibClient.normalized(artist) else { return nil }
        var result = entry.format == "ttml"
            ? TTMLParser.parse(entry.lyrics, source: "Lyrics from Unison")
            : LRCParser.parse(entry.lyrics, source: "Lyrics from Unison")
        result?.sourceURL = URL(string: "https://unison.betterlyrics.org/song/\(entry.videoId)")
        result?.contributor = entry.submitter?.displayName
        if let submitter = entry.submitter {
            result?.contributorURL = URL(string: "https://unison.betterlyrics.org/curator/\(submitter.keyId)")
        }
        return result
    }
}
