#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import RemoteCore

final class SecureSessionTests: XCTestCase {
    private let phoneId = "phone-1"
    private let macId = "mac-1"

    /// Runs hello → hello_mac. Returns the phone's outcome and both handshakes.
    private func hello(phoneKey: SymmetricKey?, macKey: SymmetricKey?)
        throws -> (PhoneHandshake, MacHandshake, PhoneHandshake.Outcome) {
        let phone = PhoneHandshake(phoneId: phoneId, phoneName: "Test iPhone")
        let mac = MacHandshake(macId: macId, macName: "Test Mac")
        let macHello = try mac.receive(phoneHello: roundTrip(phone.hello()), longTermKey: { id in
            id == self.phoneId ? macKey : nil
        })
        let outcome = try phone.receive(macHello: roundTrip(macHello), longTermKey: { id in
            id == self.macId ? phoneKey : nil
        })
        return (phone, mac, outcome)
    }

    /// Every message really goes through JSON, as on the wire.
    private func roundTrip(_ message: HandshakeMessage) throws -> HandshakeMessage {
        try JSONDecoder().decode(HandshakeMessage.self, from: JSONEncoder().encode(message))
    }

    private func channels(_ phone: SessionKeys, _ mac: SessionKeys) -> (SecureChannel, SecureChannel) {
        (SecureChannel(sendKey: phone.tcpSend, receiveKey: phone.tcpReceive, ordering: .strict),
         SecureChannel(sendKey: mac.tcpSend, receiveKey: mac.tcpReceive, ordering: .strict))
    }

    private func assertChannelsWork(_ phone: SessionKeys, _ mac: SessionKeys, file: StaticString = #filePath, line: UInt = #line) throws {
        let (phoneChannel, macChannel) = channels(phone, mac)
        let fromPhone = try macChannel.open(phoneChannel.seal(Data("click".utf8)))
        XCTAssertEqual(String(decoding: fromPhone, as: UTF8.self), "click", file: file, line: line)
        let fromMac = try phoneChannel.open(macChannel.seal(Data("auth_ok".utf8)))
        XCTAssertEqual(String(decoding: fromMac, as: UTF8.self), "auth_ok", file: file, line: line)
    }

    // MARK: Pairing

    func testPairingWithCodeThenReconnecting() throws {
        let code = PairingSecret.randomCode()
        let (phone, mac, outcome) = try hello(phoneKey: nil, macKey: nil)
        guard case .needsPairing = outcome else { return XCTFail("expected needsPairing") }

        let request = try phone.pairRequest(method: .code, secret: PairingSecret.fromCode(code))
        let result = try mac.receive(pair: roundTrip(request), secret: { method in
            method == .code ? PairingSecret.fromCode(code) : nil
        })
        let (phoneLongTerm, phoneKeys) = try phone.receive(paired: roundTrip(result.reply))
        XCTAssertEqual(phoneLongTerm.rawData, result.longTermKey.rawData)
        try assertChannelsWork(phoneKeys, result.keys)

        // Next connection: both sides know the key → authenticated without pairing.
        let (_, mac2, outcome2) = try hello(phoneKey: phoneLongTerm, macKey: result.longTermKey)
        guard case let .authenticated(auth, phoneKeys2) = outcome2 else { return XCTFail("expected authenticated") }
        let macKeys2 = try mac2.receive(auth: roundTrip(auth))
        try assertChannelsWork(phoneKeys2, macKeys2)

        // Each session uses different keys.
        XCTAssertNotEqual(phoneKeys.tcpSend.rawData, phoneKeys2.tcpSend.rawData)
    }

    func testPairingWithQRSecret() throws {
        let secret = PairingSecret.randomQRSecret()
        let (phone, mac, _) = try hello(phoneKey: nil, macKey: nil)
        let request = try phone.pairRequest(method: .qr, secret: secret)
        let result = try mac.receive(pair: request, secret: { $0 == .qr ? secret : nil })
        let (_, phoneKeys) = try phone.receive(paired: result.reply)
        try assertChannelsWork(phoneKeys, result.keys)
    }

    func testCodeFormattingIsIgnored() {
        XCTAssertEqual(PairingSecret.fromCode("123 456"), PairingSecret.fromCode("123456"))
        XCTAssertEqual(PairingSecret.fromCode("123-456"), PairingSecret.fromCode("123456"))
    }

    func testWrongCodeIsRejected() throws {
        let (phone, mac, _) = try hello(phoneKey: nil, macKey: nil)
        let request = try phone.pairRequest(method: .code, secret: PairingSecret.fromCode("111111"))
        XCTAssertThrowsError(try mac.receive(pair: request, secret: { _ in PairingSecret.fromCode("222222") })) {
            XCTAssertEqual($0 as? HandshakeError, .notAuthentic)
        }
    }

    func testPairingClosedIsRejected() throws {
        let (phone, mac, _) = try hello(phoneKey: nil, macKey: nil)
        let request = try phone.pairRequest(method: .code, secret: PairingSecret.fromCode("123456"))
        XCTAssertThrowsError(try mac.receive(pair: request, secret: { _ in nil })) { error in
            guard case .pairingRejected = error as? HandshakeError else { return XCTFail("\(error)") }
        }
    }

    func testForgedPairedReplyIsRejected() throws {
        let (phone, mac, _) = try hello(phoneKey: nil, macKey: nil)
        let request = try phone.pairRequest(method: .code, secret: PairingSecret.fromCode("123456"))
        var result = try mac.receive(pair: request, secret: { _ in PairingSecret.fromCode("123456") })
        result.reply.proof = Data(repeating: 0, count: 32).base64EncodedString()
        XCTAssertThrowsError(try phone.receive(paired: result.reply)) {
            XCTAssertEqual($0 as? HandshakeError, .notAuthentic)
        }
    }

