import CryptoKit
import Foundation
#if canImport(RemoteCore)
import RemoteCore
#endif

struct PairedPhone: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var key: Data
    var pairedAt: Date
    var lastSeen: Date?
}

/// This Mac's identity and the iPhones paired with it, saved in
/// ~/Library/Application Support/Couchpad/pairings.json (inside the app's sandbox container in
/// the App Store build) with permissions 0600. Main queue only.
final class PairingStore {
    static let shared = PairingStore()

    private(set) var macId: String
    private(set) var phones: [PairedPhone]
    /// Called after any change.
    var onChange: (() -> Void)?

    private let file: URL

    private struct Stored: Codable {
        var macId: String
        var phones: [PairedPhone]
    }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("Couchpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent("pairings.json")

        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            macId = stored.macId
            phones = stored.phones
        } else {
            macId = UUID().uuidString
            phones = []
            save()
        }
    }

    func key(for phoneId: String) -> SymmetricKey? {
        phones.first(where: { $0.id == phoneId }).map { SymmetricKey(data: $0.key) }
    }

    func add(phoneId: String, name: String, key: SymmetricKey) {
        phones.removeAll { $0.id == phoneId }
        phones.append(PairedPhone(id: phoneId, name: name, key: key.rawData, pairedAt: Date(), lastSeen: Date()))
        save()
    }

    func remove(_ phoneId: String) {
        phones.removeAll { $0.id == phoneId }
        save()
    }

    func removeAll() {
        phones.removeAll()
        save()
    }

    func markSeen(_ phoneId: String, name: String) {
        guard let index = phones.firstIndex(where: { $0.id == phoneId }) else { return }
        phones[index].lastSeen = Date()
        phones[index].name = name
        save()
    }

    private func save() {
        let stored = Stored(macId: macId, phones: phones)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        onChange?()
    }
}

/// An open "Pair iPhone" window: a QR secret and a 6-digit code, valid for a few minutes and a
/// few wrong tries. Only someone who can see the Mac's screen can pair.
final class PairingWindow {
    static let duration: TimeInterval = 180
    static let maxAttempts = 5

    let code = PairingSecret.randomCode()
    let qrSecret = PairingSecret.randomQRSecret()
    let expires = Date().addingTimeInterval(PairingWindow.duration)
    private(set) var failedAttempts = 0

    var isOpen: Bool { Date() < expires && failedAttempts < Self.maxAttempts }

    func secret(for method: PairingMethod) -> Data? {
        guard isOpen else { return nil }
        switch method {
        case .qr: return qrSecret
        case .code: return PairingSecret.fromCode(code)
        }
    }

    func recordFailure() {
        failedAttempts += 1
    }

    func link(macId: String, macName: String) -> PairingLink {
        PairingLink(macId: macId, macName: macName, secret: qrSecret)
    }
}
