// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The verbs. Each one is a whole answer to a question the plan asks, printed rather than
/// returned — this is a debugging instrument, not a library.
enum Commands {

    /// LG's key for OLED Pixel Brightness. **Not** `brightness`, which is the black-level lift
    /// and is not what anybody means by "brightness"; getting these two the wrong way round
    /// looks exactly like a broken API.
    static let backlight = "backlight"
    static let pictureCategory = "picture"
    /// Keys worth reading every time: the control we want, the one it is confused with, the
    /// mode that can lock both, and the setting known to override them silently.
    ///
    /// **Every key here must exist on the set.** One unknown key fails the *whole* request
    /// with `500 Application error` — and so does omitting `keys` to ask for the category
    /// wholesale, which is the obvious way to go looking for the others. Verified 2026-08-25:
    /// `ai_Brightness` and `energySavingModified` each 500 on their own.
    static let pictureKeys = ["backlight", "brightness", "contrast", "color", "pictureMode",
                              "energySaving"]

    // MARK: - Dispatch

    static func run(_ arguments: [String]) async throws -> Int32 {
        var args = arguments
        // Before the verb or after it, both read naturally; parse it out of the whole list.
        let verbose = args.removeFlag("--verbose") || args.removeFlag("-v")
        guard let verb = args.first else { usage(); return 2 }
        args.removeFirst()

        switch verb {
        case "discover": return try discover(args)
        case "pair": return try await pair(args, verbose: verbose)
        case "forget": KeyStore.delete(); success("forgotten: \(KeyStore.url.path)"); return 0
        case "info": return try await info(verbose: verbose)
        case "get": return try await get(args, verbose: verbose)
        case "set": return try await set(args, verbose: verbose)
        case "luna": return try await luna(args, verbose: verbose)
        case "probe": return try await probe(args, verbose: verbose)
        case "watch": return try await watch(verbose: verbose)
        case "raw": return try await raw(args, verbose: verbose)
        case "-h", "--help", "help": usage(); return 0
        default: error("unknown command: \(verb)"); usage(); return 2
        }
    }

    // MARK: - discover

    static func discover(_ args: [String]) throws -> Int32 {
        var args = args
        let all = args.removeFlag("--all")
        let mx = args.removeValue("--mx").flatMap(Int.init) ?? 1
        let timeout = args.removeValue("--timeout").flatMap(Double.init) ?? (all ? 3 : 2)

        header("SSDP M-SEARCH  ST: \(Discovery.searchTarget)  MX: \(mx)")
        let found = try Discovery.search(mx: mx, timeout: timeout, stopOnFirst: !all)
        guard !found.isEmpty else {
            warn("no LG television answered in \(timeout) s")
            info("a set in standby does not answer SSDP, and is not controllable either —")
            info("\"not discovered\" and \"not reachable\" are one state, not two")
            return 1
        }
        for reply in found {
            success("\(reply.address)  (\(Int(reply.elapsed * 1000)) ms)")
            info("UDN      \(reply.udn ?? "—")")
            info("server   \(reply.server ?? "—")")
            if let location = reply.location {
                info("location \(location)")
                if let description = try? Discovery.describe(location: location) {
                    info("name     \(description.friendlyName ?? "—")")
                    info("model    \(description.modelName ?? "—")")
                    info("wired    \(description.wiredMac ?? "—")")
                    info("wifi     \(description.wifiMac ?? "—")")
                }
            }
        }
        return 0
    }

    // MARK: - pair

