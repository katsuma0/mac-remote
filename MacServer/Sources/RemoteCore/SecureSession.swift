#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// Couchpad security, in short
// ---------------------------
// Pairing (once per iPhone): the Mac shows a QR code (256-bit secret) and a 6-digit code while
// the user has "Pair iPhone" open. Both sides do an X25519 key exchange and prove knowledge of
// the secret with an HMAC over everything exchanged so far. The Mac then hands the iPhone a
// random 256-bit pairing key, encrypted. Wrong codes are counted and pairing closes after a few.
//
// Every connection afterwards: a fresh X25519 exchange; each side proves it holds the pairing
// key (so a stranger can't control the Mac, and a fake Mac can't collect what you type).
// Session keys are derived from the exchange + pairing key, so each session is encrypted with
// new keys (forward secrecy). All commands are then sealed with ChaChaPoly and numbered, so they
// can't be read, changed, replayed or reordered.

public let couchpadProtocolVersion = 2

public enum HandshakeError: Error, Equatable {
    case malformed(String)
    /// A proof didn't verify: wrong pairing code, a forged message, or keys that don't match.
    case notAuthentic
    case pairingRejected(String)
}

public enum ChannelError: Error, Equatable {
    case malformed
    case replayed
}

/// Handshake messages are the only plaintext ever sent. They carry public keys, random nonces
/// and HMAC proofs — nothing that reveals a secret.
public struct HandshakeMessage: Codable, Equatable {
    public var t: String
    public var v: Int?
    public var id: String?        // sender's device id
    public var name: String?      // sender's device name (shown in the UI)
    public var epk: String?       // ephemeral X25519 public key, base64
    public var n: String?         // 32-byte random nonce, base64
    public var method: String?    // pairing method: "qr" | "code"
    public var proof: String?     // HMAC-SHA256, base64
    public var box: String?       // pairing key sealed for the iPhone, base64
    public var e: String?         // error shown to the user

    public init(t: String, v: Int? = nil, id: String? = nil, name: String? = nil, epk: String? = nil,
                n: String? = nil, method: String? = nil, proof: String? = nil, box: String? = nil,
                e: String? = nil) {
        self.t = t
        self.v = v
        self.id = id
        self.name = name
        self.epk = epk
        self.n = n
        self.method = method
        self.proof = proof
        self.box = box
        self.e = e
    }
}

public enum PairingMethod: String, Codable {
    case qr, code
}

public enum PairingSecret {
    /// The secret behind a 6-digit code (spaces and dashes ignored).
    public static func fromCode(_ code: String) -> Data {
        Data(("couchpad-code:" + code.filter(\.isNumber)).utf8)
    }

    public static func randomQRSecret() -> Data {
        SymmetricKey(size: .bits256).rawData
    }

    public static func randomCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0...999_999, using: &generator))
    }
}

public struct SessionKeys {
    public let tcpSend: SymmetricKey
    public let tcpReceive: SymmetricKey
    public let udpSend: SymmetricKey
    public let udpReceive: SymmetricKey
}

extension SymmetricKey {
    public var rawData: Data { withUnsafeBytes { Data($0) } }
}

func randomData(_ count: Int) -> Data {
    SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).rawData
}

// MARK: - Key derivation

enum Role { case phone, mac }

/// Everything both sides saw during the handshake. Every key and proof is bound to it, so a
/// message from one handshake can't be reused in another.
struct Transcript {
    let bytes: Data

