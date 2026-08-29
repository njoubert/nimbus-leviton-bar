// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `--probe`: one pass over every endpoint the app relies on, asserting the *shape* the
/// parser assumes rather than the values. My Leviton's API is undocumented and can change
/// under us at any time; without this, drift arrives as a mystery bug in the menu — a device
/// that stops dimming, a room order that reverts to id order — and the diagnosis starts from
/// nothing. Here it arrives as a named field on a named device.
///
/// **Read-only, and it must stay that way.** Every call is a GET on a session the caller
/// already has (`CLI.session`: the cached token, a login at most once and only if it has gone
/// stale). No PUT, no POST, no `execute`, no websocket — running the probe must never be
/// visible in the owner's house, and must never spend a sign-in attempt.
///
/// One line per check: `✓` the shape held, `⚠` an advisory (a tripwire flag, or a count kept
/// for the record), `✗` drift, with the evidence indented under it. Exit 1 iff anything
/// failed; advisories alone still exit 0.
enum Probe {

    /// The whole probe. `out` is a seam for the tests, which run it against a stubbed server.
    static func run(client: LevitonClient, session: Keychain.Session,
                    out: @escaping (String) -> Void = { Swift.print($0) }) async -> Int32 {
        let r = Report(out: out)
        var residences: [ResidenceInfo] = []
        var devices = 0, rooms = 0, activities = 0

        // 1 — the permissions list, which is where every other id comes from.
        var accounts: [String] = []
        var shared: [String] = []
        let permsPath = "Person/\(session.userId)/residentialPermissions"
        switch await rows(client, session: session, permsPath) {
        case .failure(let e):
            r.fail("residentialPermissions: \(describe(e))")
        case .success(let perms):
            var problems: [String] = []
            for (i, p) in perms.enumerated() {
                if let acct = LevitonClient.idString(p["residentialAccountId"]) {
                    accounts.append(acct)
                } else if let rid = LevitonClient.idString(p["residenceId"]) {
                    shared.append(rid)
                } else {
                    problems.append("row \(i): no id-shaped residentialAccountId or residenceId (keys: \(keys(p)))")
                }
            }
            r.expect("residentialPermissions: \(count(perms.count, "row", "rows")), each with residentialAccountId or residenceId",
                     problems: problems)
        }

        // 2 — the residences behind them. An owned account lists its own; a shared permission
        // names one residence and the record carries the name (what `residences()` does).
        var seen = Set<String>()
        for acct in accounts {
            let path = "ResidentialAccounts/\(acct)/residences"
            switch await rows(client, session: session, path) {
            case .failure(let e):
                r.fail("\(path): \(describe(e))")
            case .success(let list):
                var problems: [String] = []
                for (i, row) in list.enumerated() {
                    guard let id = LevitonClient.idString(row["id"]) else {
                        problems.append("row \(i): id is \(show(row["id"])), not id-shaped"); continue
                    }
                    guard let name = row["name"] as? String else {
                        problems.append("residence \(id): name is \(show(row["name"])), not a String"); continue
                    }
                    if seen.insert(id).inserted { residences.append(ResidenceInfo(id: id, name: name)) }
                }
                r.expect("\(path): \(count(list.count, "residence", "residences")), each {id, name}",
                         problems: problems)
            }
        }
        for rid in shared {
            let path = "Residences/\(rid)"
            switch await object(client, session, path) {
            case .failure(let e):
                r.fail("\(path) (shared): \(describe(e))")
            case .success(let row):
                let name = row["name"] as? String
                r.expect("\(path) (shared): {id, name}",
                         problems: name == nil ? ["name is \(show(row["name"])), not a String"] : [])
                if seen.insert(rid).inserted { residences.append(ResidenceInfo(id: rid, name: name ?? "Shared home")) }
            }
        }

        // 3 — the room order, which lives on the person and is one preference row per
        // residence. Its value being a JSON *string* is the fragile part.
        await checkPreferences(client, session, r)

        for res in residences {
            devices += await checkDevices(client, session, res, r)
            rooms += await checkRooms(client, session, res, r)
            activities += await checkActivities(client, session, res, r)
        }

        r.line("probed \(count(residences.count, "residence", "residences")), "
               + "\(count(devices, "device", "devices")), "
               + "\(count(rooms, "room", "rooms")), "
               + "\(count(activities, "activity", "activities"))")
        r.summary()
        return r.exitCode
    }

    // MARK: The checks

