import CryptoKit
import Foundation
import Security
import UIKit

/// This iPhone's identity and its pairing keys for Macs.
/// Keys live in the Keychain (this device only, never synced or backed up);
/// the list of paired Mac names is kept in UserDefaults (not secret).
enum PhonePairings {
    struct PairedMac: Identifiable, Hashable {
        let id: String      // Mac id
        let name: String
    }

    private static let service = "app.couchpad.pairing"
    private static let namesKey = "pairedMacNames"

    /// A random id for this iPhone, created once.
    static var phoneId: String {
        if let data = read(account: "phone-id"), let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString
        write(account: "phone-id", data: Data(id.utf8))
        return id
    }

    /// The name shown on the Mac ("Paired iPhones"). Can be changed in Settings.
    static var phoneName: String {
        let custom = UserDefaults.standard.string(forKey: "deviceName")?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? UIDevice.current.name : custom
    }

    static var all: [PairedMac] {
        let names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        return names.map { PairedMac(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func isPaired(_ macId: String?) -> Bool {
        guard let macId else { return false }
        return key(for: macId) != nil
    }

    static func key(for macId: String) -> SymmetricKey? {
        read(account: "mac-" + macId).map { SymmetricKey(data: $0) }
    }

    static func save(macId: String, macName: String, key: SymmetricKey) {
        write(account: "mac-" + macId, data: key.rawData)
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names[macId] = macName
        UserDefaults.standard.set(names, forKey: namesKey)
    }

    static func remove(_ macId: String) {
        delete(account: "mac-" + macId)
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names[macId] = nil
        UserDefaults.standard.set(names, forKey: namesKey)
    }

    // MARK: Keychain

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(account: String, data: Data) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
