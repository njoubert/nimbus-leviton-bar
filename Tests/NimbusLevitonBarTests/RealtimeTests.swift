// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import NimbusLevitonBar

/// `LevitonRealtime` against a real websocket — `LocalWebSocketServer` on 127.0.0.1, speaking
/// My Leviton's push protocol back at it. Nothing here touches the network, the Keychain or a
/// device; the only server involved is the one the test started three lines earlier.
///
/// The timing knobs (`pingInterval`, `pongTimeout`, `authBackoff`) are turned down to
/// milliseconds, which is how the pong timeout was measured by hand (CLAUDE.md) before there
/// was a test for it. The reconnect backoff itself is not injectable: it starts at 1 s, so
/// every reconnect test is built around that one second.
///
/// **What this file pins that the docs get wrong:** an auth close (1008) does *not* reach the
/// hour-long backoff. See `testAuthCloseTakesTheOrdinaryBackoff`.
@MainActor
final class RealtimeTests: XCTestCase {

    // MARK: Handshake

    func testHandshakeSendsTheTokenThenSubscribesOnReady() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, ids: ["1613723", "471125"], token: "tok-handshake", recorder: rec)
        defer { rt.stop() }

        rt.start()
        await waitUntil("the token frame") { server.tokenFrames.count == 1 }

        // The token *record*, not just the id — the server wants what the login reply gave us.
        let token = try XCTUnwrap(server.tokenFrames.first)
        XCTAssertEqual(token["id"] as? String, "tok-handshake")
        XCTAssertEqual(token["userId"] as? Int, 7, "userId goes on the wire as an Int, not a string")
        XCTAssertNil(token["userId"] as? String)
        XCTAssertEqual(token["rememberMe"] as? Bool, true)
        XCTAssertEqual(token["ttl"] as? Int, 5_184_000)
        XCTAssertFalse((token["created"] as? String ?? "").isEmpty)

        // Nothing is subscribed until the server says it is authenticated.
        try await settle()
        XCTAssertEqual(server.subscribeFrames.count, 0, "subscribed before `ready`")
        XCTAssertEqual(rec.liveEvents, [], "went live before `ready`")

        server.sendReady()
        await waitUntil("both subscribes") { server.subscribeFrames.count == 2 }
        await waitUntil("onLive(true)") { rec.liveEvents == [true] }

        XCTAssertEqual(Set(server.subscribedIds), [1_613_723, 471_125])
        for sub in server.subscribeFrames {
            XCTAssertEqual(sub["modelName"] as? String, "IotSwitch")
            XCTAssertNil(sub["modelId"] as? String, "modelId must be an Int on the wire")
        }
    }

    func testChallengeResendsTheToken() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rt = realtime(server)
        defer { rt.stop() }

        rt.start()
        await waitUntil("the first token frame") { server.tokenFrames.count == 1 }

        // The nonce is ignored — by us and by every other client of this API.
        server.sendChallenge()
        await waitUntil("the token frame again") { server.tokenFrames.count == 2 }
        XCTAssertEqual(server.tokenFrames[1]["id"] as? String, server.tokenFrames[0]["id"] as? String)
    }

    /// `status: ready` can arrive twice; the second one must not start a second wave of
    /// subscribes.
    func testDuplicateReadyDoesNotSubscribeTwice() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, ids: ["1", "2"], recorder: rec)
        defer { rt.stop() }

        rt.start()
        await waitUntil("the token frame") { server.tokenFrames.count == 1 }
        server.sendReady()
        await waitUntil("both subscribes") { server.subscribeFrames.count == 2 }

        server.sendReady()
        try await settle()
        XCTAssertEqual(server.subscribeFrames.count, 2, "the second `ready` re-subscribed")
        XCTAssertEqual(rec.liveEvents, [true], "onLive fired again for the same state")
    }

    // MARK: Notifications

    func testNotificationDeliversTheChangedFields() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, ids: ["1613723"], recorder: rec)
        defer { rt.stop() }

        try await handshake(rt, server, subscribes: 1)
        server.sendNotification(modelId: 1_613_723, data: ["power": "ON", "brightness": 40])

        await waitUntil("the update") { rec.updates.count == 1 }
        XCTAssertEqual(rec.updates[0].id, "1613723")
        XCTAssertEqual(rec.updates[0].fields, LevitonClient.DeviceFields(power: true, brightness: 40))
    }

    /// A frame carrying only fields the app doesn't show (the device's rssi, the `chgReason`
    /// the forensics spike reads) parses to an empty `DeviceFields` and must be dropped — and
    /// so must anything that isn't an IotSwitch. Both are checked against a *later* good frame
    /// rather than a sleep: frames arrive in order on one connection, so the good one arriving
    /// proves the bad ones were seen and discarded.
    func testNotificationsWithNothingToShowAreDropped() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, ids: ["1613723"], recorder: rec)
        defer { rt.stop() }

        try await handshake(rt, server, subscribes: 1)
        server.sendNotification(modelId: 1_613_723, data: ["rssi": -54, "chgReason": 3])
        server.sendNotification(modelId: 1_613_723, data: ["power": "ON"], modelName: "Residence")
        server.sendNotification(modelId: 1_613_723, data: ["brightness": 70])

        await waitUntil("the one update we should get") { rec.updates.count >= 1 }
        try await settle()
        XCTAssertEqual(rec.updates.count, 1)
        XCTAssertEqual(rec.updates[0].fields, LevitonClient.DeviceFields(brightness: 70))
    }

    func testSetDeviceIdsSubscribesOnlyTheAddition() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rt = realtime(server, ids: ["1", "2"])
        defer { rt.stop() }

        try await handshake(rt, server, subscribes: 2)

        // 1 goes away, 3 arrives: there is no unsubscribe in this protocol, so the only frame
        // that may go out is the one for 3.
        rt.setDeviceIds(["2", "3"])
        await waitUntil("the third subscribe") { server.subscribeFrames.count == 3 }
        try await settle()
        XCTAssertEqual(server.subscribeFrames.count, 3)
        XCTAssertEqual(server.subscribedIds.last, 3)
    }

    // MARK: Redaction

    /// The token frame is the one thing on this socket that is worth stealing. What is logged
    /// (`--watch`, `--journal`, the Internals panel) is a *rebuilt* frame with the token
    /// fingerprinted; what goes on the wire is the real thing, or the server would reject it.
    func testTokenIsFingerprintedInTheLogAndRawOnTheWire() async throws {
        let secret = "tok-secret-9f3b1d-do-not-log"
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, token: secret, recorder: rec)
        defer { rt.stop() }

        rt.start()
        await waitUntil("the token frame") { server.tokenFrames.count == 1 }
        await waitUntil("the outgoing line to be logged") { rec.log.contains { $0.hasPrefix("→") } }

        let sent = try XCTUnwrap(rec.log.first { $0.hasPrefix("→") })
        XCTAssertFalse(sent.contains(secret), "the raw token was logged: \(sent)")
        XCTAssertTrue(sent.contains(Diagnostics.fingerprint(secret)), "no fingerprint in \(sent)")
        for line in rec.log {
            XCTAssertFalse(line.contains(secret), "the raw token leaked into a log line: \(line)")
        }

        // …and the server really did get the token, fingerprint or no fingerprint.
        XCTAssertEqual(server.tokenFrames[0]["id"] as? String, secret)
    }

    // MARK: Drops and reconnects

    /// One drop, one reconnect. Tearing the task down fails everything outstanding on it — the
    /// pending `receive`, an aborted `sendPing` — and each failure lands back in `handleDrop`;
    /// before the `task != nil` guard a single stall scheduled three reconnects and trebled the
    /// backoff. The log is the witness: `reconnect(after:)` is what writes "reconnecting in N s",
    /// and it must appear exactly once per drop.
    func testOneDropSchedulesExactlyOneReconnect() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, recorder: rec)
        defer { rt.stop() }

        try await handshake(rt, server, subscribes: 1)
        server.dropNewest()

        await waitUntil("onLive(false)") { rec.liveEvents == [true, false] }
        await waitUntil("the reconnect to be scheduled") { !rec.reconnectLines.isEmpty }
        XCTAssertEqual(rec.reconnectLines, ["reconnecting in 1 s"])

        // The backoff is 1 s; give it three before believing it never came.
        await waitUntil("the reconnect", timeout: 3) { server.connectionCount == 2 }
        await waitUntil("the token frame again") { server.tokenFrames.count == 2 }
        server.sendReady()
        await waitUntil("onLive(true) again") { rec.liveEvents == [true, false, true] }

        XCTAssertEqual(rec.reconnectLines.count, 1, "one drop scheduled \(rec.reconnectLines)")
        XCTAssertEqual(server.connectionCount, 2)
        XCTAssertEqual(rec.authBackoffs, 0, "an ordinary drop must not raise the drift warning")
    }

    /// `reconnectNow()` skips the wait (a wake, or the Refresh row), and the timer it pre-empted
    /// must not then fire and kill the connection it just made — `connect()` bumps the
    /// generation and the scheduled block checks it. Without that guard the 1 s timer would
    /// tear this connection down and open a third.
    func testReconnectNowPreemptsTheScheduledReconnect() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, recorder: rec)
        defer { rt.stop() }

        try await handshake(rt, server, subscribes: 1)
        server.dropNewest()
        await waitUntil("onLive(false)") { rec.liveEvents == [true, false] }

        let asked = Date()
        rt.reconnectNow()
        await waitUntil("the immediate reconnect", timeout: 3) { server.connectionCount == 2 }
        XCTAssertLessThan(Date().timeIntervalSince(asked), 0.75,
                          "that looks like the scheduled 1 s reconnect, not an immediate one")

        await waitUntil("the token frame again") { server.tokenFrames.count == 2 }
        server.sendReady()
        await waitUntil("onLive(true) again") { rec.liveEvents == [true, false, true] }

        // Past when the pre-empted timer would have fired: the connection must still be the
        // one `reconnectNow` made, and must still carry frames.
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(server.connectionCount, 2, "the stale timer reconnected on top of us")
        XCTAssertEqual(rec.liveEvents, [true, false, true])
        server.sendNotification(modelId: 1_613_723, data: ["brightness": 55])
        await waitUntil("a frame on the surviving connection") { rec.updates.count == 1 }
        XCTAssertEqual(rec.updates[0].fields, LevitonClient.DeviceFields(brightness: 55))
    }

    // MARK: Pings

    /// A connection that is open but no longer carrying anything — a sleep, a changed network,
    /// a dead NAT mapping — looks healthy to everything except an unanswered ping. Measured
    /// here: with `autoReplyPing` off the server really does see the ping and say nothing, and
    /// URLSession's `sendPing` completion then never fires at all — it *is* the pong handler,
    /// as the production comment says, which is why `pongTimeout` is the whole of the
    /// detection.
    ///
    /// **`pongTimeout` must stay well under `pingInterval`.** Every ping cancels the previous
    /// ping's deadline; set the two equal (0.3/0.3 was the first thing tried here) and each
    /// tick cancels the deadline that was coming due at that same instant, so the timeout never
    /// fires at all. The app's 10 s against 30 s is safely clear of it; these are 0.15 against
    /// 0.45, the same 3:1.
    func testPongTimeoutDropsAHalfOpenConnection() async throws {
        let server = try startedServer(autoReplyPing: false)
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, recorder: rec)
        rt.pingInterval = 0.45
        rt.pongTimeout = 0.15
        defer { rt.stop() }

        try await handshake(rt, server, subscribes: 1)
        await waitUntil("the ping to reach a server that will not answer it", timeout: 3) { server.pings >= 1 }
        await waitUntil("the pong timeout", timeout: 3) { rec.log.contains { $0.contains("pong timed out") } }
        await waitUntil("onLive(false)") { rec.liveEvents == [true, false] }
        await waitUntil("the reconnect", timeout: 4) { server.connectionCount == 2 }
    }

    /// The control for the test above: the same knobs against a server that answers, for long
    /// enough to have dropped three times if a pong were being missed.
    func testAnsweredPingsKeepTheConnection() async throws {
        let server = try startedServer()   // autoReplyPing: the stack answers for the server
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, recorder: rec)
        rt.pingInterval = 0.45
        rt.pongTimeout = 0.15
        defer { rt.stop() }

        try await handshake(rt, server, subscribes: 1)
        try await Task.sleep(nanoseconds: 1_600_000_000)   // three pings' worth

        XCTAssertEqual(rec.liveEvents, [true], "an answered ping dropped the feed")
        XCTAssertEqual(rec.reconnectLines, [])
        XCTAssertEqual(server.connectionCount, 1)
        XCTAssertFalse(rec.log.contains { $0.contains("timed out") })
    }

    // MARK: Auth close — and what actually happens

    /// **An auth close takes `authBackoff`, not the ordinary 1 s.** The delegate's
    /// `didCloseWith` cannot be the carrier — URLSession delivers it *after* failing the
    /// pending `receive` (proved by `testURLSessionDeliversTheCloseCodeOnlyAfterTheReceiveFails`
    /// below), by which point `handleDrop` has torn the task down and the callback is
    /// discarded by its own identity guard. The fix reads `closeCode`/`closeReason` off the
    /// task itself inside `handleDrop`; before it, a 1008 took the ordinary backoff and a dead
    /// token re-sent its frame every ≤60 s.
    ///
    /// `authBackoff` is 2 s here: long enough to prove the 1 s path was not taken, short
    /// enough to watch the reconnect actually happen.
    func testAuthCloseTakesTheAuthBackoff() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, recorder: rec)
        rt.authBackoff = 2
        defer { rt.stop() }

        try await handshake(rt, server, subscribes: 1)
        server.closeNewest(code: .protocolCode(.policyViolation), reason: "unauthorized")

        await waitUntil("the drop") { rec.liveEvents == [true, false] }
        await waitUntil("the reconnect to be scheduled") { !rec.reconnectLines.isEmpty }
        XCTAssertEqual(rec.reconnectLines, ["reconnecting in 2 s"],
                       "a 1008 close must take the auth backoff, not the ordinary 1 s")
        await waitUntil("onAuthBackoff") { rec.authBackoffs == 1 }   // the drift warning's signal
        // Well past the ordinary 1 s backoff: still only the original connection.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(server.connectionCount, 1, "it reconnected on the ordinary backoff")
        await waitUntil("the auth-backoff reconnect", timeout: 3) { server.connectionCount == 2 }
    }

    /// The reason-string path: a close that is not 1008 but says "unauthorized" is an auth
    /// rejection too (the production regex matches unauth|forbidden|401|403).
    func testUnauthorizedReasonAloneTakesTheAuthBackoff() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, recorder: rec)
        rt.authBackoff = 2
        defer { rt.stop() }

        try await handshake(rt, server, subscribes: 1)
        server.closeNewest(code: .protocolCode(.goingAway), reason: "401 unauthorized")

        await waitUntil("the drop") { rec.liveEvents == [true, false] }
        await waitUntil("the reconnect to be scheduled") { !rec.reconnectLines.isEmpty }
        XCTAssertEqual(rec.reconnectLines, ["reconnecting in 2 s"],
                       "an \"unauthorized\" close reason must take the auth backoff")
    }

    /// The evidence for the test above, with no `LevitonRealtime` in the picture: the server's
    /// close frame is well-formed and URLSession *does* hand up code 1008 and the reason — but
    /// only after the pending `receive` has already failed. (With no receive pending at all it
    /// never arrives: URLSession seems to notice the close only while a read is being pumped.)
    func testURLSessionDeliversTheCloseCodeOnlyAfterTheReceiveFails() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let probe = CloseCodeProbe()
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: server.url)
        task.resume()
        task.receive { result in
            if case .failure(let e) = result { probe.note("receive failed: \(e.localizedDescription)") }
        }
        await waitUntil("the socket to open") { probe.notes.contains("open") }

        server.closeNewest(code: .protocolCode(.policyViolation), reason: "unauthorized")
        await waitUntil("the close to be delivered", timeout: 3) { probe.notes.contains { $0.hasPrefix("closed") } }

        let notes = probe.notes
        let close = try XCTUnwrap(notes.firstIndex { $0.hasPrefix("closed") })
        let failed = try XCTUnwrap(notes.firstIndex { $0.hasPrefix("receive failed") })
        XCTAssertEqual(notes[close], "closed 1008 unauthorized")
        XCTAssertLessThan(failed, close, "the receive failure no longer precedes the close")
    }

    // MARK: Stopping

    func testStopEndsItWithNoReconnect() async throws {
        let server = try startedServer()
        defer { server.stop() }
        let rec = Recorder()
        let rt = realtime(server, recorder: rec)

        try await handshake(rt, server, subscribes: 1)
        rt.stop()

        await waitUntil("onLive(false)") { rec.liveEvents == [true, false] }
        // Well past the 1 s backoff a drop would have used.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(server.connectionCount, 1, "it reconnected after stop()")
        XCTAssertEqual(rec.reconnectLines, [])
        XCTAssertEqual(rec.liveEvents, [true, false], "onLive(false) was delivered more than once")
    }

    // MARK: Harness

    /// A server on its own port, stopped again whatever the test does — `defer` in the test and
    /// a teardown block here, since a `waitUntil` that times out fails without unwinding.
    private func startedServer(autoReplyPing: Bool = true) throws -> LocalWebSocketServer {
        let server = try LocalWebSocketServer(autoReplyPing: autoReplyPing)
        try server.start()
        addTeardownBlock { server.stop() }
        return server
    }

    private func realtime(_ server: LocalWebSocketServer, ids: [String] = ["1613723"],
                          token: String = "tok-test-000", recorder: Recorder = Recorder()) -> LevitonRealtime {
        let rt = LevitonRealtime(session: Fixtures.session(token: token), deviceIds: ids, url: server.url)
        rt.onLive = { recorder.live($0) }
        rt.onUpdate = { recorder.update($0, $1) }
        rt.onAuthBackoff = { recorder.authBackoff() }
        rt.logSink = { recorder.log($0) }          // called on the realtime queue — hence the lock
        addTeardownBlock { rt.stop() }
        return rt
    }

    /// start → token → ready → subscribed, the state most of these tests begin in.
    private func handshake(_ rt: LevitonRealtime, _ server: LocalWebSocketServer, subscribes: Int,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        rt.start()
        await waitUntil("the token frame", file: file, line: line) { server.tokenFrames.count == 1 }
        server.sendReady()
        await waitUntil("\(subscribes) subscribe(s)", file: file, line: line) {
            server.subscribeFrames.count == subscribes
        }
    }

    /// Long enough for anything already in flight over loopback to have arrived — the wait
    /// behind every "and then nothing else happened" assertion.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 350_000_000)
    }
}

