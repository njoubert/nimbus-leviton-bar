// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ResidenceInfo: Equatable, Sendable {
    let id: String
    let name: String
}

/// The REST side of My Leviton (`https://my.leviton.com/api`, a LoopBack 3 app). Plain
/// URLSession, JSON in and out, no dependencies. Every call takes the session explicitly;
/// the store decides when to log in again.
///
/// Wire facts this relies on (see CLAUDE.md for where they come from):
///   POST Person/login                        {email,password[,code]} → {id: token, ttl, created, userId}
///   GET  Person/{userId}/residentialPermissions   → [{residentialAccountId?, residenceId?}]
///   GET  ResidentialAccounts/{id}/residences → [{id, name}]   (not primaryResidenceId — see residences())
///   GET  Residences/{id}/iotSwitches         → [IotSwitch]
///   GET  Residences/{id}/residentialRooms    → [{id, name, power, …}]
///   PUT  IotSwitches/{id}  {"power":"ON"|"OFF","brightness":n} → the full IotSwitch
///   POST ResidentialRooms/turnOn?id=N  (and turnOff)   the room switch, server-side
///   POST Person/logout
/// The token goes in `Authorization: <token>` — bare, no "Bearer". Ids are integers in the
/// JSON; they are carried as strings here.
final class LevitonClient: Sendable {

    static let base = URL(string: "https://my.leviton.com/api/")!

    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case unauthorized                 // token rejected or expired: log in again
        case badCredentials               // email/password refused
        case lockedOut                    // "Too many failed attempts": wait before retrying
        case twoFactorRequired            // account uses 2FA: log in again with a code
        case badTwoFactorCode
        case server(Int, String)          // any other HTTP failure: status + server message
        case malformed(String)            // unexpected JSON shape
        case message(String)

