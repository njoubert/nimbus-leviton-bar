// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// LG's Simple Service Access Protocol: JSON frames over a websocket at `wss://<tv>:3001`.
/// Unofficial, entirely community reverse-engineering — see docs/lg-tv-plan.md for sources.
///
/// The shape of it:
///
///   → {"type":"register","id":"register-0","payload":{"pairingType":"PROMPT","manifest":…,
///        "client-key":<if we have one>}}
///   ← {"type":"response","id":"register-0","payload":{"pairingType":"PROMPT","returnValue":true}}
///        …the television now shows a prompt; nothing else arrives until someone accepts it…
///   ← {"type":"registered","id":"register-0","payload":{"client-key":"…"}}
///   → {"id":"req-1","type":"request","uri":"ssap://…","payload":{…}}
///   ← {"id":"req-1","type":"response","payload":{"returnValue":true,…}}
///
/// **Unlike Leviton's feed this socket is the only transport**: reads, writes and
/// subscriptions all share it, so every request carries an `id` and its answer comes back
/// asynchronously bearing that id. Hence the pending table below, which `LevitonRealtime` has
/// no need of — it fires subscriptions and forgets them.
///
/// Two protocol details that a naive implementation gets wrong:
///
/// * **Register answers twice.** The first `response` only reports which pairing style is in
///   play; the registration itself is the later `registered` frame, and between the two sits a
///   human with a remote control. So the register continuation must survive its first answer.
/// * **A subscription reuses its id forever.** Every update arrives as another frame under the
///   original request's id, so its handler must not be removed the way a request's is.
final class SSAPSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {

    /// Per-request deadline. The socket is the only transport, so a request that is never
    /// answered would otherwise hang the CLI forever.
    static let requestTimeout: TimeInterval = 10

    /// Log every frame, in and out, with the client-key redacted.
    var verbose = false
    /// Called for each subscription update, with the request's id.
    var onEvent: ((String, [String: Any]) -> Void)?

    /// The leaf certificate we were shown, as a SHA-256 fingerprint. The eventual app pins
    /// this on first pair; the spike only prints it, so that we know pinning is feasible.
    private(set) var certificateFingerprint: String?
    private(set) var certificateSubject: String?

    private var urlSession: URLSession!
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var counter = 0
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var subscriptions: Set<String> = []
    /// Called when the television confirms it is showing a pairing prompt — the moment the
    /// wait stops being "will this be refused?" and starts being "will someone press accept?".
    private var prompts: [String: (@Sendable (String) -> Void)?] = [:]
    private var opened: CheckedContinuation<Void, Error>?
    private var closed = false

