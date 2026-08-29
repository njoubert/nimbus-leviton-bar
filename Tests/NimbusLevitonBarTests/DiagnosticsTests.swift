// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusLevitonBar

/// The flight recorder, and above all its redaction: everything the Internals panel shows or
/// copies has to be safe to paste into a bug report, so the password, the 2FA code and the
/// session token are checked here by their absence, not by the shape of what replaces them.
///
/// Every test builds its own `Diagnostics()` rather than using `.shared` — the app's recorder
/// is running from launch and a test that read it would see the other tests' REST traffic.
final class DiagnosticsTests: XCTestCase {

    // MARK: Redaction

    func testRedactedBodyHidesPasswordAndCode() throws {
        let body: [String: Any] = ["email": "a@example.com", "password": "hunter2-SECRET",
                                   "code": "424242", "rememberMe": true]
        let out = try XCTUnwrap(Diagnostics.redactedBody(body, path: "Person/login"))
        XCTAssertFalse(out.contains("hunter2-SECRET"), out)
        XCTAssertFalse(out.contains("424242"), out)
        XCTAssertEqual(out.components(separatedBy: "«hidden»").count - 1, 2, out)
        // Everything else survives — the point of the row is to show what was asked for.
        XCTAssertTrue(out.contains("a@example.com"), out)
        XCTAssertTrue(out.contains("rememberMe"), out)
    }

    func testRedactedBodyLeavesAbsentSecretsAbsent() throws {
        let out = try XCTUnwrap(Diagnostics.redactedBody(["email": "a@example.com"], path: "Person/login"))
        XCTAssertFalse(out.contains("password"), out)
        XCTAssertFalse(out.contains("«hidden»"), out)
    }

    func testRedactedBodyNilForNothingToSay() {
        XCTAssertNil(Diagnostics.redactedBody(nil, path: "Person/login"))
        XCTAssertNil(Diagnostics.redactedBody([:], path: "IotSwitches/5"))
    }

    func testResponseBodyRebuildsTheLoginReply() {
        let token = "tok-LOGIN-SECRET-000"
        let data = try! JSONSerialization.data(withJSONObject: Fixtures.loginReply(token: token))
        let out = Diagnostics.responseBody(data, path: "Person/login")
        XCTAssertFalse(out.contains(token), out)
        XCTAssertTrue(out.contains(Diagnostics.fingerprint(token)), out)
        for kept in ["userId", "ttl", "created"] { XCTAssertTrue(out.contains(kept), out) }
    }

    /// A body we cannot parse is one we cannot redact, so it is withheld whole — the raw
    /// bytes must not reach the detail pane on the off-chance they held the token.
    func testResponseBodyWithholdsAnUnparseableLoginReply() {
        let raw = "<html>tok-LOGIN-SECRET-000 leaked here</html>"
        let out = Diagnostics.responseBody(Data(raw.utf8), path: "Person/login")
        XCTAssertTrue(out.hasPrefix("(login reply withheld:"), out)
        XCTAssertFalse(out.contains("tok-LOGIN-SECRET-000"), out)
        XCTAssertFalse(out.contains("<html>"), out)
    }

    /// Parseable, but the token isn't where it should be: the field is dropped rather than
    /// passed through.
    func testResponseBodyHidesANonStringLoginToken() {
        let data = try! JSONSerialization.data(withJSONObject: ["id": 12345, "userId": 7])
        let out = Diagnostics.responseBody(data, path: "Person/login")
        XCTAssertTrue(out.contains("«hidden»"), out)
        XCTAssertFalse(out.contains("12345"), out)
    }

    func testResponseBodyPassesOtherPathsThrough() {
        let json = #"[{"id":5,"name":"Desk"}]"#
        XCTAssertEqual(Diagnostics.responseBody(Data(json.utf8), path: "Residences/100/iotSwitches"), json)
        XCTAssertEqual(Diagnostics.responseBody(Data(), path: "Residences/100/iotSwitches"), "(empty)")
    }

    func testResponseBodyCapsAHugeReply() {
        let big = String(repeating: "x", count: Diagnostics.detailLimit + 3)
        let out = Diagnostics.responseBody(Data(big.utf8), path: "Residences/100/iotSwitches")
        XCTAssertTrue(out.hasSuffix("\n… (3 more characters)"), String(out.suffix(40)))
    }

