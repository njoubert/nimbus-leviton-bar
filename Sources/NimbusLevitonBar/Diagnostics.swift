// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// The app's flight recorder: every REST request, every websocket frame, and the state
/// changes around them, in a ring buffer that the Internals panel reads
/// (`InternalsPanel.swift`, ⌥ over the version line).
///
/// Three rules it lives under:
///
///  - **It records from launch, not from when the panel opens.** The things worth seeing —
///    a pong that never came, the hour-long auth backoff, a feed that quietly stopped
///    delivering — happen long before anyone thinks to look.
///  - **Nothing secret goes in.** The password is replaced before the login body is
///    stringified, the session token exists here only as a SHA-256 fingerprint (`#a3f19c`,
///    enough to see it *change* after a re-login and useless to anyone reading over a
///    shoulder), the `Authorization` header is never recorded at all, and the websocket's
///    token frame is rewritten before it is logged. Everything the panel shows or copies is
///    therefore safe to paste into a bug report.
///  - **It is bounded.** `capacity` events; only the newest `detailWindow` of them keep their
///    bodies, each capped at `detailLimit`.
///
/// Safe from any thread: one lock, and no callback is ever made while it is held. The panel
/// polls `version` instead of being called back, so nothing here touches AppKit.
final class Diagnostics: @unchecked Sendable {

    static let shared = Diagnostics()

    /// Which stream an event belongs to — the panel's filter, and its middle column.
    enum Kind: String, CaseIterable, Sendable {
        case rest = "REST"
        case ws = "WS"
        case app = "APP"
    }

    struct Event: Identifiable, Sendable {
        let id: Int
        let at: Date
        let kind: Kind
        var title: String
        /// The bodies, for the detail pane. Dropped once the event falls out of
        /// `detailWindow`; nil from the start for events that never had one.
        var detail: String?
        var isError: Bool
    }

    /// What the websocket is doing, kept here rather than read off `LevitonRealtime` — that
    /// runs on its own queue, and the panel must never block on it.
    struct Feed: Sendable {
        var state = "stopped"
        var since: Date?
        var frames = 0
        var lastFrame: Date?
        var subscriptions = 0
        var backoff: TimeInterval = 1
        var nextReconnect: Date?
        var lastPing: Date?
        var lastPong: TimeInterval?
        var connects = 0
        var drops = 0
    }

    struct Rest: Sendable {
        var requests = 0
        var failures = 0
        var bytesIn = 0
        var lastDuration: TimeInterval?
        var inFlight = 0
    }

    /// The session, with the token reduced to a fingerprint on the way in.
    struct SessionInfo: Sendable {
        var fingerprint: String
        var userId: String
        var created: Date
        var expiry: Date?
        var fresh: Bool
    }

    static let capacity = 2000
    static let detailWindow = 200
    /// Big enough that a whole `Residences/{id}/iotSwitches` reply (51 KB on this account)
    /// arrives intact and can be pretty-printed — a truncated body is no longer JSON, and the
    /// detail pane then has to show it raw.
    static let detailLimit = 96 * 1024

