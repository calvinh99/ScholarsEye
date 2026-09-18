import Foundation
import CryptoKit

// Public data only. Private keys are supplied to Sparkle through stdin, never here.
guard CommandLine.arguments.count == 4,
      let publicBytes = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
    fputs("Expected public key, signature, and archive path.\n", stderr)
    exit(1)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else {
        fputs("Archive signature does not match the public key embedded in the app.\n", stderr)
        exit(1)
    }
} catch {
    fputs("Could not verify archive signature: \(error.localizedDescription)\n", stderr)
    exit(1)
}