    static func pair(_ args: [String], verbose: Bool) async throws -> Int32 {
        var args = args
        let force = args.removeFlag("--force")
        let host = args.removeValue("--host")
        let only = args.removeValue("--manifest").flatMap(SSAPManifest.Variant.init(rawValue:))
        let variants = only.map { [$0] } ?? SSAPManifest.Variant.allCases

        if !force, let existing = KeyStore.load() {
            success("already paired with \(existing.friendlyName ?? existing.udn) (\(existing.manifestVariant ?? "?") manifest)")
            info("key \(SSAPSession.fingerprint(existing.clientKey)) in \(KeyStore.url.path)")
            info("`pair --force` re-pairs, which puts a fresh prompt on the television")
            return 0
        }

        let (address, description) = try locate(host: host)

        // Each variant gets a fresh socket: a refused registration is answered with an error
        // and the television is entitled to hang up after it.
        var key: String?
        var accepted: SSAPManifest.Variant?
        var certificate: String?
        for variant in variants {
            let session = SSAPSession()
            session.verbose = verbose
            defer { session.disconnect() }
            try await session.connect(host: address)
            certificate = session.certificateFingerprint
            if variant == variants.first {
                success("connected  wss://\(address):3001")
                if let fingerprint = session.certificateFingerprint {
                    info("certificate \(session.certificateSubject ?? "?")  sha256 \(fingerprint)")
                }
            }
            header("Registering: \(variant.rawValue) — \(variant.description)")
            do {
                key = try await session.register(clientKey: nil, variant: variant) { style in
                    Commands.header("Look at the television and accept the \(style.lowercased()) prompt with the remote")
                    Commands.info("(waiting up to 3 minutes; nothing else arrives until you do)")
                }
                accepted = variant
            } catch {
                warn(error.localizedDescription)
                continue
            }
            break
        }

        guard let key, let accepted else {
            fail("every manifest was refused — pairing is not possible as things stand")
            return 1
        }
        success("accepted with the `\(accepted.rawValue)` manifest")

        var store = KeyStore(udn: description.udn ?? "", clientKey: key,
                             manifestVariant: accepted.rawValue,
                             friendlyName: description.friendlyName, modelName: description.modelName,
                             wiredMac: description.wiredMac, wifiMac: description.wifiMac,
                             lastAddress: address, certificateFingerprint: certificate)
        if store.udn.isEmpty { store.udn = "unknown" }
        try store.save()
        success("paired — client-key \(SSAPSession.fingerprint(key)) saved to \(KeyStore.url.path)")
        info("that file is 0600 and git-ignored; it is a credential, treat it as one")
        return 0
    }

    // MARK: - info

    static func info(verbose: Bool) async throws -> Int32 {
        try await connected(verbose: verbose) { session in
            // The plan lists the firmware version as an open question: this answers it.
            header("Software")
            await report(session, "ssap://com.webos.service.update/getCurrentSWInformation")
            header("System")
            await report(session, "ssap://system/getSystemInfo")
            header("Picture settings")
            let settings = try await readPicture(session)
            printSettings(settings)
            appraise(settings)
        }
    }

    // MARK: - get / set / luna / raw

    static func get(_ args: [String], verbose: Bool) async throws -> Int32 {
        var args = args
        let category = args.removeValue("--category") ?? pictureCategory
        let keys = args.isEmpty ? pictureKeys : args
        return try await connected(verbose: verbose) { session in
            let payload = try await session.request("ssap://settings/getSystemSettings",
                                                    payload: ["category": category, "keys": keys])
            printSettings(payload["settings"] as? [String: Any] ?? [:])
        }
    }

    static func set(_ args: [String], verbose: Bool) async throws -> Int32 {
        var args = args
        let category = args.removeValue("--category") ?? pictureCategory
        let numeric = args.removeFlag("--numeric")
        guard args.count == 2 else { error("usage: lgtv set KEY VALUE"); return 2 }
        let (key, raw) = (args[0], args[1])
        let value: Any = numeric ? (Int(raw) ?? 0) : raw
        return try await connected(verbose: verbose) { session in
            let payload = try await session.request(
                "ssap://settings/setSystemSettings",
                payload: ["category": category, "settings": [key: value]])
            verdict(payload)
            try await settleAndVerify(session, key: key, expected: raw)
        }
    }

    static func luna(_ args: [String], verbose: Bool) async throws -> Int32 {
        var args = args
        let category = args.removeValue("--category") ?? pictureCategory
        guard args.count == 2 else { error("usage: lgtv luna KEY VALUE"); return 2 }
        let (key, raw) = (args[0], args[1])
        return try await connected(verbose: verbose) { session in
            try await lunaWrite(session, category: category, key: key, value: raw)
            try await settleAndVerify(session, key: key, expected: raw)
        }
    }