        var description: String {
            switch self {
            case .unauthorized: return "session expired"
            case .badCredentials: return "email or password not accepted"
            case .lockedOut: return "too many failed sign-ins — My Leviton has locked the account for a while"
            case .twoFactorRequired: return "two-factor code required"
            case .badTwoFactorCode: return "two-factor code not accepted"
            case .server(let code, let msg): return "my.leviton.com: \(code) \(msg)"
            case .malformed(let what): return "unexpected reply from my.leviton.com (\(what))"
            case .message(let m): return m
            }
        }
    }

    /// A partial IotSwitch: what a PUT sends, what a PUT echoes back, what the realtime feed
    /// pushes. Only the keys we act on.
    struct DeviceFields: Sendable, Equatable, CustomStringConvertible {
        var power: Bool? = nil
        var brightness: Int? = nil
        var connected: Bool? = nil
        var name: String? = nil

        var body: [String: Any] {
            var b: [String: Any] = [:]
            if let p = power { b["power"] = p ? "ON" : "OFF" }
            if let l = brightness { b["brightness"] = l }
            return b
        }

        init(power: Bool? = nil, brightness: Int? = nil, connected: Bool? = nil, name: String? = nil) {
            self.power = power; self.brightness = brightness; self.connected = connected; self.name = name
        }

        /// Pick our keys out of an IotSwitch-shaped dictionary (full or partial).
        init(json: [String: Any]) {
            if let p = json["power"] as? String { power = p.uppercased() == "ON" }
            if let b = json["brightness"] as? Int { brightness = b }
            else if let b = json["brightness"] as? Double { brightness = Int(b) }
            if let c = json["connected"] as? Bool { connected = c }
            if let n = json["name"] as? String { name = n }
        }

        var description: String {
            var parts: [String] = []
            if let p = power { parts.append(p ? "ON" : "OFF") }
            if let b = brightness { parts.append("\(b)%") }
            if let c = connected { parts.append(c ? "connected" : "disconnected") }
            if let n = name { parts.append("name=\(n)") }
            return parts.isEmpty ? "(no change)" : parts.joined(separator: " ")
        }
    }

    private let session: URLSession

    init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "NimbusLevitonBar"]
        session = URLSession(configuration: c)
    }

    // MARK: Auth

    func login(email: String, password: String, code: String? = nil) async throws -> Keychain.Session {
        var body: [String: Any] = ["email": email, "password": password, "loggedInVia": "myLeviton", "rememberMe": true]
        if let code { body["code"] = code }
        let json: Any
        do {
            json = try await request("POST", "Person/login", query: ["include": "user"], token: nil, body: body)
        } catch Error.unauthorized {
            throw Error.badCredentials
        }
        guard let d = json as? [String: Any], let token = d["id"] as? String, let userId = Self.idString(d["userId"]) else {
            throw Error.malformed("login")
        }
        let created = (d["created"] as? String).flatMap(Self.iso.date(from:)) ?? Date()
        let ttl = (d["ttl"] as? Double) ?? (d["ttl"] as? Int).map(Double.init)
        return Keychain.Session(token: token, userId: userId, created: created, ttl: ttl)
    }

    /// Best effort; a dead token is as good as logged out.
    func logout(_ s: Keychain.Session) async {
        _ = try? await request("POST", "Person/logout", token: s.token, body: [:])
    }

    // MARK: Reading

    /// Every residence this account can see. Permissions carry either a residential account
    /// (the owner's case) or a single residence (a shared one). An account's residences come
    /// from `ResidentialAccounts/{id}/residences`; its `primaryResidenceId` is *not* reliably
    /// one of them (newer accounts 401 on it), so it is only tried as an extra, quietly.
    func residences(_ s: Keychain.Session) async throws -> [ResidenceInfo] {
        let perms = try await array("Person/\(s.userId)/residentialPermissions", s)
        var out: [ResidenceInfo] = []
        var seen = Set<String>()
        func add(_ r: ResidenceInfo) { if seen.insert(r.id).inserted { out.append(r) } }

        for p in perms {
            if let acct = Self.idString(p["residentialAccountId"]) {
                for r in try await array("ResidentialAccounts/\(acct)/residences", s) {
                    if let id = Self.idString(r["id"]) { add(ResidenceInfo(id: id, name: (r["name"] as? String) ?? "Home")) }
                }
                if let a = try? await object("ResidentialAccounts/\(acct)", s),
                   let pid = Self.idString(a["primaryResidenceId"]), !seen.contains(pid),
                   let r = try? await object("Residences/\(pid)", s) {
                    add(ResidenceInfo(id: pid, name: (r["name"] as? String) ?? "Home"))
                }
            } else if let rid = Self.idString(p["residenceId"]) {
                let r = (try? await object("Residences/\(rid)", s)) ?? [:]
                add(ResidenceInfo(id: rid, name: (r["name"] as? String) ?? "Shared home"))
            }
        }
        return out
    }

    func devices(_ s: Keychain.Session, residenceId: String) async throws -> [Device] {
        try await array("Residences/\(residenceId)/iotSwitches", s).compactMap { Self.device(from: $0, residenceId: residenceId) }
    }

    /// Rooms as the API lists them, which is by id. The order the user *sees* is a
    /// preference on the person — see `roomOrders`.
    func rooms(_ s: Keychain.Session, residenceId: String) async throws -> [Room] {
        try await array("Residences/\(residenceId)/residentialRooms", s).compactMap { r in
            guard let id = Self.idString(r["id"]) else { return nil }
            return Room(id: id, name: (r["name"] as? String) ?? "Room \(id)",
                        power: ((r["power"] as? String) ?? "").uppercased() == "ON")
        }
    }

    /// The room order the user dragged into place in the My Leviton app, per residence.
    ///
    /// It is **not** on the room: `ResidentialRoom.position` is null on every room, a dead
    /// field like `includeInRoomOnOff`. My Leviton keeps it on the person, as one
    /// `Preference` row per residence — `key` `sorting$residence:{id}$rooms`, `value` a JSON
    /// array of room ids — so two people sharing a residence each get their own order. The
    /// web bundle writes it from `saveRoomSortOrder` and reads it with `sortItemsByKeyOrder`,
    /// whose lookup misses (rooms added since the last drag) sort last, and which falls back
    /// to sorting by id when the row is absent — the order `rooms` already returns.
    ///
    /// One request covers every residence, so this is fetched once per refresh.
    func roomOrders(_ s: Keychain.Session) async throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for p in try await array("Person/\(s.userId)/preferences", s) {
            guard let key = p["key"] as? String,
                  key.hasPrefix(Self.roomOrderPrefix), key.hasSuffix(Self.roomOrderSuffix),
                  let value = p["value"] as? String else { continue }
            let rid = String(key.dropFirst(Self.roomOrderPrefix.count).dropLast(Self.roomOrderSuffix.count))
            guard !rid.isEmpty, let ids = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [Any] else { continue }
            // The app writes these under DECORA_SMART; if some other client ever wrote the
            // same key, the one the app itself reads wins.
            if out[rid] == nil || (p["appId"] as? String) == "DECORA_SMART" {
                out[rid] = ids.compactMap(Self.idString)
            }
        }
        return out
    }

    private static let roomOrderPrefix = "sorting$residence:"
    private static let roomOrderSuffix = "$rooms"

    func device(_ s: Keychain.Session, id: String) async throws -> Device {
        let j = try await object("IotSwitches/\(id)", s)
        guard let d = Self.device(from: j, residenceId: Self.idString(j["residenceId"]) ?? "") else { throw Error.malformed("IotSwitch") }
        return d
    }

    // MARK: Writing

    /// Partial update; the reply is the whole record, so the caller gets the server's view.
    func update(_ s: Keychain.Session, deviceId: String, fields: DeviceFields) async throws -> DeviceFields {
        let json = try await request("PUT", "IotSwitches/\(deviceId)", token: s.token, body: fields.body)
        guard let d = json as? [String: Any] else { throw Error.malformed("IotSwitch") }
        return DeviceFields(json: d)
    }

    /// Any GET, parsed but otherwise untouched (`--get`).
    func rawGet(_ s: Keychain.Session, _ path: String) async throws -> Any {
        try await request("GET", path, token: s.token)
    }

    /// Any PUT with a JSON object body (`--put`) — for the record fields the app has no
    /// business setting on its own, such as `includeInRoomOnOff`.
    func rawPut(_ s: Keychain.Session, _ path: String, body: [String: Any]) async throws -> Any {
        try await request("PUT", path, token: s.token, body: body)
    }

    /// The room's own On/Off, as the My Leviton app does it: the server switches every device
    /// in the room. The per-device `includeInRoomOnOff` flag has no effect on it (see
    /// `DeviceStore.toggleRoom`); it is still parsed, so `--print` can show when it changes.
    func setRoomPower(_ s: Keychain.Session, roomId: String, on: Bool) async throws {
        _ = try await request("POST", on ? "ResidentialRooms/turnOn" : "ResidentialRooms/turnOff",
                              query: ["id": roomId], token: s.token, body: [:])
    }

    // MARK: Parsing

    static func device(from j: [String: Any], residenceId: String) -> Device? {
        guard let id = idString(j["id"]) else { return nil }
        if (j["deleted"] as? Bool) == true { return nil }
        let f = DeviceFields(json: j)
        return Device(id: id,
                      residenceId: idString(j["residenceId"]) ?? residenceId,
                      roomId: idString(j["residentialRoomId"]),
                      name: f.name ?? "Switch \(id)",
                      model: (j["model"] as? String) ?? "",
                      serial: (j["serial"] as? String) ?? "",
                      power: f.power ?? false,
                      brightness: f.brightness ?? 0,
                      minLevel: (j["minLevel"] as? Int) ?? 0,
                      maxLevel: (j["maxLevel"] as? Int) ?? 100,
                      canSetLevel: (j["canSetLevel"] as? Bool) ?? false,
                      connected: f.connected ?? true,
                      includeInRoomOnOff: (j["includeInRoomOnOff"] as? Bool) ?? false,
                      presetLevel: j["presetLevel"] as? Int)
    }

    /// Ids arrive as integers (occasionally strings); normalise to a string.
    static func idString(_ v: Any?) -> String? {
        switch v {
        case let i as Int: return String(i)
        case let d as Double: return String(Int(d))
        case let s as String: return s.isEmpty ? nil : s
        default: return nil
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    // MARK: HTTP

    private func array(_ path: String, _ s: Keychain.Session) async throws -> [[String: Any]] {
        let json = try await request("GET", path, token: s.token)
        guard let a = json as? [[String: Any]] else { throw Error.malformed(path) }
        return a
    }

    private func object(_ path: String, _ s: Keychain.Session) async throws -> [String: Any] {
        let json = try await request("GET", path, token: s.token)
        guard let d = json as? [String: Any] else { throw Error.malformed(path) }
        return d
    }

    /// One request, parsed, with the LoopBack error envelope mapped to `Error`. Gateway
    /// hiccups (502/503/504, a dropped keep-alive connection) are retried once.
    private func request(_ method: String, _ path: String, query: [String: String] = [:],
                         token: String?, body: [String: Any]? = nil) async throws -> Any {
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        var attempt = 0
        while true {
            attempt += 1
            let data: Data, resp: HTTPURLResponse
            do {
                let (d, r) = try await session.data(for: req)
                data = d
                resp = r as! HTTPURLResponse
            } catch let e as URLError where attempt == 1 && e.code == .networkConnectionLost {
                continue   // the server closed a kept-alive connection under us
            }
            if (502...504).contains(resp.statusCode), attempt == 1 {
                try await Task.sleep(nanoseconds: 800_000_000)
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
            if (200..<300).contains(resp.statusCode) { return json }

            let err = (json as? [String: Any])?["error"] as? [String: Any]
            let message = (err?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: resp.statusCode)
            let code = (err?["code"] as? String) ?? ""
            switch resp.statusCode {
            case 401: throw Error.unauthorized
            case 403 where message.localizedCaseInsensitiveContains("too many"): throw Error.lockedOut
            case 403: throw Error.unauthorized
            case 406 where message.localizedCaseInsensitiveContains("two factor") || message.localizedCaseInsensitiveContains("code"):
                throw Error.twoFactorRequired
            case 408 where message.localizedCaseInsensitiveContains("code"): throw Error.badTwoFactorCode
            default: throw Error.server(resp.statusCode, code.isEmpty ? message : "\(message) [\(code)]")
            }
        }
    }
}
