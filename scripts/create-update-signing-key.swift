import Foundation
import CryptoKit

// Run once on the release maintainer's Mac. The private seed is never printed.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent(".secrets/updates", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
let privateURL = directory.appendingPathComponent("private.b64")
let key: Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath: privateURL.path) {
    let text = try String(contentsOf: privateURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: text), data.count == 32 else {
        fatalError("Existing signing key is invalid; refusing to overwrite it.")
    }
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
} else {
    key = Curve25519.Signing.PrivateKey()
    try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: privateURL, options: .atomic)
}
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
let publicURL = directory.appendingPathComponent("public.b64")
try Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: publicURL, options: .atomic)
print("Update signing key is ready in .secrets/updates. Back up this directory securely; never commit it.")