    /// `Residences/{id}/iotSwitches` — the record the whole menu is built from. Returns how
    /// many devices were seen, for the closing summary.
    private static func checkDevices(_ client: LevitonClient, _ s: Keychain.Session,
                                     _ res: ResidenceInfo, _ r: Report) async -> Int {
        let path = "Residences/\(res.id)/iotSwitches"
        guard let list = await value(rows(client, session: s, path), path, r) else { return 0 }

        var problems: [String] = []
        var optedOut: [String] = []
        var noReason: [String] = []
        var models = Set<String>()

        for j in list {
            let who = (j["name"] as? String) ?? "id \(LevitonClient.idString(j["id"]) ?? "?")"
            func bad(_ field: String) { problems.append("\(who): \(field) = \(show(j[field]))") }

            if !isInt(j["id"]) { bad("id") }
            if !isString(j["name"]) { bad("name") }
            let power = (j["power"] as? String)?.uppercased()
            if power != "ON" && power != "OFF" { bad("power") }
            if let b = j["brightness"] as? Int {
                if !(0...100).contains(b) { bad("brightness") }
            } else { bad("brightness") }
            if !isBool(j["canSetLevel"]) { bad("canSetLevel") }
            if !isInt(j["minLevel"]) { bad("minLevel") }
            if !isInt(j["maxLevel"]) { bad("maxLevel") }
            if !isBool(j["connected"]) { bad("connected") }
            if !isString(j["model"]) { bad("model") }
            if !isString(j["version"]) { bad("version") }
            if !isString(j["serial"]) { bad("serial") }
            if LevitonClient.idString(j["residenceId"]) == nil { bad("residenceId") }
            // Optional on the wire; wrong when present is still drift.
            if present(j["residentialRoomId"]), LevitonClient.idString(j["residentialRoomId"]) == nil {
                bad("residentialRoomId")
            }
            if present(j["presetLevel"]), !isInt(j["presetLevel"]) { bad("presetLevel") }
            if present(j["deleted"]), !isBool(j["deleted"]) { bad("deleted") }

            if (j["includeInRoomOnOff"] as? Bool) == false { optedOut.append(who) }
            if !isInt(j["chgReason"]) { noReason.append("\(who): chgReason = \(show(j["chgReason"]))") }
            if let m = j["model"] as? String, !m.isEmpty { models.insert(m) }
        }

        r.expect("iotSwitches [\(res.name)]: \(count(list.count, "device", "devices")), every field the shape the parser assumes",
                 problems: problems)
        if !optedOut.isEmpty {
            // The server ignores this flag on room On/Off; the account was set all-true on
            // 2026-08-22, so a false one means someone (or something) changed it back.
            r.warn("includeInRoomOnOff=false on \(optedOut.count) of \(list.count) devices — the account reads all-true since 2026-08-22",
                   optedOut)
        }
        if !noReason.isEmpty {
            r.warn("chgReason absent or not an Int on \(noReason.count) of \(list.count) devices — the forensics runbook reads it",
                   noReason)
        }
        r.warn("models [\(res.name)]: \(list.count) devices, \(models.count) models — \(models.sorted().joined(separator: ", "))")
        return list.count
    }

    /// `Residences/{id}/residentialRooms` — three separate claims, because each fails on its
    /// own: the row shape, "the listing order is id order", and `position` being dead.
    private static func checkRooms(_ client: LevitonClient, _ s: Keychain.Session,
                                   _ res: ResidenceInfo, _ r: Report) async -> Int {
        let path = "Residences/\(res.id)/residentialRooms"
        guard let list = await value(rows(client, session: s, path), path, r) else { return 0 }

        var problems: [String] = []
        var positions: [String] = []
        var ids: [Int] = []
        var unnumbered: [String] = []

        for (i, row) in list.enumerated() {
            let id = LevitonClient.idString(row["id"])
            let who = (row["name"] as? String) ?? "row \(i)"
            if id == nil { problems.append("\(who): id = \(show(row["id"])), not id-shaped") }
            if !isString(row["name"]) { problems.append("row \(i): name = \(show(row["name"])), not a String") }
            let power = (row["power"] as? String)?.uppercased()
            if power != "ON" && power != "OFF" { problems.append("\(who): power = \(show(row["power"]))") }
            // `position` is null on every room — the order the user dragged lives on the
            // person instead. A number here would mean Leviton woke the field up.
            if present(row["position"]) { positions.append("\(who): position = \(show(row["position"]))") }
            if let n = id.flatMap(Int.init) { ids.append(n) } else if id != nil { unnumbered.append(who) }
        }

        var order: [String] = []
        for (a, b) in zip(ids, ids.dropFirst()) where a >= b {
            order.append("room \(a) is listed before room \(b)")
        }
        if !unnumbered.isEmpty { order.append("ids that are not numbers: \(unnumbered.joined(separator: ", "))") }

        r.expect("residentialRooms [\(res.name)]: \(count(list.count, "room", "rooms")), each {id, name, power}",
                 problems: problems)
        r.expect("residentialRooms [\(res.name)]: listed in ascending id order", problems: order)
        r.expect("residentialRooms [\(res.name)]: position still null on every room", problems: positions)
        return list.count
    }

