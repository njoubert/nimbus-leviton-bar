// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where the spike keeps what pairing produced.
///
/// A file, not the Keychain, for the same reason `DevCredentials` exists: a non-interactive
/// shell cannot read a Keychain item, it gets `errSecInteractionNotAllowed` and no prompt. The
/// app will use the Keychain; a debugging tool that only works from a foreground terminal
/// would be useless for the job it is for.
///
/// The client-key is the one secret here — whoever holds it can drive the television without
/// the remote — so the file is 0600 and git-ignored. The UDN, MACs and last address are not
/// secret; they live alongside because the file is the natural place for them and splitting
/// them across two stores would buy nothing in a spike.
struct KeyStore: Codable {
    /// The stable identity to match a discovery response against. Never the address.
    var udn: String
    var clientKey: String
    /// Which manifest the television actually accepted. webOS 25 refuses the canonical signed
    /// one outright, so a reconnect that guessed would be refused too — and the refusal looks
    /// identical to a revoked key.
    var manifestVariant: String?
    var friendlyName: String?
    var modelName: String?
    /// For Wake-on-LAN later; an L2 broadcast needs no IP at all.
    var wiredMac: String?
    var wifiMac: String?
    /// A hint only, and the plan says not even to use it — discovery is ~200 ms and always
    /// right, whereas a cached address can point at whatever DHCP handed it to next.
    var lastAddress: String?
    /// The leaf certificate the TV showed when we paired. The app pins this; the spike records
    /// it so we can see whether it is stable enough to pin.
    var certificateFingerprint: String?

    static let fileName = ".lgtv-key.json"

    static var url: URL {
        if let override = ProcessInfo.processInfo.environment["LGTV_KEY_FILE"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(fileName)
    }

    static func load() -> KeyStore? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeyStore.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let url = KeyStore.url
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