    // MARK: Authentication

    func testUnknownPhoneMustPair() throws {
        let (_, mac, outcome) = try hello(phoneKey: SymmetricKey(size: .bits256), macKey: nil)
        guard case .needsPairing = outcome else { return XCTFail("expected needsPairing") }
        XCTAssertFalse(mac.phoneIsKnown)
    }

    func testStrangerCannotAuthenticate() throws {
        // A phone that sends an auth message with a made-up proof.
        let (_, mac, _) = try hello(phoneKey: nil, macKey: SymmetricKey(size: .bits256))
        let forged = HandshakeMessage(t: "auth", proof: Data(repeating: 1, count: 32).base64EncodedString())
        XCTAssertThrowsError(try mac.receive(auth: forged)) {
            XCTAssertEqual($0 as? HandshakeError, .notAuthentic)
        }
    }

    func testFakeMacIsDetected() throws {
        // The phone's key for this Mac id differs from the key the "Mac" uses.
        XCTAssertThrowsError(try hello(phoneKey: SymmetricKey(size: .bits256), macKey: SymmetricKey(size: .bits256))) {
            XCTAssertEqual($0 as? HandshakeError, .notAuthentic)
        }
    }

    func testWrongProtocolVersionIsRejected() throws {
        let phone = PhoneHandshake(phoneId: phoneId, phoneName: "Old iPhone")
        var hello = phone.hello()
        hello.v = 1
        XCTAssertThrowsError(try MacHandshake(macId: macId, macName: "Mac").receive(phoneHello: hello, longTermKey: { _ in nil }))
    }

    func testMalformedHelloIsRejected() {
        let mac = MacHandshake(macId: macId, macName: "Mac")
        let bad = HandshakeMessage(t: "hello", v: couchpadProtocolVersion, id: phoneId, epk: "AAAA", n: "AAAA")
        XCTAssertThrowsError(try mac.receive(phoneHello: bad, longTermKey: { _ in nil }))
    }

    // MARK: Channel

    func testChannelRejectsReplayAndReordering() throws {
        let key = SymmetricKey(size: .bits256)
        let other = SymmetricKey(size: .bits256)
        let sender = SecureChannel(sendKey: key, receiveKey: other, ordering: .strict)
        let receiver = SecureChannel(sendKey: other, receiveKey: key, ordering: .strict)
        let first = try sender.seal(Data("1".utf8))
        let second = try sender.seal(Data("2".utf8))
        XCTAssertThrowsError(try receiver.open(second)) { XCTAssertEqual($0 as? ChannelError, .replayed) }
        XCTAssertEqual(try receiver.open(first), Data("1".utf8))
        XCTAssertThrowsError(try receiver.open(first)) { XCTAssertEqual($0 as? ChannelError, .replayed) }
        XCTAssertEqual(try receiver.open(second), Data("2".utf8))
    }

    func testDatagramChannelAllowsLossButNotReplay() throws {
        let key = SymmetricKey(size: .bits256)
        let other = SymmetricKey(size: .bits256)
        let sender = SecureChannel(sendKey: key, receiveKey: other, ordering: .increasing)
        let receiver = SecureChannel(sendKey: other, receiveKey: key, ordering: .increasing)
        let packets = try (1...3).map { try sender.seal(Data([UInt8($0)])) }
        XCTAssertEqual(try receiver.open(packets[0]), Data([1]))
        XCTAssertEqual(try receiver.open(packets[2]), Data([3]))   // packet 2 lost: fine
        XCTAssertThrowsError(try receiver.open(packets[1]))          // arrives late: dropped
        XCTAssertThrowsError(try receiver.open(packets[2]))          // replay: dropped
    }

    func testTamperedMessageIsRejected() throws {
        let key = SymmetricKey(size: .bits256)
        let other = SymmetricKey(size: .bits256)
        let sender = SecureChannel(sendKey: key, receiveKey: other, ordering: .strict)
        let receiver = SecureChannel(sendKey: other, receiveKey: key, ordering: .strict)
        var sealed = try sender.seal(Data("hello".utf8))
        sealed[sealed.count - 20] ^= 0xFF
        XCTAssertThrowsError(try receiver.open(sealed))
    }

    // MARK: Pairing link

    func testPairingLinkRoundTrip() throws {
        let link = PairingLink(macId: "ABC-123", macName: "Katsu’s MacBook Pro", secret: PairingSecret.randomQRSecret())
        XCTAssertEqual(PairingLink(url: link.url), link)
        XCTAssertEqual(link.url.scheme, "couchpad")
    }

    func testPairingLinkRejectsGarbage() throws {
        XCTAssertNil(PairingLink(url: URL(string: "couchpad://pair?v=2&id=x&s=short")!))
        XCTAssertNil(PairingLink(url: URL(string: "https://example.com/pair")!))
        XCTAssertNil(PairingLink(url: URL(string: "couchpad://pair?v=1&id=x")!))
    }

    func testRemoteCommandOmitsEmptyFields() throws {
        let json = String(decoding: try JSONEncoder().encode(RemoteCommand(t: "click", b: "left")), as: UTF8.self)
        XCTAssertFalse(json.contains("dx"))
        XCTAssertTrue(json.contains("\"b\":\"left\""))
    }
}
