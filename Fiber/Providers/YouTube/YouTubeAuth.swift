import CryptoKit
import Foundation

/// Cookie-session proof YouTube Music expects on InnerTube requests.
/// The value is `timestamp + " " + SAPISID + " " + origin`, hashed with SHA1,
/// which is what music.youtube.com itself sends after a Google sign-in.
nonisolated enum YouTubeAuth {
    static func sapisid(in cookieHeader: String) -> String? {
        let pairs = cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ name: String) -> String? {
            pairs.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        return value("__Secure-3PAPISID") ?? value("SAPISID")
    }

    static func authorization(sapisid: String, origin: String, timestamp: Int) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }
}