    init(phoneId: String, macId: String, phoneKey: Data, macKey: Data, phoneNonce: Data, macNonce: Data) {
        var data = Data("couchpad-handshake-v2".utf8)
        for part in [Data(phoneId.utf8), Data(macId.utf8), phoneKey, macKey, phoneNonce, macNonce] {
            let length = UInt32(part.count)
            data.append(contentsOf: [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff),
                                     UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
            data.append(part)
        }
        bytes = data
    }
}

enum KDF {
    static func pairingKey(shared: SharedSecret, secret: Data, transcript: Transcript) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret,
                                       sharedInfo: Data("pair".utf8) + transcript.bytes,
                                       outputByteCount: 32)
    }

    static func sessionKeys(shared: SharedSecret, longTermKey: SymmetricKey, transcript: Transcript,
                            role: Role) -> SessionKeys {
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: longTermKey.rawData,
                                                      sharedInfo: Data("session".utf8) + transcript.bytes,
                                                      outputByteCount: 128).rawData
        func key(_ index: Int) -> SymmetricKey {
            SymmetricKey(data: material.subdata(in: material.startIndex + index * 32 ..< material.startIndex + (index + 1) * 32))
        }
        let phoneToMacTCP = key(0), macToPhoneTCP = key(1), phoneToMacUDP = key(2), macToPhoneUDP = key(3)
        switch role {
        case .phone:
            return SessionKeys(tcpSend: phoneToMacTCP, tcpReceive: macToPhoneTCP,
                               udpSend: phoneToMacUDP, udpReceive: macToPhoneUDP)
        case .mac:
            return SessionKeys(tcpSend: macToPhoneTCP, tcpReceive: phoneToMacTCP,
                               udpSend: macToPhoneUDP, udpReceive: phoneToMacUDP)
        }
    }

    static func proof(_ key: SymmetricKey, _ label: String, _ transcript: Transcript) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + transcript.bytes, using: key))
            .base64EncodedString()
    }

    static func verify(_ proof: String?, _ key: SymmetricKey, _ label: String, _ transcript: Transcript) -> Bool {
        guard let proof, let data = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(data, authenticating: Data(label.utf8) + transcript.bytes,
                                                      using: key)
    }
}

private func decodeKeyAndNonce(_ message: HandshakeMessage) throws -> (Curve25519.KeyAgreement.PublicKey, Data, Data) {
    guard let epk = message.epk.flatMap({ Data(base64Encoded: $0) }), epk.count == 32,
          let nonce = message.n.flatMap({ Data(base64Encoded: $0) }), nonce.count == 32 else {
        throw HandshakeError.malformed("missing key or nonce")
    }
    do {
        return (try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk), epk, nonce)
    } catch {
        throw HandshakeError.malformed("bad public key")
    }
}

// MARK: - iPhone side

public final class PhoneHandshake {
    public enum Outcome {
        /// Send `message`, then switch to the encrypted channel built from `keys`.
        case authenticated(message: HandshakeMessage, keys: SessionKeys)
        /// This iPhone and Mac don't share a pairing key (never paired, or one side forgot): pair.
        case needsPairing
    }

    public let phoneId: String
    public let phoneName: String
    public private(set) var macId: String?
    public private(set) var macName: String?

    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = randomData(32)
    private var shared: SharedSecret?
    private var transcript: Transcript?
    private var pairingKey: SymmetricKey?

    public init(phoneId: String, phoneName: String) {
        self.phoneId = phoneId
        self.phoneName = phoneName
    }

    public func hello() -> HandshakeMessage {
        HandshakeMessage(t: "hello", v: couchpadProtocolVersion, id: phoneId, name: phoneName,
                         epk: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
                         n: nonce.base64EncodedString())
    }

    /// `longTermKey` looks up the pairing key saved for a Mac id.
    public func receive(macHello message: HandshakeMessage,
                        longTermKey: (String) -> SymmetricKey?) throws -> Outcome {
        guard message.t == "hello_mac", let macId = message.id, !macId.isEmpty else {
            throw HandshakeError.malformed("expected hello_mac")
        }
        let (macKey, macKeyData, macNonce) = try decodeKeyAndNonce(message)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: macKey)
        let transcript = Transcript(phoneId: phoneId, macId: macId,
                                    phoneKey: ephemeral.publicKey.rawRepresentation, macKey: macKeyData,
                                    phoneNonce: nonce, macNonce: macNonce)
        self.macId = macId
        self.macName = message.name
        self.shared = shared
        self.transcript = transcript