/// What the callbacks saw. `onUpdate`/`onLive` come in on the main queue and `logSink` on the
/// realtime queue, so this takes a lock and the tests read it from the main actor.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _live: [Bool] = []
    private var _updates: [(id: String, fields: LevitonClient.DeviceFields)] = []
    private var _log: [String] = []
    private var _authBackoffs = 0

    func live(_ b: Bool) { sync { _live.append(b) } }
    func authBackoff() { sync { _authBackoffs += 1 } }
    var authBackoffs: Int { sync { _authBackoffs } }
    func update(_ id: String, _ f: LevitonClient.DeviceFields) { sync { _updates.append((id, f)) } }
    func log(_ s: String) { sync { _log.append(s) } }

    var liveEvents: [Bool] { sync { _live } }
    var updates: [(id: String, fields: LevitonClient.DeviceFields)] { sync { _updates } }
    var log: [String] { sync { _log } }
    /// One per call to `reconnect(after:)` — the count is the single-reconnect guard.
    var reconnectLines: [String] { log.filter { $0.hasPrefix("reconnecting in") } }

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A bare websocket delegate, for the one test that asks what URLSession itself does with a
/// close frame.
private final class CloseCodeProbe: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _notes: [String] = []
    var notes: [String] { lock.lock(); defer { lock.unlock() }; return _notes }
    func note(_ s: String) { lock.lock(); _notes.append(s); lock.unlock() }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        note("open")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        note("closed \(closeCode.rawValue) \(reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")")
    }
}

private extension LocalWebSocketServer {
    /// The `token` object out of every token frame the client sent.
    var tokenFrames: [[String: Any]] { frames.compactMap { $0["token"] as? [String: Any] } }
    /// The `subscription` object out of every subscribe frame.
    var subscribeFrames: [[String: Any]] {
        frames.filter { $0["type"] as? String == "subscribe" }.compactMap { $0["subscription"] as? [String: Any] }
    }
    var subscribedIds: [Int] { subscribeFrames.compactMap { $0["modelId"] as? Int } }
}