    private let lock = NSLock()
    private var events: [Event] = []
    private var nextID = 1
    private var _version = 0
    private var _feed = Feed()
    private var _rest = Rest()
    private var _session: SessionInfo?

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Reading (the panel's side)

    /// Bumped by every change. The panel reloads when it moves and does nothing when it
    /// doesn't, which is what keeps a 4 Hz tick free.
    var version: Int { sync { _version } }
    var snapshot: [Event] { sync { events } }
    var feed: Feed { sync { _feed } }
    var rest: Rest { sync { _rest } }
    var session: SessionInfo? { sync { _session } }

    func clear() {
        sync {
            events.removeAll()
            _version += 1
        }
    }

    // MARK: Writing

    @discardableResult
    func record(_ kind: Kind, _ title: String, detail: String? = nil, isError: Bool = false) -> Int {
        sync {
            let id = nextID
            nextID += 1
            events.append(Event(id: id, at: Date(), kind: kind, title: title,
                                detail: detail.map(Self.cap), isError: isError))
            // Older events keep their one-line title for as long as they are in the buffer;
            // only the bodies are let go, and those are all of the weight.
            if events.count > Self.detailWindow {
                events[events.count - Self.detailWindow - 1].detail = nil
            }
            if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
            _version += 1
            return id
        }
    }

    /// Attach a reply (or a failure) to an event already logged. Ids are unique for the life
    /// of the process, so an event that has fallen out of the buffer simply finds nothing.
    func amend(_ id: Int, title: String? = nil, append: String? = nil, isError: Bool? = nil) {
        sync {
            guard let i = events.lastIndex(where: { $0.id == id }) else { return }
            if let title { events[i].title = title }
            if let append {
                let joined = (events[i].detail.map { $0 + "\n\n" } ?? "") + append
                events[i].detail = Self.cap(joined)
            }
            if let isError { events[i].isError = isError }
            _version += 1
        }
    }

    func feed(_ mutate: (inout Feed) -> Void) {
        sync {
            mutate(&_feed)
            _version += 1
        }
    }

    func rest(_ mutate: (inout Rest) -> Void) {
        sync {
            mutate(&_rest)
            _version += 1
        }
    }

    /// Called wherever the store gains or loses a session. The token is fingerprinted here,
    /// on the way in, so a raw one is never held.
    func setSession(_ s: Keychain.Session?) {
        let info = s.map {
            SessionInfo(fingerprint: Self.fingerprint($0.token), userId: $0.userId,
                        created: $0.created, expiry: $0.expiry, fresh: $0.isFresh)
        }
        sync {
            _session = info
            _version += 1
        }
    }

    // MARK: REST plumbing (LevitonClient calls these)

    /// A request on its way out. The returned id carries the reply back to this row.
    func beginRequest(method: String, url: URL, path: String, body: [String: Any]?) -> Int {
        rest { $0.inFlight += 1; $0.requests += 1 }
        var detail = "→ \(method) \(url.absoluteString)"
        if let b = Self.redactedBody(body, path: path) { detail += "\n\(b)" }
        return record(.rest, "\(method) \(Self.short(path, url: url))", detail: detail)
    }

    /// The reply came back — logged whatever the status, since a 401 or a 403 is exactly what
    /// someone opens the panel to see. `data` is the raw body; the login's is rewritten
    /// (it carries the token) and anything else is kept as it came, capped.
    func endRequest(_ id: Int, method: String, path: String, url: URL, status: Int,
                    started: Date, data: Data) {
        let ms = Date().timeIntervalSince(started)
        rest {
            $0.inFlight = max(0, $0.inFlight - 1)
            $0.bytesIn += data.count
            $0.lastDuration = ms
            if !(200..<300).contains(status) { $0.failures += 1 }
        }
        let head = "← \(status) · \(Self.ms(ms)) · \(Self.bytes(data.count))"
        amend(id,
              title: "\(method) \(Self.short(path, url: url))  \(status) · \(Self.ms(ms))",
              append: head + "\n" + Self.responseBody(data, path: path),
              isError: !(200..<300).contains(status))
    }

    /// The request never got a reply: offline, a timeout, a refused connection.
    func failRequest(_ id: Int, method: String, path: String, url: URL, started: Date, error: Swift.Error) {
        rest {
            $0.inFlight = max(0, $0.inFlight - 1)
            $0.failures += 1
        }
        amend(id,
              title: "\(method) \(Self.short(path, url: url))  ✗ \(DeviceStore.describe(error))",
              append: "✗ \(error) after \(Self.ms(Date().timeIntervalSince(started)))",
              isError: true)
    }

    /// The call went away without an answer — the task it ran on was cancelled (a refresh
    /// abandoned mid-flight, the app quitting).
    func abandonRequest(_ id: Int, method: String, path: String, url: URL, started: Date) {
        rest { $0.inFlight = max(0, $0.inFlight - 1) }
        amend(id,
              title: "\(method) \(Self.short(path, url: url))  ✗ abandoned",
              append: "✗ cancelled after \(Self.ms(Date().timeIntervalSince(started)))",
              isError: true)
    }

    /// A retry (a 502, or a keep-alive the server dropped under us) — the same row, so one
    /// request stays one line.
    func noteRetry(_ id: Int, _ why: String) {
        amend(id, append: "… \(why), retrying")
    }

    // MARK: Redaction and formatting

    /// A token as six hex digits of its SHA-256. Two sessions are the same or they aren't;
    /// nothing else about the token can be recovered from this.
    static func fingerprint(_ token: String) -> String {
        let d = SHA256.hash(data: Data(token.utf8))
        return "#" + d.prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// A request body as JSON, with the secrets taken out. `password` and the 2FA `code`
    /// never appear; nothing else in a body this app sends is sensitive.
    static func redactedBody(_ body: [String: Any]?, path: String) -> String? {
        guard let body, !body.isEmpty else { return nil }
        var b = body
        for key in ["password", "code"] where b[key] != nil { b[key] = "«hidden»" }
        return json(b)
    }

    /// A response body for the detail pane. The login's reply *is* the token, so that one is
    /// rebuilt from the fields worth seeing; if it can't be parsed it is dropped rather than
    /// shown, because a body we cannot understand is one we cannot redact.
    static func responseBody(_ data: Data, path: String) -> String {
        guard !data.isEmpty else { return "(empty)" }
        if path.hasSuffix("Person/login") {
            guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "(login reply withheld: \(bytes(data.count)) that could not be parsed and so could not be redacted)"
            }
            var safe: [String: Any] = ["id": (d["id"] as? String).map(fingerprint) ?? "«hidden»"]
            for k in ["userId", "ttl", "created"] where d[k] != nil { safe[k] = d[k] }
            return json(safe) ?? "(login reply)"
        }
        return cap(String(data: data, encoding: .utf8) ?? "(\(bytes(data.count)) of non-text)")
    }

    /// Pretty-print JSON for the detail pane; anything that isn't JSON (a truncated body, an
    /// HTML error page) comes back untouched.
    static func pretty(_ s: String) -> String {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8) else { return s }
        return text
    }

