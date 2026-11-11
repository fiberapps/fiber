import Foundation

/// Picks a direct audio URL out of a YouTube player response.
///
/// The iOS player client returns ordinary `audio/mp4` addresses Fiber can hand
/// to AVPlayer. Formats that only include a signature cipher are skipped:
/// Fiber does not ship a decipherer, and it does not substitute a different file.
nonisolated enum YouTubeAudio {
    static let playbackUserAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_0 like Mac OS X)"
    static let iosClientVersion = "20.10.4"

    static func bestURL(in json: [String: Any]) throws -> URL {
        let status = json["playabilityStatus"] as? [String: Any]
        let state = status?["status"] as? String ?? ""
        if state == "LOGIN_REQUIRED" {
            throw ProviderError.notConnected(.youtubeMusic)
        }
        if state == "UNPLAYABLE" || state == "CONTENT_CHECK_REQUIRED" {
            let reason = (status?["reason"] as? String) ?? "YouTube Music won't play this song on this account."
            throw ProviderError.playback(reason)
        }
        let streaming = json["streamingData"] as? [String: Any]
        let formats = ((streaming?["adaptiveFormats"] as? [[String: Any]]) ?? [])
            + ((streaming?["formats"] as? [[String: Any]]) ?? [])
        let audio = formats.compactMap { format -> (url: URL, bitrate: Int, aac: Bool)? in
            guard let raw = format["url"] as? String, let url = URL(string: raw) else { return nil }
            let mime = format["mimeType"] as? String ?? ""
            guard mime.hasPrefix("audio/") else { return nil }
            return (url, format["bitrate"] as? Int ?? 0, mime.hasPrefix("audio/mp4"))
        }
        guard let best = audio.sorted(by: { lhs, rhs in
            if lhs.aac != rhs.aac { return lhs.aac && !rhs.aac }
            return lhs.bitrate > rhs.bitrate
        }).first else {
            throw ProviderError.playback("YouTube Music didn't give Fiber an audio stream for this song. It may be blocked, region-locked, or a video Fiber can't play as audio.")
        }
        return best.url
    }
}
