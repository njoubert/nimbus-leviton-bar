// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NimbusUpdater

/// The command-line face of the client: the same Keychain login and the same requests as the
/// menu, minus the UI. The quickest way to check the data path against the real account.
enum CLI {
    enum Command {
        case login(email: String)
        case logout
        case print
        case set(device: String, value: String)
        case room(room: String, value: String)
        case watch
        case get(path: String)
        case put(path: String, json: String)
        case checkUpdate
        case preflight(app: String)
    }

    static func run(_ cmd: Command) -> Int32 {
        let client = LevitonClient()
        do {
            switch cmd {
            case .login(let email):
                // MYLEVITON_PASSWORD in the environment skips the prompt (scripts, tests).
                let password = ProcessInfo.processInfo.environment["MYLEVITON_PASSWORD"]
                    ?? readPassword("My Leviton password for \(email): ")
                guard let password, !password.isEmpty else {
                    fputs("no password given\n", stderr); return 2
                }
                let s = try block { try await client.login(email: email, password: password) }
                try Keychain.saveLogin(.init(email: email, password: password))
                try Keychain.saveSession(s)
                Swift.print("signed in as user \(s.userId); login and session saved to the Keychain")
                if let e = s.expiry { Swift.print("session expires \(e)") }

            case .logout:
                if let s = Keychain.loadSession() { block { await client.logout(s) } }
                Keychain.deleteSession()
                Keychain.deleteLogin()
                Swift.print("signed out; Keychain entries removed")

            case .print:
                let s = try session(client)
                for r in try block({ try await client.residences(s) }) {
                    Swift.print("\(r.name)  [residence \(r.id)]")
                    let ds = try block { try await client.devices(s, residenceId: r.id) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    let rooms = try block { try await client.rooms(s, residenceId: r.id) }
                    let res = Residence(id: r.id, name: r.name, rooms: rooms, devices: ds)
                    if ds.isEmpty { Swift.print("    (no devices)") }
                    for room in res.displayRooms {
                        let inRoom = res.displayDevices(in: room)
                        Swift.print("  \(room.name)  [room \(room.id), \(room.power ? "ON" : "off"), \(inRoom.count) devices]")
                        for d in inRoom { Swift.print("    " + describe(d)) }
                    }
                    let rest = res.unassigned
                    if !rest.isEmpty { Swift.print("  (no room)"); for d in rest { Swift.print("    " + describe(d)) } }
                }

            case .set(let which, let value):
                let s = try session(client)
                let all = try block { () async throws -> [Device] in
                    var out: [Device] = []
                    for r in try await client.residences(s) { out += try await client.devices(s, residenceId: r.id) }
                    return out
                }
                guard let d = all.first(where: { $0.id == which || $0.name.caseInsensitiveCompare(which) == .orderedSame }) else {
                    fputs("no device named or numbered \(which); have: \(all.map(\.name).joined(separator: ", "))\n", stderr)
                    return 1
                }
                let fields: LevitonClient.DeviceFields
                switch value.lowercased() {
                case "on": fields = .init(power: true)
                case "off": fields = .init(power: false)
                default:
                    guard let n = Int(value.replacingOccurrences(of: "%", with: "")), (0...100).contains(n) else {
                        fputs("value must be on, off, or 0–100\n", stderr); return 2
                    }
                    guard d.canSetLevel else { fputs("\(d.name) (\(d.model)) has no level to set\n", stderr); return 1 }
                    if n == 0 {
                        fields = .init(power: false)
                    } else if d.power {
                        fields = .init(brightness: max(n, d.minLevel))
                    } else if d.comesOnAtPreset {
                        // Off, with a preset of its own: On first, wait for the device to come
                        // up and report that preset, then the level — a combined write loses to
                        // the report. Same two-step as `DeviceStore.setBrightness`, which says why.
                        _ = try block { try await client.update(s, deviceId: d.id, fields: .init(power: true)) }
                        try block { try await Task.sleep(for: DeviceStore.onSettle) }
                        fields = .init(brightness: max(n, d.minLevel))
                    } else {
                        fields = .init(power: true, brightness: max(n, d.minLevel))
                    }
                }
                let echo = try block { try await client.update(s, deviceId: d.id, fields: fields) }
                Swift.print("\(d.name): power=\(echo.power.map { $0 ? "ON" : "OFF" } ?? "?") brightness=\(echo.brightness.map(String.init) ?? "?")")

            case .room(let which, let value):
                // My Leviton's own room switch, for checking what the server does with it.
                let s = try session(client)
                let residences = try block { try await client.residences(s) }
                var found: (Residence, Room)?
                for r in residences {
                    let rooms = try block { try await client.rooms(s, residenceId: r.id) }
                    let ds = try block { try await client.devices(s, residenceId: r.id) }
                    if let room = rooms.first(where: { $0.id == which || $0.name.caseInsensitiveCompare(which) == .orderedSame }) {
                        found = (Residence(id: r.id, name: r.name, rooms: rooms, devices: ds), room)
                        break
                    }
                }
                guard let (res, room) = found else { fputs("no room named or numbered \(which)\n", stderr); return 1 }
                guard let on = ["on": true, "off": false][value.lowercased()] else {
                    fputs("value must be on or off\n", stderr); return 2
                }
                Swift.print("\(room.name)  [room \(room.id)] before:")
                for d in res.displayDevices(in: room) { Swift.print("    " + describe(d)) }
                try block { try await client.setRoomPower(s, roomId: room.id, on: on) }
                Thread.sleep(forTimeInterval: 2)
                let after = try block { try await client.devices(s, residenceId: res.id) }
                Swift.print("after turn\(on ? "On" : "Off"):")
                for d in after.filter({ $0.roomId == room.id }).sorted(by: { $0.name < $1.name }) {
                    Swift.print("    " + describe(d))
                }

            case .get(let path):
                // Raw GET, pretty-printed: for poking at endpoints the app does not use yet.
                let s = try session(client)
                let json = try block { try await client.rawGet(s, path) }
                let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                Swift.print(String(decoding: data, as: UTF8.self))

            case .put(let path, let json):
                // Raw PUT: a JSON object on the command line, the server's reply back.
                let s = try session(client)
                guard let data = json.data(using: .utf8),
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    fputs("--put needs a JSON object, e.g. '{\"includeInRoomOnOff\":true}'\n", stderr); return 2
                }
                let reply = try block { try await client.rawPut(s, path, body: body) }
                let out = try JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
                Swift.print(String(decoding: out, as: UTF8.self))

            case .checkUpdate:
                // The updater's data path, without the app around it: the feed, the parse and
                // the comparison. Installing needs the real bundle, so that is not offered here.
                let current = Updates.runningVersion ?? Updates.installedVersion
                guard let current else {
                    fputs("no version to compare against: \(Updates.appName) is not installed\n", stderr); return 1
                }
                let config = Updates.config(currentVersion: current)
                let where_ = Updates.runningVersion != nil ? "this bundle" : "the installed copy"
                Swift.print("current: \(current)  (\(where_))")
                let found = try block { try await Release.fetchLatest(config) }
                guard let release = found else {
                    Swift.print("latest:  none the updater can read"); return 0
                }
                Swift.print("latest:  \(release.version)  [\(release.tag)]")
                if let asset = release.asset {
                    Swift.print("asset:   \(asset.name)  (\(asset.size) bytes)")
                } else {
                    Swift.print("asset:   none named \(config.assetPrefix)\(release.version.text).zip — invisible to the updater")
                }
                Swift.print(release.version > current
                    ? (release.asset != nil ? "→ an update is available" : "→ newer, but nothing installable is published")
                    : "→ up to date")

            case .preflight(let path):
                // What must stay true for auto-update to keep working, checked against a built
                // bundle. `build.sh release` runs this before it pushes anything.
                // The version comes from the bundle being checked — this is about *that* build,
                // not whatever happens to be installed or running.
                let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
                let info = (try? Data(contentsOf: plist)).flatMap {
                    try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                } ?? nil
                guard let short = info?["CFBundleShortVersionString"] as? String,
                      let version = SemanticVersion(short) else {
                    fputs("\(path) has no readable CFBundleShortVersionString\n", stderr); return 1
                }
                let report = try block {
                    await Preflight.run(app: URL(fileURLWithPath: path),
                                        config: Updates.config(currentVersion: version),
                                        releaseVersion: version)
                }
                for check in report.checks {
                    Swift.print("\(check.ok ? "ok  " : "FAIL") \(check.name): \(check.detail)")
                }
                guard report.passed else {
                    fputs("\nthis build would break auto-update for people who already have the app\n", stderr)
                    return 1
                }
                Swift.print("\npreflight passed")

            case .watch:
                let s = try session(client)
                let all = try block { () async throws -> [Device] in
                    var out: [Device] = []
                    for r in try await client.residences(s) { out += try await client.devices(s, residenceId: r.id) }
                    return out
                }
                let names = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
                let rt = LevitonRealtime(session: s, deviceIds: all.map(\.id))
                rt.verbose = true
                rt.onUpdate = { id, f in
                    Swift.print("\(names[id] ?? id): \(f)")
                }
                rt.start()
                Swift.print("watching \(all.count) devices — Ctrl-C to stop")
                RunLoop.main.run()
            }
            return 0
        } catch {
            fputs("error: \(DeviceStore.describe(error))\n", stderr)
            return 1
        }
    }