        guard message.proof != nil, let key = longTermKey(macId) else { return .needsPairing }
        // The Mac proved it has our pairing key; anyone else can't produce this.
        guard KDF.verify(message.proof, key, "mac-auth", transcript) else { throw HandshakeError.notAuthentic }
        let reply = HandshakeMessage(t: "auth", proof: KDF.proof(key, "phone-auth", transcript))
        return .authenticated(message: reply,
                              keys: KDF.sessionKeys(shared: shared, longTermKey: key, transcript: transcript, role: .phone))
    }

    public func pairRequest(method: PairingMethod, secret: Data) throws -> HandshakeMessage {
        guard let shared, let transcript else { throw HandshakeError.malformed("pair before hello_mac") }
        let key = KDF.pairingKey(shared: shared, secret: secret, transcript: transcript)
        pairingKey = key
        return HandshakeMessage(t: "pair", method: method.rawValue, proof: KDF.proof(key, "phone-pair", transcript))
    }

    public func receive(paired message: HandshakeMessage) throws -> (longTermKey: SymmetricKey, keys: SessionKeys) {
        guard message.t == "paired", let shared, let transcript, let pairingKey,
              let box = message.box.flatMap({ Data(base64Encoded: $0) }) else {
            throw HandshakeError.malformed("expected paired")
        }
        guard KDF.verify(message.proof, pairingKey, "mac-pair", transcript) else { throw HandshakeError.notAuthentic }
        let raw = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: box), using: pairingKey,
                                      authenticating: transcript.bytes)
        guard raw.count == 32 else { throw HandshakeError.malformed("bad pairing key") }
        let longTermKey = SymmetricKey(data: raw)
        return (longTermKey,
                KDF.sessionKeys(shared: shared, longTermKey: longTermKey, transcript: transcript, role: .phone))
    }
}

// MARK: - Mac side

public final class MacHandshake {
    public let macId: String
    public let macName: String
    public private(set) var phoneId: String?
    public private(set) var phoneName: String?

    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = randomData(32)
    private var shared: SharedSecret?
    private var transcript: Transcript?
    private var knownKey: SymmetricKey?

    public init(macId: String, macName: String) {
        self.macId = macId
        self.macName = macName
    }

    /// Whether the phone that said hello is already paired.
    public var phoneIsKnown: Bool { knownKey != nil }

    public func receive(phoneHello message: HandshakeMessage,
                        longTermKey: (String) -> SymmetricKey?) throws -> HandshakeMessage {
        guard message.t == "hello" else { throw HandshakeError.malformed("expected hello") }
        guard message.v == couchpadProtocolVersion else {
            throw HandshakeError.pairingRejected("This version of Couchpad on your iPhone doesn't match the Mac. Update both apps.")
        }
        guard let phoneId = message.id, !phoneId.isEmpty, phoneId.count <= 128 else {
            throw HandshakeError.malformed("missing phone id")
        }
        let (phoneKey, phoneKeyData, phoneNonce) = try decodeKeyAndNonce(message)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: phoneKey)
        let transcript = Transcript(phoneId: phoneId, macId: macId, phoneKey: phoneKeyData,
                                    macKey: ephemeral.publicKey.rawRepresentation,
                                    phoneNonce: phoneNonce, macNonce: nonce)
        self.phoneId = phoneId
        self.phoneName = message.name.map { String($0.prefix(64)) }
        self.shared = shared
        self.transcript = transcript
        self.knownKey = longTermKey(phoneId)

