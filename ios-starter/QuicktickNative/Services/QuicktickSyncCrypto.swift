import Foundation
import CryptoKit
import Security

struct ParsedSyncID: Equatable, Sendable {
    let full: String
    let recordID: String
    let secret: Data
}

struct SyncCryptoMaterial: Sendable {
    let parsed: ParsedSyncID
    let key: SymmetricKey
    let verifier: String
}

enum QuicktickSyncCryptoError: LocalizedError {
    case invalidID, invalidEnvelope, invalidCiphertext
    var errorDescription: String? {
        switch self {
        case .invalidID: "That is not a valid Quicktick Sync ID. Copy the full QT6-… ID from the other device."
        case .invalidEnvelope: "The cloud profile uses an invalid or unsupported encryption format."
        case .invalidCiphertext: "The cloud profile cannot be decrypted with this Sync ID."
        }
    }
}

enum QuicktickSyncCrypto {
    static let prefix = "QT6"

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    static func generate() -> String {
        var record = Data(count: 16), secret = Data(count: 32)
        let recordStatus = record.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let secretStatus = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(recordStatus == errSecSuccess && secretStatus == errSecSuccess, "Secure random generation failed")
        return "\(prefix)-\(base64URL(record)).\(base64URL(secret))"
    }

    static func parse(_ value: String) throws -> ParsedSyncID {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^QT6-([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges == 3,
              let r1 = Range(match.range(at: 1), in: trimmed), let r2 = Range(match.range(at: 2), in: trimmed),
              let record = decodeBase64URL(String(trimmed[r1])), record.count == 16,
              let secret = decodeBase64URL(String(trimmed[r2])), secret.count == 32,
              base64URL(record) == String(trimmed[r1]), base64URL(secret) == String(trimmed[r2]) else { throw QuicktickSyncCryptoError.invalidID }
        return ParsedSyncID(full: trimmed, recordID: String(trimmed[r1]), secret: secret)
    }

    static func derive(_ syncID: String) throws -> SyncCryptoMaterial {
        let parsed = try parse(syncID)
        let encPrefix = Data("quicktick-sync-encryption-v1:".utf8)
        let verifyPrefix = Data("quicktick-sync-verifier-v1:".utf8)
        let keyDigest = SHA256.hash(data: encPrefix + parsed.secret)
        let verifierDigest = SHA256.hash(data: verifyPrefix + parsed.secret)
        return SyncCryptoMaterial(parsed: parsed, key: SymmetricKey(data: Data(keyDigest)), verifier: base64URL(Data(verifierDigest)))
    }

    static func encrypt<T: Encodable>(_ value: T, syncID: String, nonceData: Data? = nil) throws -> (recordID: String, verifier: String, envelope: SyncEnvelope) {
        let material = try derive(syncID)
        let plain = try JSONEncoder.webCompatible.encode(value)
        let nonce: AES.GCM.Nonce
        if let nonceData { nonce = try AES.GCM.Nonce(data: nonceData) } else { nonce = AES.GCM.Nonce() }
        let aad = Data("Quicktick:\(material.parsed.recordID):v1".utf8)
        let sealed = try AES.GCM.seal(plain, using: material.key, nonce: nonce, authenticating: aad)
        let combinedWebData = sealed.ciphertext + sealed.tag
        let nonceBytes = nonce.withUnsafeBytes { Data($0) }
        let envelope = SyncEnvelope(v: 1, alg: "A256GCM", iv: base64URL(nonceBytes), data: base64URL(combinedWebData))
        return (material.parsed.recordID, material.verifier, envelope)
    }

    static func decrypt<T: Decodable>(_ type: T.Type, envelope: SyncEnvelope, syncID: String) throws -> T {
        guard envelope.v == 1, envelope.alg == "A256GCM", let iv = decodeBase64URL(envelope.iv), iv.count == 12, let combined = decodeBase64URL(envelope.data), combined.count >= 16 else { throw QuicktickSyncCryptoError.invalidEnvelope }
        let material = try derive(syncID)
        let cipher = combined.dropLast(16), tag = combined.suffix(16)
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag)
        let aad = Data("Quicktick:\(material.parsed.recordID):v1".utf8)
        let plain: Data
        do { plain = try AES.GCM.open(box, using: material.key, authenticating: aad) }
        catch { throw QuicktickSyncCryptoError.invalidCiphertext }
        return try JSONDecoder().decode(type, from: plain)
    }
}

extension JSONEncoder {
    static var webCompatible: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }
}
