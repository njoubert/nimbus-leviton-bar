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

    var onUpdate: ((String, LevitonClient.DeviceFields) -> Void)?
    /// The feed went live (authenticated and subscribed) or stopped being live — a drop, an
    /// auth rejection, `stop()`. The menu says "live" on the strength of this; the REST poll
    /// carries on either way.
    var onLive: ((Bool) -> Void)?
    /// Log every frame to stderr (`--watch`).
    var verbose = false

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

    init(session: Keychain.Session, deviceIds: [String]) {
        self.session = session
        self.deviceIds = Set(deviceIds)
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
            if self.ready { for id in new { self.subscribe(id) } }
        }
    }

    // MARK: Connection

    private func connect() {
        guard !stopped else { return }
        teardown()
        generation += 1
        var req = URLRequest(url: Self.url)
        req.setValue("https://my.leviton.com", forHTTPHeaderField: "Origin")
        req.timeoutInterval = 30
        let t = urlSession.webSocketTask(with: req)
        task = t
        t.resume()
        receive(t, generation)
        log("connecting")
    }

    private func teardown() {
        pingTimer?.cancel(); pingTimer = nil
        pongDeadline?.cancel(); pongDeadline = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
    }

    private func reconnect(after delay: TimeInterval) {
        guard !stopped else { return }
        let gen = generation
        log("reconnecting in \(Int(delay)) s")
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
        guard task != nil else { return }
        teardown()
        if authFailure {
            reconnect(after: 3600)
        } else {
            reconnect(after: backoff)
            backoff = min(backoff * 2, 60)
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
        log("→ \(s.hasPrefix("{\"token\"") ? "{\"token\": …}" : s)")
        t.send(.string(s)) { [weak self] e in
            if let e { self?.queue.async { self?.log("send failed: \(e.localizedDescription)") } }
        }
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
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let t = self.task else { return }
            let gen = self.generation
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == gen else { return }
                self.log("pong timed out after \(Int(Self.pongTimeout)) s")
                self.handleDrop(authFailure: false)
            }
            self.pongDeadline?.cancel()
            self.pongDeadline = deadline
            self.queue.asyncAfter(deadline: .now() + Self.pongTimeout, execute: deadline)
            t.sendPing { [weak self] e in
                self?.queue.async {
                    guard let self, self.generation == gen, t === self.task else { return }
                    deadline.cancel()
                    if let e {
                        self.log("ping failed: \(e.localizedDescription)")
                        self.handleDrop(authFailure: false)
                    }
                }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func log(_ s: String) {
        if verbose { fputs("[realtime] \(s)\n", stderr) }
    }
}