    /// `Person/{userId}/preferences` — one row per residence carries the room order, and its
    /// `value` is a JSON **string**. A real array there is exactly the silent drift that would
    /// drop the user's order back to id order with nothing to see.
    private static func checkPreferences(_ client: LevitonClient, _ s: Keychain.Session, _ r: Report) async {
        let path = "Person/\(s.userId)/preferences"
        guard let list = await value(rows(client, session: s, path), path, r) else { return }

        var problems: [String] = []
        var sortingKeys: [String] = []
        var orderRows = 0

        for p in list {
            guard let key = p["key"] as? String else { continue }
            if key.hasPrefix("sorting$") { sortingKeys.append(key) }
            guard key.hasPrefix("sorting$residence:"), key.hasSuffix("$rooms") else { continue }
            orderRows += 1
            guard let text = p["value"] as? String else {
                problems.append("\(key): value is \(typeName(p["value"])), not a JSON string — the room order would be dropped")
                continue
            }
            guard let ids = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] else {
                problems.append("\(key): value does not parse as a JSON array — \(show(text))")
                continue
            }
            let odd = ids.filter { LevitonClient.idString($0) == nil }
            if !odd.isEmpty {
                problems.append("\(key): \(odd.count) of \(ids.count) entries are not id-shaped — \(show(odd.first))")
            }
        }

