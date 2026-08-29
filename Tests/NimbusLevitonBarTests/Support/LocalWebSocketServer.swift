// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

/// A websocket server on 127.0.0.1 that speaks My Leviton's push protocol back at
/// `LevitonRealtime`: it counts every connection it accepts (which is how the reconnect tests
/// tell one reconnect from three), keeps every text frame the client sent, and can answer with
/// a frame, an abrupt drop, or a close carrying a chosen code.
///
/// `Network.framework` is a system framework, not a new dependency, and its
/// `NWProtocolWebSocket` does the handshake and the framing for us. `autoReplyPing` is the one
/// knob the pong-timeout test turns off: with it on — the default, and what a real server does
/// — the stack answers a ping before we ever see it.
///
/// Everything is under one lock and every callback runs on the server's own queue, because the
/// tests read this from the main actor while the client's realtime queue is driving it.
final class LocalWebSocketServer: @unchecked Sendable {

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let queue = DispatchQueue(label: "test.leviton.wsserver")
    private let lock = NSLock()
    private let listener: NWListener

    private var connections: [NWConnection] = []
    private var _connectionCount = 0
    private var _texts: [String] = []
    private var _pings = 0
    private var _listenerError: Error?

    /// Every text frame as it arrives, on the server queue. The array is kept too — this is for
    /// the tests that want to react rather than poll.
    var onText: ((String) -> Void)?

    private(set) var port: UInt16 = 0

    /// What `LevitonRealtime` should be pointed at. ATS exempts localhost, so plain `ws://`.
    var url: URL { URL(string: "ws://127.0.0.1:\(port)/socket/websocket")! }

    init(autoReplyPing: Bool = true) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bound to the loopback address on purpose: no test in this suite may put a byte on a
        // real network.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = autoReplyPing
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params)
    }

    /// Start listening and block until the port is known — `listener.port` is nil until the
    /// listener reaches `.ready`, and the client cannot be built without it.
    func start(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let e):
                self?.sync { self?._listenerError = e }
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            self.sync {
                self.connections.append(conn)
                self._connectionCount += 1
            }
            conn.stateUpdateHandler = { state in
                if case .failed = state { conn.cancel() }
            }
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            listener.cancel()
            throw Failure(description: "the listener never became ready")
        }
        if let e = (sync { _listenerError }) {
            listener.cancel()
            throw Failure(description: "the listener failed: \(e)")
        }
        guard let p = listener.port?.rawValue, p != 0 else {
            listener.cancel()
            throw Failure(description: "the listener is ready but has no port")
        }
        port = p
    }

    func stop() {
        let open: [NWConnection] = sync {
            let c = connections
            connections.removeAll()
            return c
        }
        for c in open { c.forceCancel() }
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    // MARK: What the client did

    /// How many connections this server has accepted, ever. One reconnect adds exactly one.
    var connectionCount: Int { sync { _connectionCount } }
    /// Every text frame the client has sent, in order.
    var texts: [String] { sync { _texts } }
    /// Ping frames seen — only non-zero when `autoReplyPing` is off, since otherwise the stack
    /// swallows them.
    var pings: Int { sync { _pings } }

    /// The text frames parsed as JSON objects; anything unparseable is dropped rather than
    /// failing here, so the assertion lands in the test that cares.
    var frames: [[String: Any]] {
        texts.compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
    }

    // MARK: What the server says

    @discardableResult
    func send(text: String) -> Bool {
        guard let c = newest else { return false }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        c.send(content: Data(text.utf8), contentContext: ctx, isComplete: true,
               completion: .contentProcessed { _ in })
        return true
    }

    @discardableResult
    func send(json: [String: Any]) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: json),
              let s = String(data: d, encoding: .utf8) else { return false }
        return send(text: s)
    }

    /// `{"type":"status","status":"ready"}` — the frame that authenticates the feed.
    @discardableResult
    func sendReady() -> Bool { send(json: ["type": "status", "status": "ready"]) }

    @discardableResult
    func sendChallenge() -> Bool { send(json: ["type": "challenge", "nonce": "ignored-by-every-client"]) }

    /// A `saved` notification in the shape the live feed sends: partial data, integer modelId.
    @discardableResult
    func sendNotification(modelId: Int, data: [String: Any], modelName: String = "IotSwitch",
                          event: String = "saved") -> Bool {
        send(json: ["type": "notification",
                    "notification": ["event": event, "modelName": modelName,
                                     "modelId": modelId, "data": data]])
    }

    /// Yank the connection out from under the client. `force` skips the close frame entirely —
    /// what a NAT timeout or a killed server looks like from the client's side.
    func dropNewest(force: Bool = false) {
        guard let c = newest else { return }
        if force { c.forceCancel() } else { c.cancel() }
    }

    /// Close with a specific code — `.policyViolation` is 1008, the auth rejection
    /// `handleDrop` backs off an hour for. `reason` rides in the close frame's payload, which is
    /// the other half of that classification (`handleDrop`'s caller regexes it for
    /// "unauth|forbidden|401|403").
    func closeNewest(code: NWProtocolWebSocket.CloseCode = .protocolCode(.policyViolation),
                     reason: String? = nil) {
        guard let c = newest else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = code
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        c.send(content: reason.map { Data($0.utf8) }, contentContext: ctx, isComplete: true,
               completion: .contentProcessed { _ in })
    }

    // MARK: Plumbing

    private var newest: NWConnection? { sync { connections.last } }

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            var done = error != nil
            if let meta = context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text, .binary:
                    if let data, let s = String(data: data, encoding: .utf8) {
                        self.sync { self._texts.append(s) }
                        self.onText?(s)
                    }
                case .ping:
                    self.sync { self._pings += 1 }
                case .close:
                    done = true
                default:
                    break
                }
            }
            guard !done else { return }
            self.receive(on: conn)
        }
    }
}
