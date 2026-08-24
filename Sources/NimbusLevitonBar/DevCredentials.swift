// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A file-backed stand-in for the Keychain, **for the CLI only** — the app never looks at it.
///
/// The Keychain is where this project's secrets live, and reading an item's data needs a
/// process macOS can put a prompt in front of. A non-interactive shell (a coding agent, ssh,
/// a script run from an editor) gets a silent failure instead of that prompt, so every CLI
/// command reports "not signed in" while the items sit right there. When a `.leviton` file
/// exists the CLI takes the login from it, caches the session token beside it, and leaves the
/// Keychain alone.
///
/// The file is `KEY=value` lines, like `.signing`:
///
///     MYLEVITON_EMAIL=you@example.com
///     MYLEVITON_PASSWORD=hunter2
///
/// `MYLEVITON_EMAIL` / `MYLEVITON_PASSWORD` in the environment win over the file, and on their
/// own are enough (the session is then cached in the working directory).
/// `MYLEVITON_ENV_FILE` names a file somewhere other than `./.leviton`.
enum DevCredentials {
    static let fileName = ".leviton"
    static let sessionFileName = ".leviton-session.json"

    /// A resolved credentials file: the login it holds, and where its session token is cached.
    struct Store {
        var login: Keychain.Login
        /// Where the login came from, for messages ("`.leviton`" or "the environment").
        var source: String
        var sessionFile: URL

        // MARK: The cached session

        func loadSession() -> Keychain.Session? {
            guard let data = try? Data(contentsOf: sessionFile) else { return nil }
            return try? JSONDecoder().decode(Keychain.Session.self, from: data)
        }

        /// Written 0600 — it is a bearer token for the account.
        func saveSession(_ s: Keychain.Session) {
            guard let data = try? JSONEncoder().encode(s) else { return }
            FileManager.default.createFile(atPath: sessionFile.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }

        func deleteSession() { try? FileManager.default.removeItem(at: sessionFile) }
    }

    /// The credentials the CLI should use instead of the Keychain, if any.
    static func load(warnings: (String) -> Void = { fputs("warning: \($0)\n", stderr) }) -> Store? {
        let env = ProcessInfo.processInfo.environment
        let path = env["MYLEVITON_ENV_FILE"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(fileName)

        var values: [String: String] = [:]
        var source = "the environment"
        if let text = try? String(contentsOf: path, encoding: .utf8) {
            values = parse(text)
            source = path.lastPathComponent
            if let mode = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.posixPermissions] as? NSNumber,
               mode.intValue & 0o077 != 0 {
                warnings("\(path.path) is readable by others — chmod 600 it")
            }
        } else if let named = env["MYLEVITON_ENV_FILE"] {
            warnings("MYLEVITON_ENV_FILE points at \(named), which cannot be read — falling back to the Keychain")
        }

        // The environment wins over the file, and suffices on its own.
        let email = env["MYLEVITON_EMAIL"] ?? values["MYLEVITON_EMAIL"]
        let password = env["MYLEVITON_PASSWORD"] ?? values["MYLEVITON_PASSWORD"]
        guard let email, let password, !email.isEmpty, !password.isEmpty else {
            if !values.isEmpty {
                warnings("\(path.path) has no MYLEVITON_EMAIL/MYLEVITON_PASSWORD — falling back to the Keychain")
            }
            return nil
        }
        return Store(login: .init(email: email, password: password), source: source,
                     sessionFile: path.deletingLastPathComponent().appendingPathComponent(sessionFileName))
    }

    /// `KEY=value` lines: `#` comments, an optional `export`, and optional quotes around the
    /// value (so the same file can be `source`d by a shell).
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            for q in ["\"", "'"] where value.count >= 2 && value.hasPrefix(q) && value.hasSuffix(q) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}