    func testFingerprintIsStableShortAndOpaque() {
        let token = "tok-fingerprint-SECRET"
        let f = Diagnostics.fingerprint(token)
        XCTAssertEqual(f, Diagnostics.fingerprint(token))         // deterministic
        XCTAssertEqual(f.count, 7)                                 // "#" + six hex
        XCTAssertTrue(f.hasPrefix("#"), f)
        XCTAssertTrue(f.dropFirst().allSatisfy(\.isHexDigit), f)
        XCTAssertNotEqual(f, Diagnostics.fingerprint(token + "1"))
        XCTAssertFalse(f.contains("tok"), f)
    }

    // MARK: The ring buffer

    func testRecordAssignsIncrementingIds() {
        let d = Diagnostics()
        XCTAssertEqual(d.record(.app, "one"), 1)
        XCTAssertEqual(d.record(.rest, "two"), 2)
        XCTAssertEqual(d.record(.ws, "three"), 3)
        XCTAssertEqual(d.snapshot.map(\.title), ["one", "two", "three"])
        XCTAssertEqual(d.snapshot.map(\.kind), [.app, .rest, .ws])
    }

    func testCapacityEvictsTheOldest() {
        let d = Diagnostics()
        for i in 1...(Diagnostics.capacity + 5) { d.record(.app, "e\(i)") }
        let ids = d.snapshot.map(\.id)
        XCTAssertEqual(ids.count, Diagnostics.capacity)
        XCTAssertEqual(ids.first, 6)                               // 1…5 fell off the front
        XCTAssertEqual(ids.last, Diagnostics.capacity + 5)
    }

    /// Titles are cheap and stay for the whole buffer; the bodies are all of the weight and
    /// only the newest `detailWindow` keep theirs.
    func testOnlyTheNewestEventsKeepTheirBodies() {
        let d = Diagnostics()
        let n = Diagnostics.detailWindow + 50
        for i in 1...n { d.record(.rest, "e\(i)", detail: "body \(i)") }
        let events = d.snapshot
        XCTAssertEqual(events.count, n)
        XCTAssertEqual(events.map(\.title), (1...n).map { "e\($0)" })
        for (i, e) in events.enumerated() {
            if i < 50 { XCTAssertNil(e.detail, "\(e.title) should have lost its body") }
            else { XCTAssertEqual(e.detail, "body \(i + 1)") }
        }
    }

    func testClearEmptiesTheBufferAndBumpsVersion() {
        let d = Diagnostics()
        d.record(.app, "one")
        let before = d.version
        d.clear()
        XCTAssertTrue(d.snapshot.isEmpty)
        XCTAssertGreaterThan(d.version, before)
    }

    // MARK: amend

    func testAmendRetitlesAppendsAndFlagsAnError() {
        let d = Diagnostics()
        let id = d.record(.rest, "GET rooms", detail: "→ GET …")
        d.amend(id, title: "GET rooms  200", append: "← 200", isError: false)
        d.amend(id, append: "extra", isError: true)
        let e = d.snapshot[0]
        XCTAssertEqual(e.title, "GET rooms  200")
        XCTAssertEqual(e.detail, "→ GET …\n\n← 200\n\nextra")     // blank line between parts
        XCTAssertTrue(e.isError)
    }

    func testAmendOnAnEventWithNoBodyStartsOne() {
        let d = Diagnostics()
        let id = d.record(.ws, "frame")
        d.amend(id, append: "the frame")
        XCTAssertEqual(d.snapshot[0].detail, "the frame")
    }

    /// Ids are unique for the life of the recorder, so an amend that arrives after its event
    /// has fallen out of the buffer finds nothing — and changes nothing, `version` included.
    func testAmendOfAnEvictedIdIsASilentNoOp() {
        let d = Diagnostics()
        for i in 1...(Diagnostics.capacity + 5) { d.record(.app, "e\(i)") }
        let before = (version: d.version, events: d.snapshot.count)
        d.amend(1, title: "resurrected", append: "…", isError: true)
        XCTAssertEqual(d.snapshot.count, before.events)
        XCTAssertEqual(d.version, before.version)
        XCTAssertFalse(d.snapshot.contains { $0.title == "resurrected" })
    }

    func testVersionMovesOnWritesAndNotOnReads() {
        let d = Diagnostics()
        var v = d.version
        func bumped(_ what: String, _ change: () -> Void) {
            change()
            XCTAssertGreaterThan(d.version, v, what)
            v = d.version
        }
        bumped("record") { d.record(.app, "one") }
        bumped("amend") { d.amend(1, title: "one!") }
        bumped("feed") { d.feed { $0.frames += 1 } }
        bumped("rest") { d.rest { $0.requests += 1 } }
        bumped("setSession") { d.setSession(Fixtures.session()) }
        _ = d.snapshot; _ = d.feed; _ = d.rest; _ = d.session; _ = d.version
        XCTAssertEqual(d.version, v, "reading must not count as a change")
    }