    static func raw(_ args: [String], verbose: Bool) async throws -> Int32 {
        guard let uri = args.first else { error("usage: lgtv raw ssap://… [JSON]"); return 2 }
        var payload: [String: Any]?
        if args.count > 1 {
            guard let data = args[1].data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                error("the payload is not JSON: \(args[1])"); return 2
            }
            payload = parsed
        }
        return try await connected(verbose: verbose) { session in
            let reply = try await session.request(uri, payload: payload)
            print(pretty(reply))
        }
    }

    // MARK: - watch

    static func watch(verbose: Bool) async throws -> Int32 {
        try await connected(verbose: verbose, hold: true) { session in
            let (_, first) = try await session.subscribe(
                "ssap://settings/getSystemSettings",
                payload: ["category": pictureCategory, "keys": pictureKeys])
            header("Subscribed to picture settings — change brightness on the TV to see a frame")
            printSettings(first["settings"] as? [String: Any] ?? [:])
            session.onEvent = { _, payload in
                let stamp = ISO8601DateFormatter().string(from: Date())
                print("\n[\(stamp)]")
                printSettings(payload["settings"] as? [String: Any] ?? [:])
            }
            // Held open by `hold`; ^C ends it.
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
    }

    // MARK: - probe: the go/no-go

    /// Phase 0's whole question: **does this set honour the native `settings/setSystemSettings`
    /// for `backlight`, or does it still need the luna alert bridge?**
    ///
    /// An echo is not proof — the same trap as Leviton's `presetLevel`, and here Energy Saving
    /// and OLED Care are known to accept a write and quietly reassert their own value. So each
    /// path is judged only by a read-back after it has had time to settle, and again later to
    /// catch a value that comes back a second time.
    static func probe(_ args: [String], verbose: Bool) async throws -> Int32 {
        var args = args
        let target = args.removeValue("--to").flatMap(Int.init)
        let settle = args.removeValue("--settle").flatMap(Double.init) ?? 2

        return try await connected(verbose: verbose) { session in
            header("Before")
            let before = try await readPicture(session)
            printSettings(before)
            appraise(before)

            guard let original = intValue(before[backlight]) else {
                fail("the TV did not report a `\(backlight)` at all — nothing to write")
                return
            }
            // Far enough to be unambiguous in a read-back, and restored either way.
            let wanted = target ?? (original > 40 ? original - 25 : original + 25)
            guard wanted != original else { fail("target equals the current value; pick another --to"); return }

            var winner: String?
            header("Native  ssap://settings/setSystemSettings  \(backlight) \(original) → \(wanted)")
            if try await attemptNative(session, value: wanted, settle: settle) { winner = "native" }

            if winner == nil {
                header("Luna bridge  createAlert → onClose → luna://com.webos.settingsservice/setSystemSettings")
                info("a privilege hack, and what BetterDisplay uses; unconfirmed past webOS 26")
                try await lunaWrite(session, category: pictureCategory, key: backlight, value: "\(wanted)")
                if try await verify(session, key: backlight, expected: wanted, settle: settle) { winner = "luna" }
            }

            header("Restoring \(backlight) to \(original)")
            if winner == "luna" {
                try await lunaWrite(session, category: pictureCategory, key: backlight, value: "\(original)")
            } else {
                _ = try? await session.request("ssap://settings/setSystemSettings",
                                               payload: ["category": pictureCategory,
                                                         "settings": [backlight: "\(original)"]])
            }
            try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            let after = try await readPicture(session)
            if intValue(after[backlight]) == original {
                success("restored to \(original)")
            } else {
                warn("NOT restored — \(backlight) reads \(display(after[backlight])), was \(original)")
            }

            header("Verdict")
            switch winner {
            case "native":
                success("the native endpoint works — Phase 0 passes, the plan is live")
            case "luna":
                warn("only the luna bridge works — the native endpoint is not available here")
                info("the plan's build-vs-buy gate says: use BetterDisplay instead")
            default:
                fail("neither path moved `\(backlight)` — stop, and use BetterDisplay")
                info("check the traps first: Energy Saving off, and a picture mode that is not")
                info("Filmmaker or Dolby Vision, both of which lock the control")
            }
        }
    }

    /// The native write, tried as a string and then as a number — the settings service echoes
    /// values back as strings, but that is not proof it wants them that way.
    private static func attemptNative(_ session: SSAPSession, value: Int, settle: Double) async throws -> Bool {
        for encoded in [("string", "\(value)" as Any), ("number", value as Any)] {
            let reply: [String: Any]
            do {
                reply = try await session.request(
                    "ssap://settings/setSystemSettings",
                    payload: ["category": pictureCategory, "settings": [backlight: encoded.1]])
            } catch {
                // Never swallow this. `401 insufficient permissions` is the whole answer to
                // Phase 0, and reporting it as "no answer" hides it behind a shrug.
                warn("as a \(encoded.0): \(error.localizedDescription)")
                continue
            }
            info("as a \(encoded.0): returnValue \(reply["returnValue"] ?? "—")")
            if try await verify(session, key: backlight, expected: value, settle: settle) { return true }
        }
        return false
    }

    /// The alert bridge: an alert whose `onClose` action is a privileged luna call, created and
    /// immediately closed. The alert flashes on screen for the moment it exists.
    private static func lunaWrite(_ session: SSAPSession, category: String, key: String, value: String) async throws {
        let action: [String: Any] = [
            "uri": "luna://com.webos.settingsservice/setSystemSettings",
            "params": ["category": category, "settings": [key: value]],
        ]
        let created = try await session.request("ssap://system.notifications/createAlert", payload: [
            "message": " ",
            "buttons": [["label": "", "onClick": action["uri"] as Any, "params": action["params"] as Any]],
            "onclose": action,
            "onfail": action,
        ])
        guard let alertId = created["alertId"] as? String else {
            warn("createAlert returned no alertId: \(pretty(created))")
            return
        }
        _ = try await session.request("ssap://system.notifications/closeAlert", payload: ["alertId": alertId])
        info("alert \(alertId) created and closed")
    }

    /// Read back after a settle, then once more — a value that is going to be overridden is
    /// overridden about a second later, not instantly.
    private static func verify(_ session: SSAPSession, key: String, expected: Int, settle: Double) async throws -> Bool {
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        let first = intValue(try await readPicture(session)[key])
        try await Task.sleep(nanoseconds: UInt64(3 * 1_000_000_000))
        let second = intValue(try await readPicture(session)[key])
        info("read back after \(Int(settle)) s: \(first.map(String.init) ?? "—"), after \(Int(settle) + 3) s: \(second.map(String.init) ?? "—")")
        if first == expected && second == expected { success("\(key) is \(expected) and stayed there"); return true }
        if first == expected { warn("\(key) reached \(expected) then drifted to \(second.map(String.init) ?? "—") — something is overriding it"); return false }
        warn("\(key) never reached \(expected)")
        return false
    }

    private static func settleAndVerify(_ session: SSAPSession, key: String, expected: String) async throws {
        guard let wanted = Int(expected) else { return }
        _ = try await verify(session, key: key, expected: wanted, settle: 2)
    }

    // MARK: - Plumbing

    /// Discover, connect, register with the stored key. Every verb but `discover` and `pair`
    /// needs exactly this.
    @discardableResult
    private static func connected(verbose: Bool, hold: Bool = false,
                                  _ body: (SSAPSession) async throws -> Void) async throws -> Int32 {
        guard let store = KeyStore.load() else {
            error("not paired — run `lgtv pair` first")
            return 1
        }
        let (address, _) = try locate(host: nil, expecting: store.udn)
        let session = SSAPSession()
        session.verbose = verbose
        defer { if !hold { session.disconnect() } }
        try await session.connect(host: address)
        if let fingerprint = session.certificateFingerprint, let pinned = store.certificateFingerprint,
           fingerprint != pinned {
            warn("certificate changed since pairing: \(pinned) → \(fingerprint)")
        }
        // With a key in hand this answers straight away and puts nothing on screen — provided
        // it is offered under the manifest the set accepted when we paired.
        let variant = store.manifestVariant.flatMap(SSAPManifest.Variant.init(rawValue:)) ?? .unsigned
        _ = try await session.register(clientKey: store.clientKey, variant: variant, promptTimeout: 20)
        success("session up — \(store.friendlyName ?? store.udn) at \(address)")
        try await body(session)
        return 0
    }

    /// Discovery first, always. It costs ~200 ms and verifies the identity *before* a
    /// credential is offered to whatever now holds that address.
    private static func locate(host: String?, expecting udn: String? = nil) throws -> (String, Discovery.Description) {
        if let host {
            let description = (try? Discovery.describe(location: "http://\(host):1196/")) ?? Discovery.Description()
            return (host, description)
        }
        let found = try Discovery.search(mx: 1, timeout: 3, stopOnFirst: udn == nil)
        let match = udn.flatMap { wanted in found.first { $0.udn == wanted } } ?? found.first
        guard let match else {
            throw Discovery.Failure.notFound("no LG television answered SSDP — a set in standby stays silent")
        }
        if let udn, match.udn != udn {
            throw Discovery.Failure.notFound("found \(match.udn ?? "?") at \(match.address), expected \(udn)")
        }
        let description = match.location.flatMap { try? Discovery.describe(location: $0) } ?? Discovery.Description()
        return (match.address, description)
    }

    private static func readPicture(_ session: SSAPSession) async throws -> [String: Any] {
        let payload = try await session.request("ssap://settings/getSystemSettings",
                                                payload: ["category": pictureCategory, "keys": pictureKeys])
        return payload["settings"] as? [String: Any] ?? [:]
    }

    /// The two traps that make a working write look broken.
    private static func appraise(_ settings: [String: Any]) {
        if let mode = settings["pictureMode"] as? String {
            let locked = ["filmMaker", "dolby", "hdrFilmMaker", "technicolor"]
            if locked.contains(where: { mode.lowercased().contains($0.lowercased()) }) {
                warn("picture mode is `\(mode)` — Filmmaker and Dolby Vision lock these controls")
            }
        }
        if let saving = settings["energySaving"] as? String, saving != "off" {
            warn("Energy Saving is `\(saving)` — it accepts a backlight write and then reasserts its own")
        }
    }

    private static func report(_ session: SSAPSession, _ uri: String) async {
        do { print(pretty(try await session.request(uri))) } catch { warn("\(uri): \(error.localizedDescription)") }
    }

    private static func verdict(_ payload: [String: Any]) {
        if payload["returnValue"] as? Bool == true { success("accepted (returnValue true) — which is not proof") } else { warn("returnValue \(payload["returnValue"] ?? "missing"): \(pretty(payload))") }
    }

    // MARK: - Values and output

    /// The settings service reports numbers as strings on some firmwares and as numbers on
    /// others; nothing should depend on which.
    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func display(_ any: Any?) -> String {
        guard let any else { return "—" }
        return "\(any)"
    }

    private static func printSettings(_ settings: [String: Any]) {
        guard !settings.isEmpty else { info("(no settings returned)"); return }
        for key in settings.keys.sorted() { info("\(key.padding(toLength: max(22, key.count), withPad: " ", startingAt: 0)) \(display(settings[key]))") }
    }

    private static func pretty(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return "\(object)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    // Output in the house style: the glyph on the headline, detail indented under it, and
    // anything that reports trouble on stderr so it survives a pipe.
    static func header(_ text: String) { print("\n\u{001B}[1m\(text)\u{001B}[0m") }
    static func success(_ text: String) { print("✓ \(text)") }
    static func info(_ text: String) { print("  \(text)") }
    static func warn(_ text: String) { FileHandle.standardError.write(Data("⚠ \(text)\n".utf8)) }
    static func fail(_ text: String) { FileHandle.standardError.write(Data("✗ \(text)\n".utf8)) }
    static func error(_ text: String) { FileHandle.standardError.write(Data("✗ \(text)\n".utf8)) }

    static func usage() {
        print("""
            lgtv — a scratch SSAP client for the LG webOS brightness spike (docs/lg-tv-plan.md)

              discover [--all] [--mx N] [--timeout S]   one SSDP M-SEARCH for LG televisions
              pair [--host IP] [--force] [--manifest V]  register; the TV shows a prompt
                                                        V: full | unsigned | minimal | hoisted | own
              forget                                    delete the stored client-key
              info                                      firmware, system info, picture settings
              get [KEY…] [--category C]                 read settings
              set KEY VALUE [--numeric]                 native settings/setSystemSettings
              luna KEY VALUE                            the createAlert/onClose privilege bridge
              probe [--to N] [--settle S]               the Phase 0 go/no-go, restores what it changed
              watch                                     subscribe and print every change
              raw ssap://URI [JSON]                     anything else

            --verbose prints every frame (the client-key is redacted, always).
            The pairing credential lives in ./\(KeyStore.fileName) (0600, git-ignored);
            $LGTV_KEY_FILE moves it.
            """)
    }
}

// MARK: - Tiny argument helpers

extension Array where Element == String {
    mutating func removeFlag(_ name: String) -> Bool {
        guard let index = firstIndex(of: name) else { return false }
        remove(at: index)
        return true
    }

    mutating func removeValue(_ name: String) -> String? {
        guard let index = firstIndex(of: name), index + 1 < count else { return nil }
        let value = self[index + 1]
        removeSubrange(index...(index + 1))
        return value
    }
}
