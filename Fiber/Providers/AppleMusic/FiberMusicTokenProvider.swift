import Foundation
import MusicKit

/// Supplies a locally signed developer token while MusicKit manages user authorization.
/// The private signing key is never included in the app.
nonisolated final class FiberMusicTokenProvider: MusicUserTokenProvider, MusicDeveloperTokenProvider, @unchecked Sendable {
    private struct TokenFile: Decodable {
        let token: String
        let expiresAt: TimeInterval
    }

    func developerToken(options: MusicTokenRequestOptions) async throws -> String {
        // Read afresh on every request, including ignoreCache requests.
        guard let url = Bundle.main.url(forResource: "AppleMusicToken", withExtension: "json") else {
            throw ProviderError.network("This build has no Apple Music developer token. Rebuild with the local MusicKit configuration.")
        }
        let file = try JSONDecoder().decode(TokenFile.self, from: Data(contentsOf: url))
        guard file.expiresAt > Date().timeIntervalSince1970 + 60 else {
            throw ProviderError.network("This build's Apple Music developer token has expired. Install a refreshed Fiber build.")
        }
        return file.token
    }
}
