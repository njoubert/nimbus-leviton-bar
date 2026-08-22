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
/// A ping every 30 s keeps it alive; drops are routine and reconnect with backoff. An auth
/// rejection (close 1008, or "unauthorized" in the reason) backs off for an hour — the REST
/// poll is the safety net, and repeated bad logins lock the account.
///
/// `onUpdate` is called on the main queue.
final class LevitonRealtime: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {

    static let url = URL(string: "wss://my.leviton.com/socket/websocket")!
    static let pingInterval: TimeInterval = 30

    var onUpdate: ((String, LevitonClient.DeviceFields) -> Void)?
    /// Log every frame to stderr (`--watch`).
    var verbose = false

    private let session: Keychain.Session
    private var deviceIds: Set<String>
    private let queue = DispatchQueue(label: "leviton.realtime")
    private lazy var urlSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?
    private var ready = false
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
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
    }

    private func reconnect(after delay: TimeInterval) {
        guard !stopped else { return }
        log("reconnecting in \(Int(delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
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
            t.sendPing { e in
                if let e { self.queue.async { self.log("ping failed: \(e.localizedDescription)"); self.handleDrop(authFailure: false) } }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func log(_ s: String) {
        if verbose { fputs("[realtime] \(s)\n", stderr) }
    }
}
