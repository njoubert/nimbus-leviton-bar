// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import NimbusLevitonBar

/// An in-memory `CredentialStore` — what keeps every `DeviceStore` test away from the real
/// Keychain (whose session item belongs to the running app, and whose reads prompt).
final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    var login: Keychain.Login?
    var session: Keychain.Session?
    var readFailureHint = ""
    /// Set to make the next save throw (Keychain full/locked paths).
    var saveError: Error?
    /// Every mutating call, in order — for asserting a sign-out really deleted both items.
    private(set) var calls: [String] = []

    init(login: Keychain.Login? = nil, session: Keychain.Session? = nil) {
        self.login = login
        self.session = session
    }

    func loadLogin() -> Keychain.Login? { login }
    func saveLogin(_ l: Keychain.Login) throws {
        calls.append("saveLogin")
        if let e = saveError { throw e }
        login = l
    }
    func deleteLogin() { calls.append("deleteLogin"); login = nil }
    func loadSession() -> Keychain.Session? { session }
    func saveSession(_ s: Keychain.Session) throws {
        calls.append("saveSession")
        if let e = saveError { throw e }
        session = s
    }
    func deleteSession() { calls.append("deleteSession"); session = nil }
}