    static func json(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func cap(_ s: String) -> String {
        guard s.count > detailLimit else { return s }
        return String(s.prefix(detailLimit)) + "\n… (\(s.count - detailLimit) more characters)"
    }

    /// `IotSwitches/1613723` out of the full URL, with the query if there is one — the path is
    /// what identifies a call, and the host is the same for all of them.
    static func short(_ path: String, url: URL) -> String {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
        return path + (q.map { "?\($0)" } ?? "")
    }

    static func ms(_ t: TimeInterval) -> String {
        t < 1 ? "\(Int((t * 1000).rounded())) ms" : String(format: "%.1f s", t)
    }

    static func bytes(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : n < 1024 * 1024 ? String(format: "%.1f KB", Double(n) / 1024)
                                              : String(format: "%.1f MB", Double(n) / 1_048_576)
    }

    // MARK: Websocket frames

    /// One line for the list: what the frame *is*, rather than its first eighty characters.
    /// The full frame is the detail.
    static func frameSummary(_ text: String, outgoing: Bool) -> String {
        let arrow = outgoing ? "→" : "←"
        guard let d = text.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return "\(arrow) \(oneLine(text))"
        }
        if j["token"] != nil { return "\(arrow) token" }
        switch j["type"] as? String {
        case "subscribe":
            let sub = j["subscription"] as? [String: Any]
            return "\(arrow) subscribe \(LevitonClient.idString(sub?["modelId"]) ?? "?")"
        case "status":
            return "\(arrow) status \((j["status"] as? String) ?? "?")"
        case "challenge":
            return "\(arrow) challenge"
        case "notification":
            let n = j["notification"] as? [String: Any]
            let id = LevitonClient.idString(n?["modelId"]) ?? "?"
            let event = (n?["event"] as? String) ?? "?"
            let fields = (n?["data"] as? [String: Any]).map { LevitonClient.DeviceFields(json: $0).description } ?? ""
            let keys = (n?["data"] as? [String: Any]).map { $0.keys.sorted().joined(separator: ",") } ?? ""
            return "\(arrow) \(event) \(id) \(fields == "(no change)" ? keys : fields)"
        default:
            return "\(arrow) \(oneLine(text))"
        }
    }

    private static func oneLine(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 110 ? String(flat.prefix(110)) + "…" : flat
    }
}
