import Foundation
import Security
import CryptoKit
import Darwin

/// Persists ALL saved ssh host passwords as a single blob, in two places kept in sync:
///
/// - **A (primary): one Keychain item** — a `[user@host: password]` JSON under ONE generic-password
///   entry. One item (not one per host) means a re-signed / reinstalled app triggers at most ONE
///   Keychain authorization prompt instead of N. The value never touches UserDefaults or logs.
/// - **C (backup): a machine-bound encrypted file** — AES-GCM, key derived from this Mac's hardware
///   UUID (`gethostuuid`). Does NOT depend on the app's code signature, so it survives ad-hoc
///   re-signing / reinstalls without any prompt; the file is useless if copied to another machine.
///
/// On every write we update BOTH. On read we try the Keychain first; if that *fails* (not merely
/// empty — e.g. the signature changed and the user denied the prompt) the caller can fall back to
/// the backup.
enum SSHPasswordStore {
    private static let service = "com.tfa.ssh"
    private static let allAccount = "__all__.v1" // single combined entry (was one item per host)

    // MARK: A — Keychain (single item)

    /// Returns the saved map, `[:]` if nothing was ever stored, or `nil` if the read FAILED
    /// (auth denied / interaction not allowed / other error) — that's the signal to offer the backup.
    static func loadKeychain() -> [String: String]? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data,
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return map
        case errSecItemNotFound:
            return [:]            // never stored → not a failure
        default:
            return nil            // genuine read failure → caller may fall back to backup
        }
    }

    static func saveKeychain(_ map: [String: String]) {
        SecItemDelete(baseQuery() as CFDictionary) // upsert
        guard !map.isEmpty, let data = try? JSONEncoder().encode(map) else { return }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: allAccount]
    }

    /// One-time migration from the OLD layout (≤ v0.10.0: one Keychain item per `user@host`) to the
    /// single combined item. Reads each host's legacy entry, then removes the legacy entries. Returns
    /// whatever was recovered (empty if none / reads denied). Caller persists the result.
    static func migrateLegacy(hosts: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for h in hosts where !h.isEmpty && h != allAccount {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: h,
                                        kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne]
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, let pw = String(data: data, encoding: .utf8) {
                map[h] = pw
            }
            query.removeValue(forKey: kSecReturnData as String)
            query.removeValue(forKey: kSecMatchLimit as String)
            SecItemDelete(query as CFDictionary) // clean up the legacy per-host entry
        }
        return map
    }

    // MARK: C — machine-bound encrypted backup

    static func loadBackup() -> [String: String]? {
        guard let blob = try? Data(contentsOf: backupURL),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let data = try? AES.GCM.open(box, using: machineKey()),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return map
    }

    static func saveBackup(_ map: [String: String]) {
        if map.isEmpty { try? FileManager.default.removeItem(at: backupURL); return }
        guard let data = try? JSONEncoder().encode(map),
              let sealed = try? AES.GCM.seal(data, using: machineKey()).combined else { return }
        try? sealed.write(to: backupURL, options: [.atomic, .completeFileProtection])
    }

    /// Update BOTH stores. Call after any change so A and C never drift.
    static func persist(_ map: [String: String]) {
        saveKeychain(map)
        saveBackup(map)
    }

    private static var backupURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("TFA", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ssh-passwords.enc")
    }

    /// A 256-bit key bound to this Mac (hardware UUID + a fixed salt). Independent of the app's code
    /// signature, so the backup decrypts across re-signs / reinstalls — but not on another machine.
    private static func machineKey() -> SymmetricKey {
        var uuid = [UInt8](repeating: 0, count: 16)
        var timeout = timespec(tv_sec: 2, tv_nsec: 0)
        _ = gethostuuid(&uuid, &timeout)
        var hasher = SHA256()
        hasher.update(data: Data(uuid))
        hasher.update(data: Data("com.tfa.ssh.backup.v1".utf8))
        return SymmetricKey(data: hasher.finalize())
    }
}
