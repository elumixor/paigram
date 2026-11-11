import Foundation
import Security

/// The watch's copy of the box's address and token and of the last glance. Kept in the keychain rather than
/// in files: the watch app and its complications are signed with one keychain access group as their only
/// (so default) group, which lets both read it without an app group. The glance files under
/// `PaiGlanceStore.local` remember the usage alerts.
///
/// The Pai glance sources (`PaiGlance.swift`, `PaiGlanceSource.swift`, `PaiGlanceStore.swift`) are copied
/// next to this file from `submodules/PaiGlance/Sources` by the watch build (`prebuilt_watchos_build.sh`).
enum PaiVault {
    private static let service = "pai.glance"

    static var config: PaiGlanceConfig? {
        get { read("config").flatMap { try? JSONDecoder().decode(PaiGlanceConfig.self, from: $0) } }
        set { write("config", newValue.flatMap { try? JSONEncoder().encode($0) }) }
    }

    static var glance: PaiGlance? {
        get { read("glance").flatMap(PaiGlanceStore.decode) }
        set { write("glance", newValue.flatMap(PaiGlanceStore.encode)) }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ account: String, _ data: Data?) {
        let query = query(account)
        guard let data else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
