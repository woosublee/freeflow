#!/usr/bin/env swift

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: validate-sparkle-key.swift <expected-public-key-base64>")
}

guard let expectedPublicKey = Data(base64Encoded: CommandLine.arguments[1]),
      expectedPublicKey.count == 32 else {
    fail("Expected Sparkle public key must decode to 32 bytes")
}

let secretInput = FileHandle.standardInput.readDataToEndOfFile()
guard let secretString = String(data: secretInput, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines),
      let secret = Data(base64Encoded: secretString) else {
    fail("Sparkle private key is not valid base64")
}

let derivedPublicKey: Data
switch secret.count {
case 32:
    do {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        derivedPublicKey = privateKey.publicKey.rawRepresentation
    } catch {
        fail("Unable to derive the Sparkle public key from the private seed")
    }
case 96:
    derivedPublicKey = secret.suffix(32)
default:
    fail("Sparkle private key must decode to 32 or 96 bytes")
}

guard derivedPublicKey == expectedPublicKey else {
    fail("Sparkle private key does not match SUPublicEDKey")
}