        var reply = HandshakeMessage(t: "hello_mac", v: couchpadProtocolVersion, id: macId, name: macName,
                                     epk: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
                                     n: nonce.base64EncodedString())
        if let knownKey {
            reply.proof = KDF.proof(knownKey, "mac-auth", transcript)
        }
        return reply
    }

    public func receive(auth message: HandshakeMessage) throws -> SessionKeys {
        guard message.t == "auth", let shared, let transcript else { throw HandshakeError.malformed("expected auth") }
        guard let knownKey, KDF.verify(message.proof, knownKey, "phone-auth", transcript) else {
            throw HandshakeError.notAuthentic
        }
        return KDF.sessionKeys(shared: shared, longTermKey: knownKey, transcript: transcript, role: .mac)
    }

    /// `secret` returns the current secret for a pairing method, or nil when pairing isn't open.
    public func receive(pair message: HandshakeMessage, secret: (PairingMethod) -> Data?) throws
        -> (reply: HandshakeMessage, longTermKey: SymmetricKey, keys: SessionKeys) {
        guard message.t == "pair", let shared, let transcript,
              let method = message.method.flatMap(PairingMethod.init(rawValue:)) else {
            throw HandshakeError.malformed("expected pair")
        }
        guard let pairingSecret = secret(method) else {
            throw HandshakeError.pairingRejected("Pairing isn't open on the Mac. In Couchpad on your Mac, click “Pair iPhone”, then try again.")
        }
        let pairingKey = KDF.pairingKey(shared: shared, secret: pairingSecret, transcript: transcript)
        guard KDF.verify(message.proof, pairingKey, "phone-pair", transcript) else { throw HandshakeError.notAuthentic }

        let longTermKey = SymmetricKey(size: .bits256)
        let box = try ChaChaPoly.seal(longTermKey.rawData, using: pairingKey, authenticating: transcript.bytes).combined
        let reply = HandshakeMessage(t: "paired", proof: KDF.proof(pairingKey, "mac-pair", transcript),
                                     box: box.base64EncodedString())
        knownKey = longTermKey
        return (reply, longTermKey,
                KDF.sessionKeys(shared: shared, longTermKey: longTermKey, transcript: transcript, role: .mac))
    }
}

// MARK: - Encrypted channel

/// Seals and opens messages with ChaChaPoly. Each message carries a counter inside the
/// encryption: TCP requires exactly the next number (no replay, no reordering); UDP accepts
/// any number higher than the last one seen (packets may be lost, but never replayed).
public final class SecureChannel {
    public enum Ordering {
        case strict
        case increasing
    }

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let ordering: Ordering
    private var sendCounter: UInt64 = 0
    private var lastReceived: UInt64 = 0

    public init(sendKey: SymmetricKey, receiveKey: SymmetricKey, ordering: Ordering) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.ordering = ordering
    }

    public func seal(_ plaintext: Data) throws -> Data {
        sendCounter += 1
        var message = Data(count: 8)
        for i in 0..<8 {
            message[i] = UInt8(truncatingIfNeeded: sendCounter >> (56 - UInt64(i) * 8))
        }
        message.append(plaintext)
        return try ChaChaPoly.seal(message, using: sendKey).combined
    }

    public func open(_ sealed: Data) throws -> Data {
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: sealed)
        } catch {
            throw ChannelError.malformed
        }
        let message = try ChaChaPoly.open(box, using: receiveKey)
        guard message.count >= 8 else { throw ChannelError.malformed }
        let counter = message.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        switch ordering {
        case .strict:
            guard counter == lastReceived + 1 else { throw ChannelError.replayed }
        case .increasing:
            guard counter > lastReceived else { throw ChannelError.replayed }
        }
        lastReceived = counter
        return Data(message.dropFirst(8))
    }
}

// MARK: - Pairing link (QR code)

/// What the Mac's pairing QR code contains: couchpad://pair?v=2&id=<mac id>&name=<mac name>&s=<secret>
/// Scanning it with the iPhone camera opens Couchpad and pairs.
public struct PairingLink: Equatable {
    public var macId: String
    public var macName: String
    public var secret: Data

    public init(macId: String, macName: String, secret: Data) {
        self.macId = macId
        self.macName = macName
        self.secret = secret
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "couchpad"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(couchpadProtocolVersion)),
            URLQueryItem(name: "id", value: macId),
            URLQueryItem(name: "name", value: macName),
            URLQueryItem(name: "s", value: Base64URL.encode(secret)),
        ]
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "couchpad", url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard value("v") == String(couchpadProtocolVersion),
              let id = value("id"), !id.isEmpty,
              let secret = value("s").flatMap(Base64URL.decode), secret.count == 32 else { return nil }
        self.init(macId: id, macName: value("name") ?? "Mac", secret: secret)
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
