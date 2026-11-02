import Foundation
import CryptoKit
import CommonCrypto

// Envelope encryption, byte-compatible with bridge/src/crypto.ts:
//   key = PBKDF2-HMAC-SHA256(NFC(passphrase), salt, iter, 32)
//   ct  = AES-256-GCM(key, iv[12], plaintext, aad = "tagwerk:" + kind) -> ciphertext || tag[16]

public enum EnvelopeKind: String, Codable, Sendable {
    case inbox, snapshot
}

public struct Envelope: Codable, Sendable {
    public var tw: Int
    public var k: String
    public var kdf: String
    public var iter: Int
    public var salt: String
    public var iv: String
    public var ct: String
}

public enum TagwerkCryptoError: LocalizedError, Equatable {
    case noPassphrase
    case badEnvelope
    case wrongKind(expected: String, found: String)
    case decryptFailed
    case kdfFailed

    public var errorDescription: String? {
        switch self {
        case .noPassphrase: return "Keine Passphrase gesetzt."
        case .badEnvelope: return "Die Datei ist kein gültiger Tagwerk-Umschlag."
        case .wrongKind(let e, let f): return "Falscher Dateityp: erwartet \(e), gefunden \(f)."
        case .decryptFailed: return "Entschlüsselung fehlgeschlagen. Stimmt die Passphrase in App und Plugin überein?"
        case .kdfFailed: return "Schlüsselableitung fehlgeschlagen."
        }
    }
}

public enum TagwerkCrypto {
    public static let defaultIterations = 600_000

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var keyCache: [String: SymmetricKey] = [:]

    public static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizeJournal(_ text: String?) -> String {
        guard let text else { return "" }
        return text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "" for no or empty text, else the first 16 hex chars of SHA-256 of the normalised text.
    public static func journalHash(_ text: String?) -> String {
        let n = normalizeJournal(text)
        if n.isEmpty { return "" }
        return String(sha256Hex(Data(n.utf8)).prefix(16))
    }

    public static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let pw = passphrase.precomposedStringWithCanonicalMapping
        let cacheID = "\(iterations)|\(salt.base64EncodedString())|\(sha256Hex(Data(pw.utf8)))"
        cacheLock.lock()
        if let k = keyCache[cacheID] {
            cacheLock.unlock()
            return k
        }
        cacheLock.unlock()

        var derived = [UInt8](repeating: 0, count: 32)
        let pwData = Data(pw.utf8)
        let status: Int32 = pwData.withUnsafeBytes { (pwBuf: UnsafeRawBufferPointer) -> Int32 in
            salt.withUnsafeBytes { (saltBuf: UnsafeRawBufferPointer) -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBuf.bindMemory(to: CChar.self).baseAddress, pwData.count,
                    saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    &derived, derived.count)
            }
        }
        guard status == Int32(kCCSuccess) else { throw TagwerkCryptoError.kdfFailed }
        let key = SymmetricKey(data: derived)
        cacheLock.lock()
        keyCache[cacheID] = key
        cacheLock.unlock()
        return key
    }

    private static func aad(_ kind: String) -> Data { Data("tagwerk:\(kind)".utf8) }

    public static func seal(_ plaintext: Data, passphrase: String, kind: EnvelopeKind, salt: Data,
                            iterations: Int = defaultIterations, iv: Data? = nil) throws -> Data {
        guard !passphrase.isEmpty else { throw TagwerkCryptoError.noPassphrase }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let ivData = iv ?? randomBytes(12)
        let nonce = try AES.GCM.Nonce(data: ivData)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad(kind.rawValue))
        var ct = Data(box.ciphertext)
        ct.append(contentsOf: box.tag)
        let env = Envelope(tw: 1, k: kind.rawValue, kdf: "pbkdf2-sha256", iter: iterations,
                           salt: salt.base64EncodedString(), iv: ivData.base64EncodedString(), ct: ct.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(env)
    }

    public static func open(_ envelopeData: Data, passphrase: String, kind: EnvelopeKind) throws -> Data {
        guard !passphrase.isEmpty else { throw TagwerkCryptoError.noPassphrase }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: envelopeData), env.tw == 1, env.kdf == "pbkdf2-sha256" else {
            throw TagwerkCryptoError.badEnvelope
        }
        guard env.k == kind.rawValue else { throw TagwerkCryptoError.wrongKind(expected: kind.rawValue, found: env.k) }
        guard (100_000...5_000_000).contains(env.iter),
              let salt = Data(base64Encoded: env.salt),
              let iv = Data(base64Encoded: env.iv),
              let ct = Data(base64Encoded: env.ct), ct.count >= 16 else {
            throw TagwerkCryptoError.badEnvelope
        }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: env.iter)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                            ciphertext: ct.prefix(ct.count - 16),
                                            tag: ct.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: aad(env.k))
        } catch {
            throw TagwerkCryptoError.decryptFailed
        }
    }
}
