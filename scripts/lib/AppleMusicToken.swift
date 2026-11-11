// Prints a 30-day Apple Music API developer token (an ES256 JWT) signed
// with a MusicKit .p8 key. Mac-side tooling only; only the resulting token
// is bundled in Fiber.
//
// Usage: swift scripts/lib/AppleMusicToken.swift TEAM_ID KEY_ID KEY_FILE
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: AppleMusicToken.swift TEAM_ID KEY_ID KEY_FILE\n".utf8))
    exit(2)
}
let (team, keyID, keyFile) = (arguments[1], arguments[2], arguments[3])

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

do {
    let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: keyFile, encoding: .utf8))
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: .sortedKeys)
    let claims = try JSONSerialization.data(withJSONObject: ["iss": team, "iat": now, "exp": now + 30 * 24 * 3600], options: .sortedKeys)
    let signingInput = base64URL(header) + "." + base64URL(claims)
    let signature = try key.signature(for: Data(signingInput.utf8))
    print(signingInput + "." + base64URL(signature.rawRepresentation))
} catch {
    FileHandle.standardError.write(Data("couldn't sign with \(keyFile): \(error)\n".utf8))
    exit(1)
}
