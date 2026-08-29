// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// My Leviton's push feed: a websocket that announces every change to a subscribed switch —
/// from the wall, the phone app, a schedule, or us — so the menu and the bar count follow
/// without polling. The protocol (the web app's `LevdbRealTime`):
///
///   → {"token": {id, userId, ttl, created, rememberMe}}      on open (and again on a "challenge")
///   ← {"type":"status","status":"ready"}                      authenticated
///   → {"type":"subscribe","subscription":{"modelName":"IotSwitch","modelId":<int>}}   per device
///   ← {"type":"notification","notification":{"event":"saved","modelName":"IotSwitch",
///        "modelId":<int>,"data":{ partial IotSwitch }}}
///
/// A ping every 30 s keeps it alive and must be answered within `pongTimeout` — an unanswered
/// ping is the only thing that catches a connection that is open but no longer carrying
/// anything. Drops are routine and reconnect with backoff, and `reconnectNow()` skips the
/// wait. An auth
/// rejection (close 1008, or "unauthorized" in the reason) backs off for an hour — the REST
/// poll is the safety net, and repeated bad logins lock the account.
///
/// `onUpdate` and `onLive` are called on the main queue.
final class LevitonRealtime: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {

    static let url = URL(string: "wss://my.leviton.com/socket/websocket")!
    static let pingInterval: TimeInterval = 30
    /// How long a pong may take before the connection counts as dead. `sendPing`'s completion
    /// *is* the pong handler and has no timeout of its own, so without this a half-open
    /// connection (a sleep, a changed network, an expired NAT mapping) sits there looking
    /// healthy until the kernel gives up retransmitting — minutes later.
    static let pongTimeout: TimeInterval = 10

    /// The statics above are the app's values; the instance knobs exist so the tests can
    /// point at a localhost server and force a pong timeout in milliseconds rather than
    /// editing constants (which is how it was measured by hand, per CLAUDE.md). Set them
    /// before `start()`.
    let url: URL
    var pingInterval: TimeInterval = LevitonRealtime.pingInterval
    var pongTimeout: TimeInterval = LevitonRealtime.pongTimeout
    /// The backoff after an auth rejection (close 1008): an hour in the app.
    var authBackoff: TimeInterval = 3600
    /// The ordinary reconnect backoff's ceiling.
    var maxBackoff: TimeInterval = 60

    var onUpdate: ((String, LevitonClient.DeviceFields) -> Void)?
    /// The feed went live (authenticated and subscribed) or stopped being live — a drop, an
    /// auth rejection, `stop()`. The menu says "live" on the strength of this; the REST poll
    /// carries on either way.
    var onLive: ((Bool) -> Void)?
    /// The feed's session was rejected (close 1008, or an unauthorized-flavoured reason) and
    /// the feed is now waiting out `authBackoff`. Called on the main queue; the store's drift
    /// warning is the audience — an ordinary drop never fires this.
    var onAuthBackoff: (() -> Void)?
    /// Log every frame to stderr (`--watch`).
    var verbose = false
    /// Where the frame log goes instead of stderr (`--journal`): every line `log()` would
    /// print under `verbose`, token frames already redacted. Called on the realtime queue.
    var logSink: ((String) -> Void)?

    private let session: Keychain.Session
    private var deviceIds: Set<String>
    private let queue = DispatchQueue(label: "leviton.realtime")
    private lazy var urlSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?
    private var pongDeadline: DispatchWorkItem?
    private var ready = false {
        didSet {
            guard ready != oldValue else { return }
            let live = ready
            DispatchQueue.main.async { self.onLive?(live) }
        }
    }
    private var stopped = false
    private var backoff: TimeInterval = 1
    private var generation = 0   // bumped per connection so stale callbacks are ignored

    init(session: Keychain.Session, deviceIds: [String], url: URL = LevitonRealtime.url) {
        self.session = session
        self.deviceIds = Set(deviceIds)
        self.url = url
    }

    func start() {
        queue.async { self.stopped = false; self.connect() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.teardown()
        }
    }

    /// The device list changed (a refresh found new switches): subscribe to the additions.
    func setDeviceIds(_ ids: [String]) {
        queue.async {
            let new = Set(ids).subtracting(self.deviceIds)
            self.deviceIds = Set(ids)
            if self.ready {
                for id in new { self.subscribe(id) }
                Diagnostics.shared.feed { $0.subscriptions = self.deviceIds.count }
            }
        }
    }

    // MARK: Connection

