// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// The My Leviton account (email + password) and the session token it yields, kept as
/// generic-password items in the login keychain. Nothing secret ever lands in UserDefaults.
///
/// Dev builds are ad-hoc signed, and macOS ties a keychain item's access list to the code
/// signature that created it — so after a rebuild the next read prompts "NimbusLevitonBar
/// wants to use your confidential information". "Always Allow" quiets it until the next
/// rebuild. The installed (consistently signed) copy never asks twice.
enum Keychain {
    static let service = "com.njoubert.nimbuslevitonbar"
    /// The `account` attribute of each item: the sign-in and the token are separate items so
    /// the token can be dropped (sign out, 401) without touching the password.
    static let loginAccount = "my.leviton.com"
    static let tokenAccount = "my.leviton.com session"

    struct Login: Equatable {
        var email: String
        var password: String
    }

    /// What `Person/login` hands back and every later request needs.
    struct Session: Codable, Equatable {
        var token: String
        var userId: String
        var created: Date
        var ttl: TimeInterval?

        var expiry: Date? { ttl.map { created.addingTimeInterval($0) } }
        /// Treat the session as stale before the server would, so a long-running app re-logs
        /// in on its own schedule rather than discovering a 401 mid-click. The margin is half
        /// the ttl, capped at a day. My Leviton issues ttl 5184000 (60 days, measured
        /// 2026-08-24), so the day is what applies in practice; the fraction only matters if
        /// the server ever hands back a short ttl, where a flat day would make the session
        /// stale the moment it was issued — a login per app launch and per CLI command, and
        /// repeated logins are what lock an account.
        var isFresh: Bool {
            guard let e = expiry, let ttl else { return true }
            return Date() < e.addingTimeInterval(-min(86_400, ttl / 2))
        }
    }

    // MARK: Login

    static func loadLogin() -> Login? {
        guard let (account, data) = read(loginAccount, wantAccountFromItem: true),
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        return Login(email: account, password: password)
    }

    static func saveLogin(_ login: Login) throws {
        // The email goes in the item's label/comment (the account attribute is our fixed key,
        // so one sign-in replaces the previous one instead of piling up).
        try write(loginAccount, data: Data(login.password.utf8), label: "My Leviton (\(login.email))", comment: login.email)
    }

    static func deleteLogin() { delete(loginAccount) }

    // MARK: Session

    static func loadSession() -> Session? {
        guard let (_, data) = read(tokenAccount, wantAccountFromItem: false) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func saveSession(_ s: Session) throws {
        try write(tokenAccount, data: try JSONEncoder().encode(s), label: "My Leviton session", comment: s.userId)
    }

    static func deleteSession() { delete(tokenAccount) }

    // MARK: Generic-password plumbing

    struct Error: Swift.Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "keychain error \(status)"
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Why the last read came back empty, when it was not simply "no such item". A
    /// non-interactive process (a coding agent, ssh, a script) cannot be shown the "allow
    /// access" panel, so `SecItemCopyMatching` fails instead of prompting and the CLI would
    /// otherwise report a perfectly good Keychain as "not signed in".
    private(set) static var lastReadFailure: OSStatus?

    /// A clause to append to "not signed in" when the Keychain, not the absence of an item,
    /// is what went wrong.
    static var readFailureHint: String {
        guard let s = lastReadFailure else { return "" }
        return " (the Keychain refused this process: \(Error(status: s)) — a non-interactive"
            + " shell cannot be prompted for access; put the login in a .leviton file instead)"
    }

    /// Returns the item's data, plus (for the login) the email we stashed in the comment.
    private static func read(_ account: String, wantAccountFromItem: Bool) -> (String, Data)? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status != errSecSuccess && status != errSecItemNotFound { lastReadFailure = status }
        guard status == errSecSuccess, let dict = out as? [String: Any],
              let data = dict[kSecValueData as String] as? Data else { return nil }
        let email = (dict[kSecAttrComment as String] as? String) ?? ""
        return (email, data)
    }

    private static func write(_ account: String, data: Data, label: String, comment: String) throws {
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrLabel as String: label,
                                    kSecAttrComment as String: comment]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            attrs.forEach { add[$0.key] = $0.value }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error(status: status) }
    }

    private static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