    enum Failure: LocalizedError {
        case notConnected
        case handshake(String)
        case remote(String)
        case timeout(String)
        case badFrame(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "not connected"
            case .handshake(let why): return "websocket handshake failed: \(why)"
            case .remote(let why): return "the TV refused: \(why)"
            case .timeout(let what): return "the TV did not answer \(what) in time"
            case .badFrame(let what): return "unreadable frame: \(what)"
            }
        }
    }

    // MARK: - Connecting

    func connect(host: String, port: Int = 3001) async throws {
        // A session of its very own, so the delegate that waives certificate verification for
        // this television can never be reached by a request to anywhere else. The app will
        // want exactly the same separation (see the risks table in the plan).
        urlSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        guard let url = URL(string: "wss://\(host):\(port)/") else { throw Failure.handshake("bad host \(host)") }
        let task = urlSession.webSocketTask(with: url)
        self.task = task
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); opened = continuation; lock.unlock()
            task.resume()
        }
        receiveLoop()
    }

    func disconnect() {
        lock.lock()
        closed = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    // MARK: - Pairing

    /// Send the register handshake and wait for the `registered` frame, returning the
    /// client-key to store. With a key in hand the television answers immediately; without
    /// one it puts a prompt on screen and says nothing until someone presses accept — which is
    /// why `promptTimeout` is minutes, not seconds.
    ///
    /// `onPrompt` fires when the TV has confirmed it is showing that prompt.
    func register(clientKey: String?, variant: SSAPManifest.Variant = .full,
                  promptTimeout: TimeInterval = 180,
                  onPrompt: (@Sendable (String) -> Void)? = nil) async throws -> String {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": SSAPManifest.manifest(variant),
        ]
        if let clientKey { payload["client-key"] = clientKey }
        let id = nextID("register")
        let frame: [String: Any] = ["type": "register", "id": id, "payload": payload]
        note(prompt: onPrompt, for: id)
        let answer = try await withDeadline(promptTimeout, what: "the pairing prompt") {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                self.lock.lock()
                // Deliberately *not* removed on the first answer: the interesting frame is the
                // second one. `deliver` keeps register entries until `registered` or `error`.
                self.pending[id] = { continuation.resume(with: $0) }
                self.lock.unlock()
                do {
                    try self.send(frame)
                } catch {
                    self.fail(id: id, with: error)
                }
            }
        }
        guard let key = answer["client-key"] as? String else {
            throw Failure.badFrame("registered without a client-key: \(answer)")
        }
        return key
    }

    // MARK: - Requests

    @discardableResult
    func request(_ uri: String, payload: [String: Any]? = nil,
                 timeout: TimeInterval = requestTimeout) async throws -> [String: Any] {
        let id = nextID("req")
        var frame: [String: Any] = ["id": id, "type": "request", "uri": uri]
        if let payload { frame["payload"] = payload }
        return try await exchange(id: id, frame: frame, timeout: timeout, what: uri)
    }

    /// Subscribe and hand back the first answer; later updates arrive through `onEvent` under
    /// the same id.
    @discardableResult
    func subscribe(_ uri: String, payload: [String: Any]? = nil,
                   timeout: TimeInterval = requestTimeout) async throws -> (id: String, first: [String: Any]) {
        let id = nextID("sub")
        var frame: [String: Any] = ["id": id, "type": "subscribe", "uri": uri]
        if let payload { frame["payload"] = payload }
        note(subscription: id)
        let first = try await exchange(id: id, frame: frame, timeout: timeout, what: uri)
        return (id, first)
    }

    private func exchange(id: String, frame: [String: Any], timeout: TimeInterval,
                          what: String) async throws -> [String: Any] {
        try await withDeadline(timeout, what: what) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                self.lock.lock()
                self.pending[id] = { continuation.resume(with: $0) }
                self.lock.unlock()
                do { try self.send(frame) } catch { self.fail(id: id, with: error) }
            }
        }
    }

    // MARK: - Frames

    /// Locking is not allowed from an async context, so the lines that need it live in
    /// synchronous helpers rather than inline in `subscribe` and `register`.
    private func note(subscription id: String) {
        lock.lock(); subscriptions.insert(id); lock.unlock()
    }

    private func note(prompt: (@Sendable (String) -> Void)?, for id: String) {
        lock.lock(); prompts[id] = prompt; lock.unlock()
    }

    private func nextID(_ prefix: String) -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private func send(_ frame: [String: Any]) throws {
        lock.lock(); let task = self.task; lock.unlock()
        guard let task else { throw Failure.notConnected }
        let data = try JSONSerialization.data(withJSONObject: frame)
        let text = String(decoding: data, as: UTF8.self)
        if verbose { log("→", frame) }
        task.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            if let id = frame["id"] as? String { self.fail(id: id, with: error) }
        }
    }

    private func receiveLoop() {
        lock.lock(); let task = self.task; lock.unlock()
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lock.lock(); let quiet = self.closed; self.lock.unlock()
                if !quiet { self.failAll(error) }
            case .success(let message):
                switch message {
                case .string(let text): self.deliver(text)
                case .data(let data): self.deliver(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func deliver(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if verbose { FileHandle.standardError.write(Data("← (unparsed) \(text)\n".utf8)) }
            return
        }
        if verbose { log("←", frame) }
        guard let id = frame["id"] as? String else { return }
        let type = frame["type"] as? String ?? ""
        let payload = frame["payload"] as? [String: Any] ?? [:]

        lock.lock()
        let handler = pending[id]
        let isSubscription = subscriptions.contains(id)
        // A register exchange answers twice — the first frame only names the pairing style, so
        // it is reported and the entry kept. A subscription's entry goes once its first answer
        // is delivered, but its updates keep arriving and go to `onEvent`.
        let keepPending = (id.hasPrefix("register") && type == "response")
        if handler != nil && !keepPending { pending.removeValue(forKey: id) }
        lock.unlock()

        if type == "error" {
            let why = frame["error"] as? String ?? "unknown error"
            handler?(.failure(Failure.remote(why)))
            return
        }
        if keepPending {
            lock.lock(); let announce = prompts[id] ?? nil; lock.unlock()
            announce?(payload["pairingType"] as? String ?? "PROMPT")
            return
        }
        if let handler {
            handler(.success(payload))
        } else if isSubscription {
            onEvent?(id, payload)
        }
    }

    private func fail(id: String, with error: Error) {
        lock.lock(); let handler = pending.removeValue(forKey: id); lock.unlock()
        handler?(.failure(error))
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let handlers = pending.values
        pending.removeAll()
        lock.unlock()
        for handler in handlers { handler(.failure(error)) }
    }

    /// A ceiling on any await. Without it a request the TV simply never answers — which is the
    /// normal shape of "the picture mode has locked this control" — hangs the process.
    private func withDeadline<T: Sendable>(_ seconds: TimeInterval, what: String,
                                           _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Failure.timeout(what)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timeout(what) }
            return first
        }
    }

    // MARK: - Logging, with the one secret held back

    /// A client-key is a credential: whoever holds it drives the television. It is never
    /// printed, in either direction — a frame carrying one is rebuilt with a fingerprint in
    /// its place, the same trick `LevitonRealtime.send` uses for the token frame.
    private func log(_ arrow: String, _ frame: [String: Any]) {
        var shown = frame
        if var payload = shown["payload"] as? [String: Any] {
            if let key = payload["client-key"] as? String { payload["client-key"] = "<key \(SSAPSession.fingerprint(key))>" }
            // The manifest is 40 lines of boilerplate and identical every time.
            if payload["manifest"] != nil { payload["manifest"] = "<manifest>" }
            shown["payload"] = payload
        }
        let text = (try? JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\(shown)"
        FileHandle.standardError.write(Data("\(arrow) \(text)\n".utf8))
    }

    /// Six hex of SHA-256 — enough to see that a key changed, useless to anyone who sees it.
    /// Same convention as the app's `Diagnostics.fingerprint`.
    static func fingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock(); let continuation = opened; opened = nil; lock.unlock()
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        failAll(Failure.handshake("closed (\(closeCode.rawValue)) \(why)"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock(); let continuation = opened; opened = nil; let quiet = closed; lock.unlock()
        continuation?.resume(throwing: error)
        if !quiet { failAll(error) }
    }

    /// The television presents a certificate for `CN=LGE TV SSG` issued by an LG intermediate
    /// CA — not in any trust store, and not matching the address we dialled, so verification
    /// cannot succeed and there is nothing to configure that would make it. **The spike waives
    /// it and records what it was shown.** The app must not do that: it pins this fingerprint
    /// on first pair and refuses anything else, on a URLSession that can reach nothing but the
    /// television.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            let der = SecCertificateCopyData(leaf) as Data
            certificateFingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            certificateSubject = SecCertificateCopySubjectSummary(leaf) as String?
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
