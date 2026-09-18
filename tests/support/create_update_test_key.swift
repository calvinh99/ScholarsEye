// Local updater integration tests only. Never reads or writes the Keychain.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Expected private-key path and public-key path")
}
let privateURL = URL(fileURLWithPath: CommandLine.arguments[1])
let publicURL = URL(fileURLWithPath: CommandLine.arguments[2])
let key: Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath: privateURL.path) {
    let encoded = try String(contentsOf: privateURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: encoded), raw.count == 32 else {
        fatalError("Invalid local test signing key; refusing to replace it")
    }
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
} else {
    key = Curve25519.Signing.PrivateKey()
    try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
        .write(to: privateURL, options: .atomic)
}
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
try Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8)
    .write(to: publicURL, options: .atomic)
print("Local test signing key is ready. No Keychain access was used.")
