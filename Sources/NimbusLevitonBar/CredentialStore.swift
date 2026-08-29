// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where `DeviceStore` keeps the login and the session. The real store is the Keychain
/// (`Keychain.swift`); the tests substitute an in-memory one, which is what guarantees a
/// test can never read or overwrite the owner's real Keychain items — a fake token written
/// over the real session item would sign the running app out.
protocol CredentialStore {
    func loadLogin() -> Keychain.Login?
    func saveLogin(_ login: Keychain.Login) throws
    func deleteLogin()
    func loadSession() -> Keychain.Session?
    func saveSession(_ s: Keychain.Session) throws
    func deleteSession()
    /// Appended to "not signed in" when the store itself, not an absent item, failed a read.
    var readFailureHint: String { get }
}

/// The Keychain, behind the protocol. Stateless — every call forwards to the enum.
struct KeychainCredentialStore: CredentialStore {
    func loadLogin() -> Keychain.Login? { Keychain.loadLogin() }
    func saveLogin(_ login: Keychain.Login) throws { try Keychain.saveLogin(login) }
    func deleteLogin() { Keychain.deleteLogin() }
    func loadSession() -> Keychain.Session? { Keychain.loadSession() }
    func saveSession(_ s: Keychain.Session) throws { try Keychain.saveSession(s) }
    func deleteSession() { Keychain.deleteSession() }
    var readFailureHint: String { Keychain.readFailureHint }
}