    private func connect() {
        guard !stopped else { return }
        teardown()
        generation += 1
        var req = URLRequest(url: url)
        req.setValue("https://my.leviton.com", forHTTPHeaderField: "Origin")
        req.timeoutInterval = 30
        let t = urlSession.webSocketTask(with: req)
        task = t
        t.resume()
        receive(t, generation)
        log("connecting")
        Diagnostics.shared.feed {
            $0.state = "connecting"
            $0.since = Date()
            $0.nextReconnect = nil
            $0.connects += 1
        }
    }

    private func teardown() {
        pingTimer?.cancel(); pingTimer = nil
        pongDeadline?.cancel(); pongDeadline = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
        Diagnostics.shared.feed {
            $0.state = self.stopped ? "stopped" : "down"
            $0.since = Date()
            $0.subscriptions = 0
            $0.lastPing = nil
            $0.lastPong = nil
        }
    }

    private func reconnect(after delay: TimeInterval) {
        guard !stopped else { return }
        let gen = generation
        log("reconnecting in \(Int(delay)) s")
        Diagnostics.shared.feed {
            $0.state = delay >= authBackoff ? "backing off after an auth rejection" : "backing off"
            $0.backoff = delay
            $0.nextReconnect = Date().addingTimeInterval(delay)
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            // `connect()` bumps the generation, so a `reconnectNow()` in the meantime makes
            // this one stale — firing it would kill the connection it just made.
            guard let self, self.generation == gen else { return }
            self.connect()
        }
    }