        r.expect("preferences: \(count(list.count, "row", "rows")), "
                 + "\(count(orderRows, "room-order row", "room-order rows")), "
                 + "each a JSON *string* holding an array of ids",
                 problems: problems)
        // Device-order rows appearing here would be news: our own device order is alphabetical.
        r.warn("sorting$ rows: \(sortingKeys.count)", sortingKeys.sorted())
    }

    /// `Residences/{id}/residentialActivities?filter={"include":["residentialActions"]}` — the
    /// include has to be honoured (one request, or the scenes have no contents) and both live
    /// `residentialAction` shapes have to keep decoding.
    private static func checkActivities(_ client: LevitonClient, _ s: Keychain.Session,
                                        _ res: ResidenceInfo, _ r: Report) async -> Int {
        let filter = #"{"include":["residentialActions"]}"#
        let path = "Residences/\(res.id)/residentialActivities"
        guard let list = await value(rows(client, session: s, "\(path)?filter=\(filter)"), path, r) else { return 0 }

        var withoutActions = 0
        var flags: [String] = []
        var missingFlag: [String] = []
        var undecoded: [String] = []
        var blobs = 0, bare = 0

        for a in list {
            let who = (a["name"] as? String) ?? "activity \(LevitonClient.idString(a["id"]) ?? "?")"
            let actions = a["residentialActions"] as? [[String: Any]]
            if actions == nil { withoutActions += 1 }
            // `activities()` reads `(isButtonActivity as? Bool) != true`, so an absent flag is
            // safe (it means "not a button activity") but a wrong type is not: a string "true"
            // would put a 4-button controller's activities in the menu.
            if !present(a["isButtonActivity"]) {
                missingFlag.append(who)
            } else if !isBool(a["isButtonActivity"]) {
                flags.append("\(who): isButtonActivity = \(show(a["isButtonActivity"]))")
            }
            for action in actions ?? [] {
                guard (action["targetModelName"] as? String) == "IotSwitch" else { continue }
                let property = (action["targetProperty"] as? String) ?? ""
                if property == "properties" { blobs += 1 } else { bare += 1 }
                if LevitonClient.sceneAction(from: action) == nil {
                    undecoded.append("\(who): targetProperty \(show(action["targetProperty"])), "
                                     + "targetValue \(show(action["targetValue"])) does not decode")
                }
            }
        }

        if list.isEmpty {
            r.warn("residentialActivities [\(res.name)]: no activities — the include could not be checked")
        } else if withoutActions == list.count {
            r.fail("residentialActivities [\(res.name)]: the include was not honoured — none of "
                   + "\(count(list.count, "activity", "activities")) carries residentialActions")
        } else if withoutActions > 0 {
            r.warn("residentialActivities [\(res.name)]: residentialActions missing on \(withoutActions) of \(list.count) rows")
        } else {
            r.pass("residentialActivities [\(res.name)]: \(count(list.count, "activity", "activities")), "
                   + "every row carries residentialActions")
        }
        r.expect("residentialActivities [\(res.name)]: isButtonActivity is a Bool wherever it appears", problems: flags)
        if !missingFlag.isEmpty {
            r.warn("isButtonActivity absent on \(missingFlag.count) of \(list.count) activities — read as false", missingFlag)
        }
        r.expect("residentialActions [\(res.name)]: every IotSwitch action decodes", problems: undecoded)
        r.warn("action shapes [\(res.name)]: \(blobs) properties-blob, \(bare) bare")
        return list.count
    }

    // MARK: The report

    /// Terse and greppable: a glyph, a claim, and the evidence indented under a failure —
    /// `provision.sh`'s convention, in Swift.
    final class Report {
        private let out: (String) -> Void
        private(set) var checks = 0
        private(set) var warnings = 0
        private(set) var failures = 0
        /// A drift that hits 40 devices should not print 40 lines.
        static let evidenceLimit = 6

        init(out: @escaping (String) -> Void) { self.out = out }

        func line(_ text: String) { out(text) }
        func pass(_ text: String) { checks += 1; out("✓ \(text)") }
        func warn(_ text: String, _ evidence: [String] = []) {
            checks += 1; warnings += 1; out("⚠ \(text)"); detail(evidence)
        }
        func fail(_ text: String, _ evidence: [String] = []) {
            checks += 1; failures += 1; out("✗ \(text)"); detail(evidence)
        }
        /// The usual shape of a check: a claim, and the records that broke it.
        func expect(_ text: String, problems: [String]) {
            if problems.isEmpty { pass(text) } else { fail(text, problems) }
        }
        func summary() { out("\(checks) checks, \(warnings) warnings, \(failures) failures") }
        var exitCode: Int32 { failures == 0 ? 0 : 1 }

        private func detail(_ evidence: [String]) {
            for e in evidence.prefix(Self.evidenceLimit) { out("    \(e)") }
            if evidence.count > Self.evidenceLimit {
                out("    … and \(evidence.count - Self.evidenceLimit) more")
            }
        }
    }

    // MARK: Fetching

    /// A GET that must come back as an array of objects.
    private static func rows(_ client: LevitonClient, session s: Keychain.Session,
                             _ path: String) async -> Result<[[String: Any]], Swift.Error> {
        do {
            let json = try await client.rawGet(s, path)
            guard let a = json as? [[String: Any]] else {
                return .failure(LevitonClient.Error.message("not an array of objects (\(typeName(json)))"))
            }
            return .success(a)
        } catch { return .failure(error) }
    }

    private static func object(_ client: LevitonClient, _ s: Keychain.Session,
                               _ path: String) async -> Result<[String: Any], Swift.Error> {
        do {
            let json = try await client.rawGet(s, path)
            guard let d = json as? [String: Any] else {
                return .failure(LevitonClient.Error.message("not an object (\(typeName(json)))"))
            }
            return .success(d)
        } catch { return .failure(error) }
    }

    /// Unwrap a fetch, recording the failure as drift and letting the caller skip the rest.
    private static func value<T>(_ result: Result<T, Swift.Error>, _ path: String, _ r: Report) -> T? {
        switch result {
        case .success(let v): return v
        case .failure(let e): r.fail("\(path): \(describe(e))"); return nil
        }
    }

    // MARK: Shapes

    private static func isString(_ v: Any?) -> Bool { v as? String != nil }
    private static func isBool(_ v: Any?) -> Bool { v as? Bool != nil }
    private static func isInt(_ v: Any?) -> Bool { v as? Int != nil }
    private static func present(_ v: Any?) -> Bool { v != nil && !(v is NSNull) }

    /// The offending value itself — the thing that makes a ✗ line worth reading. Capped:
    /// a device record's stray field can be a whole blob.
    private static func show(_ v: Any?) -> String {
        guard let v else { return "absent" }
        if v is NSNull { return "null" }
        let text = (v as? String).map { "\"\($0)\"" } ?? String(describing: v)
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    private static func typeName(_ v: Any?) -> String {
        guard let v else { return "absent" }
        switch v {
        case is NSNull: return "null"
        case is String: return "a string"
        case is [Any]: return "an array"
        case is [String: Any]: return "an object"
        case is Bool, is Int, is Double: return "a number"
        default: return "a \(type(of: v))"
        }
    }

    private static func keys(_ d: [String: Any]) -> String { d.keys.sorted().joined(separator: ", ") }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    private static func describe(_ e: Swift.Error) -> String {
        (e as? LevitonClient.Error)?.description ?? e.localizedDescription
    }
}