    // MARK: The session

    func testSetSessionKeepsOnlyAFingerprint() throws {
        let d = Diagnostics()
        let token = "tok-session-SECRET-9"
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        d.setSession(Fixtures.session(token: token, userId: "7", created: created, ttl: 5_184_000))
        let info = try XCTUnwrap(d.session)
        XCTAssertEqual(info.fingerprint, Diagnostics.fingerprint(token))
        XCTAssertEqual(info.userId, "7")
        XCTAssertEqual(info.created, created)
        XCTAssertEqual(info.expiry, created.addingTimeInterval(5_184_000))
        // No field of the record may carry the token, whatever is added to it later.
        for child in Mirror(reflecting: info).children {
            XCTAssertFalse("\(child.value)".contains(token), "\(child.label ?? "?") carries the token")
        }
    }

    func testSetSessionNilClears() {
        let d = Diagnostics()
        d.setSession(Fixtures.session())
        d.setSession(nil)
        XCTAssertNil(d.session)
    }

    // MARK: Formatting

    func testCapTruncatesWithACountAndLeavesShortStringsAlone() {
        let under = String(repeating: "y", count: Diagnostics.detailLimit)
        XCTAssertEqual(Diagnostics.cap(under), under)
        let over = String(repeating: "y", count: Diagnostics.detailLimit + 17)
        let capped = Diagnostics.cap(over)
        XCTAssertTrue(capped.hasSuffix("\n… (17 more characters)"), String(capped.suffix(40)))
        XCTAssertEqual(capped.prefix(Diagnostics.detailLimit), under[...])
    }