    /// Reconnect at once, whatever the backoff was waiting for: a wake, or the user asking for
    /// a refresh. This is the only way out of the hour-long auth backoff — a token that was
    /// rejected an hour ago may well have been replaced since.
    func reconnectNow() {
        queue.async {
            guard !self.stopped else { return }
            self.log("reconnecting now")
            self.backoff = 1
            self.connect()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue.async {
            guard webSocketTask === self.task else { return }
            self.log("open; sending token")
            self.send(["token": self.tokenObject()])
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            guard webSocketTask === self.task else { return }
            let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.log("closed \(closeCode.rawValue) \(why)")
            self.handleDrop(authFailure: closeCode == .policyViolation || why.range(of: "unauth|forbidden|401|403", options: .regularExpression) != nil)
        }
    }

    private func handleDrop(authFailure: Bool) {
        // One drop, one reconnect. Tearing the task down makes every request outstanding on it
        // fail, and each of those failures lands here: an aborted `sendPing` completion, the
        // pending `receive`. Without this guard a single drop scheduled three reconnects and
        // trebled the backoff (1 s → 8 s instead of 1 s → 2 s).
        guard let t = task else { return }
        // `didCloseWith` would say whether this was an auth rejection, but URLSession delivers
        // it only *after* failing the pending `receive` — which lands here first, tears down,
        // and leaves that callback to be discarded by its own task-identity guard. By then the
        // close frame's code and reason are already recorded on the task itself, so read them
        // here. Without this the hour-long auth backoff was unreachable and a dead token
        // re-sent its frame every ≤60 s (found by RealtimeTests against a local server,
        // 2026-08-29; `testURLSessionDeliversTheCloseCodeOnlyAfterTheReceiveFails` pins the
        // delivery order that makes it necessary).
        let reason = t.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let auth = authFailure || t.closeCode == .policyViolation
            || reason.range(of: "unauth|forbidden|401|403", options: .regularExpression) != nil
        Diagnostics.shared.feed { $0.drops += 1 }
        teardown()
        if auth {
            DispatchQueue.main.async { self.onAuthBackoff?() }
            reconnect(after: authBackoff)
        } else {
            reconnect(after: backoff)
            backoff = min(backoff * 2, maxBackoff)
        }
    }

    // MARK: Frames

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, t === self.task else { return }
                switch result {
                case .failure(let e):
                    self.log("receive failed: \(e.localizedDescription)")
                    self.handleDrop(authFailure: false)
                case .success(let msg):
                    let text: String
                    switch msg {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: text = ""
                    }
                    self.handle(text)
                    self.receive(t, gen)
                }
            }
        }
    }

    private func handle(_ text: String) {
        log("← \(text)")
        Diagnostics.shared.record(.ws, Diagnostics.frameSummary(text, outgoing: false), detail: text)
        Diagnostics.shared.feed { $0.frames += 1; $0.lastFrame = Date() }
        guard let data = text.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = j["type"] as? String else { return }
        switch type {
        case "challenge":
            send(["token": tokenObject()])
        case "status":
            if (j["status"] as? String) == "ready", !ready {
                ready = true
                backoff = 1
                for id in deviceIds { subscribe(id) }
                startPing()
                Diagnostics.shared.feed {
                    $0.state = "live"
                    $0.since = Date()
                    $0.backoff = 1
                    $0.nextReconnect = nil
                    $0.subscriptions = self.deviceIds.count
                }
            }
        case "notification":
            guard let n = j["notification"] as? [String: Any],
                  (n["modelName"] as? String) == "IotSwitch",
                  let id = LevitonClient.idString(n["modelId"]),
                  let d = n["data"] as? [String: Any] else { return }
            let fields = LevitonClient.DeviceFields(json: d)
            if fields == LevitonClient.DeviceFields() { return }   // nothing we show (rssi, chgReason…)
            DispatchQueue.main.async { self.onUpdate?(id, fields) }
        default:
            break
        }
    }

    private func subscribe(_ id: String) {
        let modelId: Any = Int(id) ?? id
        send(["type": "subscribe", "subscription": ["modelName": "IotSwitch", "modelId": modelId]])
    }

    private func send(_ obj: [String: Any]) {
        guard let t = task, let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        // Never the frame itself: the token frame carries the session token. What is logged
        // (and what the Internals panel shows) is a copy with the token fingerprinted, which
        // still says whether the session changed and what ttl the server was given.
        let safe = Self.redacted(obj).flatMap(Diagnostics.json) ?? s
        log("→ \(safe)")
        Diagnostics.shared.record(.ws, Diagnostics.frameSummary(safe, outgoing: true), detail: safe)
        t.send(.string(s)) { [weak self] e in
            if let e {
                self?.queue.async { self?.log("send failed: \(e.localizedDescription)") }
                Diagnostics.shared.record(.app, "feed: send failed — \(e.localizedDescription)", isError: true)
            }
        }
    }

    /// The token frame with its token replaced by a fingerprint. Every other frame we send
    /// (a subscribe) is already safe.
    private static func redacted(_ obj: [String: Any]) -> [String: Any]? {
        guard var token = obj["token"] as? [String: Any] else { return obj }
        token["id"] = (token["id"] as? String).map(Diagnostics.fingerprint) ?? "«hidden»"
        var out = obj
        out["token"] = token
        return out
    }

    /// The access-token object, as the login reply gave it (the server wants the record, not
    /// just the id).
    private func tokenObject() -> [String: Any] {
        var t: [String: Any] = ["id": session.token,
                                "userId": Int(session.userId) ?? session.userId,
                                "created": LevitonClient.iso.string(from: session.created),
                                "rememberMe": true]
        if let ttl = session.ttl { t["ttl"] = Int(ttl) }
        return t
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let t = self.task else { return }
            let gen = self.generation
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == gen else { return }
                self.log("pong timed out after \(Int(self.pongTimeout)) s")
                Diagnostics.shared.record(.app, "feed: no pong in \(Int(self.pongTimeout)) s — the connection is open but dead", isError: true)
                self.handleDrop(authFailure: false)
            }
            self.pongDeadline?.cancel()
            self.pongDeadline = deadline
            self.queue.asyncAfter(deadline: .now() + self.pongTimeout, execute: deadline)
            let sent = Date()
            Diagnostics.shared.feed { $0.lastPing = sent; $0.lastPong = nil }
            t.sendPing { [weak self] e in
                self?.queue.async {
                    guard let self, self.generation == gen, t === self.task else { return }
                    deadline.cancel()
                    if let e {
                        self.log("ping failed: \(e.localizedDescription)")
                        Diagnostics.shared.record(.app, "feed: ping failed — \(e.localizedDescription)", isError: true)
                        self.handleDrop(authFailure: false)
                    } else {
                        Diagnostics.shared.feed { $0.lastPong = Date().timeIntervalSince(sent) }
                    }
                }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    /// stderr under `--watch`, and — for everything but the frames, which are recorded with
    /// their own summaries — a line in the Internals panel's App stream.
    private func log(_ s: String) {
        if let sink = logSink { sink(s) } else if verbose { fputs("[realtime] \(s)\n", stderr) }
        guard !s.hasPrefix("→"), !s.hasPrefix("←") else { return }
        Diagnostics.shared.record(.app, "feed: \(s)", isError: s.contains("failed") || s.contains("timed out"))
    }
}
