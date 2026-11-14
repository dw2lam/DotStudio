//  SignalKeychain.swift — where a web signal's API key lives: the macOS Keychain, and nowhere else
//  (never library.json, a bridge message, MCP output or a log). One generic password per signal:
//  service com.davidlam.DotStudio.signal, account = the signal's UUID.
//
//  Ad-hoc signing: the login keychain trusts the app that created an item by its code signature,
//  and an ad-hoc-signed update is a new signature — so after an update macOS may want to ask
//  before handing the key over. Background reads (the fetch scheduler) never let it ask
//  (kSecUseAuthenticationUIFail): they fail quietly, and Settings shows "Key needs re-entry"
//  (errSecAuthFailed / errSecInteractionNotAllowed). Saving from Settings (the user's own click)
//  replaces the item, so it belongs to this build again.
//
//  Self-test: DOTSTUDIO_KEYCHAIN_SELFTEST=1 (with DOTSTUDIO_STORE_DIR) adds, reads, updates and
//  deletes ONE item under a unique test service, checks the status mapping, prints and exits —
//  from the real app binary and its signature. It never touches any other item.

import Foundation
import Security

enum SignalKeychain {
    static let service = "com.davidlam.DotStudio.signal"

    /// What reading a key found.
    enum Lookup: Equatable {
        case found(String)
        case missing
        /// The item is there but this build may not read it without asking (an update re-signed
        /// the app): the user re-enters the key in Settings.
        case needsReentry
        case failed(OSStatus)
    }

    /// Statuses that mean "there, but not readable by this build without asking".
    static func needsReentry(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed || status == errSecUserCanceled
            || status == errSecNoAccessForItem
    }

    static func lookup(status: OSStatus, data: Data?) -> Lookup {
        switch status {
        case errSecSuccess:
            guard let data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return .missing }
            return .found(s)
        case errSecItemNotFound: return .missing
        case _ where needsReentry(status): return .needsReentry
        default: return .failed(status)
        }
    }

    private static func base(_ account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The key for a signal. `interactive` false (the scheduler): never shows a Keychain prompt.
    static func read(_ id: UUID, interactive: Bool = false, service: String = service) -> Lookup {
        read(account: id.uuidString, interactive: interactive, service: service)
    }

    static func read(account: String, interactive: Bool, service: String) -> Lookup {
        var q = base(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return lookup(status: status, data: out as? Data)
    }

    /// Is a key stored (without reading it)?
    static func has(_ id: UUID, service: String = service) -> Bool {
        var q = base(id.uuidString, service: service)
        q[kSecReturnAttributes as String] = true
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return status == errSecSuccess || needsReentry(status)
    }

    /// Store (or replace) a signal's key. The old item goes first, so the new one belongs to
    /// this build (see the header). Returns the OSStatus (errSecSuccess = stored).
    @discardableResult
    static func save(_ key: String, for id: UUID, service: String = service) -> OSStatus {
        save(key, account: id.uuidString, service: service)
    }

    @discardableResult
    static func save(_ key: String, account: String, service: String) -> OSStatus {
        SecItemDelete(base(account, service: service) as CFDictionary)
        var q = base(account, service: service)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrLabel as String] = "DotStudio signal key"
        q[kSecAttrDescription as String] = "API key for a DotStudio live data signal"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil)
    }

    @discardableResult
    static func delete(_ id: UUID, service: String = service) -> OSStatus {
        SecItemDelete(base(id.uuidString, service: service) as CFDictionary)
    }

    /// Keys of signals that no longer exist (deleted while the app was closed — dotstudio-mcp
    /// can't reach the Keychain). Reads attributes only, never a key.
    static func pruneOrphans(keep: Set<UUID>) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return }
        for item in items {
            guard let acct = item[kSecAttrAccount as String] as? String, let id = UUID(uuidString: acct), !keep.contains(id) else { continue }
            delete(id)
        }
    }

    // MARK: Self-test (DOTSTUDIO_KEYCHAIN_SELFTEST=1)

    static func runSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["DOTSTUDIO_KEYCHAIN_SELFTEST"] == "1" else { return }
        let svc = service + ".selftest-" + UUID().uuidString.prefix(8).lowercased()
        let acct = UUID().uuidString
        var fails = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ok   " : "  FAIL ") + what); if !ok { fails += 1 } }
        print("keychain self-test (service \(svc), one item, deleted after)")
        let secret = "test-\(UUID().uuidString)"
        let add = save(secret, account: acct, service: svc)
        check(add == errSecSuccess, "SecItemAdd → \(add)")
        check(read(account: acct, interactive: false, service: svc) == .found(secret), "SecItemCopyMatching (no UI) reads it back")
        let add2 = save(secret + "-2", account: acct, service: svc)
        check(add2 == errSecSuccess && read(account: acct, interactive: false, service: svc) == .found(secret + "-2"),
              "replacing it (delete + add) → \(add2)")
        let del = SecItemDelete(base(acct, service: svc) as CFDictionary)
        check(del == errSecSuccess, "SecItemDelete → \(del)")
        check(read(account: acct, interactive: false, service: svc) == .missing, "gone afterwards (errSecItemNotFound → missing)")
        check(lookup(status: errSecAuthFailed, data: nil) == .needsReentry, "errSecAuthFailed → needs re-entry")
        check(lookup(status: errSecInteractionNotAllowed, data: nil) == .needsReentry, "errSecInteractionNotAllowed → needs re-entry")
        check(lookup(status: errSecItemNotFound, data: nil) == .missing, "errSecItemNotFound → missing")
        check(SignalService.keyStatusText(.needsReentry) == "Key needs re-entry", "the UI says “Key needs re-entry”")
        print(fails == 0 ? "keychain self-test: PASS" : "keychain self-test: \(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