    func testPrettyPrintsJSONSortedAndPassesTheRestThrough() throws {
        let out = Diagnostics.pretty(#"{"b":1,"a":2}"#)
        let a = try XCTUnwrap(out.range(of: "\"a\""))
        let b = try XCTUnwrap(out.range(of: "\"b\""))
        XCTAssertLessThan(a.lowerBound, b.lowerBound, out)          // .sortedKeys
        XCTAssertTrue(out.contains("\n"), out)
        let notJSON = "504 Gateway Time-out\n<html>…"
        XCTAssertEqual(Diagnostics.pretty(notJSON), notJSON)
        XCTAssertEqual(Diagnostics.pretty(""), "")
    }

    // MARK: Websocket frame summaries

    func testFrameSummaryNamesTheTokenFrameWithoutTheToken() {
        let frame = #"{"token":{"id":"tok-frame-SECRET","userId":7,"ttl":5184000}}"#
        let out = Diagnostics.frameSummary(frame, outgoing: true)
        XCTAssertEqual(out, "→ token")
        XCTAssertFalse(out.contains("tok-frame-SECRET"))
    }

    func testFrameSummaryOfTheProtocolFrames() {
        XCTAssertEqual(Diagnostics.frameSummary(
            #"{"type":"subscribe","subscription":{"modelName":"IotSwitch","modelId":123}}"#, outgoing: true),
            "→ subscribe 123")
        XCTAssertEqual(Diagnostics.frameSummary(#"{"type":"status","status":"ready"}"#, outgoing: false),
                       "← status ready")
        XCTAssertEqual(Diagnostics.frameSummary(#"{"type":"challenge","nonce":"abc"}"#, outgoing: false),
                       "← challenge")
    }

    func testFrameSummaryOfANotificationShowsTheFields() {
        let frame = #"{"type":"notification","notification":{"event":"saved","modelId":5,"data":{"power":"ON","brightness":40}}}"#
        XCTAssertEqual(Diagnostics.frameSummary(frame, outgoing: false), "← saved 5 ON 40%")
    }

    /// A frame that changes nothing we model (an rssi report, a `lastUpdated` bump) is worth
    /// a line anyway — the keys say what it was about.
    func testFrameSummaryOfANotificationWeModelNothingOfListsTheKeys() {
        let frame = #"{"type":"notification","notification":{"event":"saved","modelId":5,"data":{"rssi":-50,"lastUpdated":"2026-08-29T00:00:00.000Z"}}}"#
        XCTAssertEqual(Diagnostics.frameSummary(frame, outgoing: false), "← saved 5 lastUpdated,rssi")
    }

    func testFrameSummaryOfNonJSONIsOneClampedLine() {
        XCTAssertEqual(Diagnostics.frameSummary("hello\nworld", outgoing: false), "← hello world")
        let long = String(repeating: "z", count: 150)
        let out = Diagnostics.frameSummary(long, outgoing: true)
        XCTAssertEqual(out, "→ " + String(repeating: "z", count: 110) + "…")
    }

    // MARK: REST plumbing

    func testRequestRoundTripCountsAndStaysOneRow() throws {
        let d = Diagnostics()
        let url = URL(string: "https://my.leviton.com/api/Person/login?include=user")!
        let id = d.beginRequest(method: "POST", url: url, path: "Person/login",
                                body: ["email": "a@example.com", "password": "hunter2-SECRET"])
        XCTAssertEqual(d.rest.requests, 1)
        XCTAssertEqual(d.rest.inFlight, 1)
        XCTAssertEqual(d.rest.failures, 0)
        XCTAssertFalse(try XCTUnwrap(d.snapshot[0].detail).contains("hunter2-SECRET"))

        // A retry is a note on the same row, not a second row.
        d.noteRetry(id, "502 from the gateway")
        XCTAssertEqual(d.snapshot.count, 1)
        XCTAssertTrue(try XCTUnwrap(d.snapshot[0].detail).contains("502 from the gateway, retrying"))

        let body = try! JSONSerialization.data(withJSONObject: Fixtures.loginReply())
        d.endRequest(id, method: "POST", path: "Person/login", url: url, status: 200,
                     started: Date(), data: body)
        XCTAssertEqual(d.snapshot.count, 1)
        XCTAssertEqual(d.rest.inFlight, 0)
        XCTAssertEqual(d.rest.bytesIn, body.count)
        XCTAssertEqual(d.rest.failures, 0)
        XCTAssertNotNil(d.rest.lastDuration)
        let e = d.snapshot[0]
        XCTAssertTrue(e.title.contains("POST Person/login?include=user"), e.title)
        XCTAssertTrue(e.title.contains("200"), e.title)
        XCTAssertFalse(e.isError)
        XCTAssertFalse(try XCTUnwrap(e.detail).contains("tok-test-000"))   // the login reply, rebuilt
    }

    func testAFailedStatusCountsAsAFailure() {
        let d = Diagnostics()
        let url = URL(string: "https://my.leviton.com/api/Residences/100/iotSwitches")!
        let id = d.beginRequest(method: "GET", url: url, path: "Residences/100/iotSwitches", body: nil)
        d.endRequest(id, method: "GET", path: "Residences/100/iotSwitches", url: url, status: 401,
                     started: Date(), data: Data("{}".utf8))
        XCTAssertEqual(d.rest.failures, 1)
        XCTAssertEqual(d.rest.inFlight, 0)
        XCTAssertTrue(d.snapshot[0].isError)
        XCTAssertTrue(d.snapshot[0].title.contains("401"), d.snapshot[0].title)
    }

    func testFailRequestNamesTheReasonAndClearsInFlight() {
        let d = Diagnostics()
        let url = URL(string: "https://my.leviton.com/api/Residences/100/iotSwitches")!
        let id = d.beginRequest(method: "GET", url: url, path: "Residences/100/iotSwitches", body: nil)
        let offline = URLError(.notConnectedToInternet)
        d.failRequest(id, method: "GET", path: "Residences/100/iotSwitches", url: url,
                      started: Date(), error: offline)
        XCTAssertEqual(d.rest.requests, 1)
        XCTAssertEqual(d.rest.failures, 1)
        XCTAssertEqual(d.rest.inFlight, 0)
        let e = d.snapshot[0]
        XCTAssertTrue(e.isError)
        XCTAssertTrue(e.title.contains("✗ offline"), e.title)
    }

    func testAbandonedRequestClearsInFlightWithoutCountingAFailure() {
        let d = Diagnostics()
        let url = URL(string: "https://my.leviton.com/api/Residences/100/iotSwitches")!
        let id = d.beginRequest(method: "GET", url: url, path: "Residences/100/iotSwitches", body: nil)
        d.abandonRequest(id, method: "GET", path: "Residences/100/iotSwitches", url: url, started: Date())
        XCTAssertEqual(d.rest.inFlight, 0)
        XCTAssertEqual(d.rest.failures, 0)
        XCTAssertTrue(d.snapshot[0].title.contains("abandoned"), d.snapshot[0].title)
    }
}