    /// The saved session, or a fresh one from the saved password. Tells the user what to do
    /// when there is neither.
    private static func session(_ client: LevitonClient) throws -> Keychain.Session {
        if let s = Keychain.loadSession(), s.isFresh { return s }
        guard let login = Keychain.loadLogin() else {
            throw LevitonClient.Error.message("not signed in — run with --login EMAIL first")
        }
        let s = try block { try await client.login(email: login.email, password: login.password) }
        try? Keychain.saveSession(s)
        return s
    }

    static func describe(_ d: Device) -> String {
        let state = !d.connected ? "offline" : d.power ? "ON " : "off"
        let level = d.canSetLevel ? String(format: " %3d%% (%d–%d)", d.brightness, d.minLevel, d.maxLevel) : ""
        // The flag the server ignores on room On/Off — dumped so a change of heart is visible.
        let preset = d.comesOnAtPreset ? " preset=\(d.presetLevel.map(String.init) ?? "?")" : ""
        let room = d.includeInRoomOnOff ? "" : " includeInRoomOnOff=false"
        return "\(state)\(level.padding(toLength: 15, withPad: " ", startingAt: 0))  \(d.name)  [\(d.kind.rawValue) \(d.model) \(d.serial) id=\(d.id)\(preset)\(room)]"
    }

    /// Run an async call to completion from synchronous top-level code.
    @discardableResult
    static func block<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Swift.Error>?
        Task.detached {
            result = await Result { try await body() }
            sem.signal()
        }
        sem.wait()
        return try result!.get()
    }

    static func block<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        try! block { () async throws -> T in await body() }
    }

    private static func readPassword(_ prompt: String) -> String? {
        guard let raw = getpass(prompt) else { return nil }
        return String(cString: raw)
    }
}

extension Result where Failure == Swift.Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
