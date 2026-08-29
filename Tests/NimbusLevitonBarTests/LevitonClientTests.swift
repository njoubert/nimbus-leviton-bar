// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusLevitonBar

/// The HTTP contract: the real `LevitonClient` against a `URLProtocol` stand-in for
/// my.leviton.com. Everything here pins a fact about the wire that was measured against the
/// live account (CLAUDE.md, "The My Leviton API") — the bare `Authorization` token, the
/// LoopBack error envelope, the one-shot gateway retry, the JSON-string-inside-JSON shapes.
/// Nothing reaches the network and nothing touches the Keychain.
final class LevitonClientTests: XCTestCase {

    // MARK: Helpers

    /// One canned reply on an ordinary authed GET, and the `Error` it maps to. `rooms` stands
    /// in for "any call": the mapping lives in `request`, not in the caller.
    private func roomsFailure(_ reply: MockHTTP.Reply,
                              file: StaticString = #filePath, line: UInt = #line) async -> LevitonClient.Error? {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms", reply)
        do {
            _ = try await client.rooms(Fixtures.session(), residenceId: "100")
            XCTFail("expected a throw", file: file, line: line)
            return nil
        } catch let e as LevitonClient.Error {
            return e
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
            return nil
        }
    }

    /// Whatever the call threw, untyped — for the transport failures that surface as `URLError`.
    private func failure<T>(file: StaticString = #filePath, line: UInt = #line,
                            _ body: () async throws -> T) async -> Swift.Error? {
        do {
            _ = try await body()
            XCTFail("expected a throw", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Wire shape

    /// `Authorization: <token>` — bare, no "Bearer". A GET carries no body and no Content-Type.
    func testAuthorizationHeaderIsTheBareToken() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms", .json(200, [Fixtures.room(id: 1, name: "Alcove")]))
        _ = try await client.rooms(Fixtures.session(token: "abc123"), residenceId: "100")

        let req = http.requests("GET", "Residences/100/residentialRooms")[0]
        XCTAssertEqual(req.headers["Authorization"], "abc123")
        XCTAssertNil(req.headers["Content-Type"])
        XCTAssertNil(req.bodyData)
    }

    func testWritesCarryJSONContentType() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("PUT", "IotSwitches/5", .json(200, Fixtures.iotSwitch(id: 5, name: "Desk")))
        http.stub("POST", "ResidentialRooms/turnOn", .json(200, [String: Any]()))
        _ = try await client.update(Fixtures.session(), deviceId: "5", fields: .init(power: true))
        try await client.setRoomPower(Fixtures.session(), roomId: "9", on: true)

        XCTAssertEqual(http.requests("PUT", "IotSwitches/5")[0].headers["Content-Type"], "application/json")
        XCTAssertEqual(http.requests("POST", "ResidentialRooms/turnOn")[0].headers["Content-Type"], "application/json")
    }

    /// The login body is fixed (`loggedInVia`/`rememberMe` are what the web app sends), the
    /// `include=user` is in the query, and the one request that must *not* be authenticated
    /// isn't.
    func testLoginRequestShape() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("POST", "Person/login", .json(200, Fixtures.loginReply()))
        _ = try await client.login(email: "a@b.com", password: "secret")

        let req = http.requests("POST", "Person/login")[0]
        XCTAssertNil(req.headers["Authorization"])
        XCTAssertEqual(req.headers["Content-Type"], "application/json")
        XCTAssertEqual(req.query["include"], "user")
        XCTAssertEqual(req.body?["email"] as? String, "a@b.com")
        XCTAssertEqual(req.body?["password"] as? String, "secret")
        XCTAssertEqual(req.body?["loggedInVia"] as? String, "myLeviton")
        XCTAssertEqual(req.body?["rememberMe"] as? Bool, true)
        XCTAssertNil(req.body?["code"])
        XCTAssertEqual(req.body?.count, 4)
    }

    func testLoginSendsCodeOnlyWhenGiven() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("POST", "Person/login", .json(200, Fixtures.loginReply()))
        _ = try await client.login(email: "a@b.com", password: "secret", code: "123456")

        XCTAssertEqual(http.requests("POST", "Person/login")[0].body?["code"] as? String, "123456")
    }

    // MARK: login()

    func testLoginParsesTheSession() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("POST", "Person/login", .json(200, Fixtures.loginReply(token: "tok-9", userId: 4242)))
        let s = try await client.login(email: "a@b.com", password: "pw")

        XCTAssertEqual(s.token, "tok-9")
        XCTAssertEqual(s.userId, "4242")            // an Int on the wire, a String here
        XCTAssertEqual(s.ttl, 5_184_000)            // 60 days, measured 2026-08-24
        XCTAssertEqual(s.created, Date(timeIntervalSince1970: 1_787_565_600))   // 2026-08-24T10:00:00Z
    }

    /// `ttl` is read as a Double first, an Int second, so either wire type lands.
    func testLoginAcceptsAFractionalTtl() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("POST", "Person/login",
                  .json(200, ["id": "tok", "userId": 7, "ttl": 1200.5,
                              "created": "2026-08-24T10:00:00.250Z"] as [String: Any]))
        let s = try await client.login(email: "a@b.com", password: "pw")

        XCTAssertEqual(s.ttl, 1200.5)
        XCTAssertEqual(s.created, Date(timeIntervalSince1970: 1_787_565_600.25))
    }

    /// No `created` → now. So does a `created` **without** fractional seconds: the formatter
    /// is built `.withFractionalSeconds`, which is all this account has ever sent, but a
    /// server that dropped the milliseconds would silently reset the session's clock rather
    /// than fail. Pinned as it behaves, not as it reads.
    func testLoginWithoutAParsableCreatedFallsBackToNow() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("POST", "Person/login", .json(200, ["id": "tok", "userId": 7, "ttl": 60] as [String: Any]))
        let missing = try await client.login(email: "a@b.com", password: "pw")
        XCTAssertLessThan(abs(missing.created.timeIntervalSinceNow), 5)

        let (client2, http2) = MockHTTP.makeClient()
        http2.stub("POST", "Person/login",
                   .json(200, ["id": "tok", "userId": 7, "created": "2026-08-24T10:00:00Z"] as [String: Any]))
        let unparsable = try await client2.login(email: "a@b.com", password: "pw")
        XCTAssertLessThan(abs(unparsable.created.timeIntervalSinceNow), 5)
        XCTAssertNil(unparsable.ttl)
    }

    /// A 401 means "session rejected" everywhere else; on the login call itself it can only
    /// mean the password, so `login` remaps it. The store shows a different message for each.
    func testLoginRemaps401ToBadCredentials() async {
        let (client, http) = MockHTTP.makeClient()
        http.stub("POST", "Person/login",
                  .json(401, Fixtures.loopbackError(status: 401, message: "login failed", code: "LOGIN_FAILED")))
        let e = await failure { try await client.login(email: "a@b.com", password: "wrong") }
        XCTAssertEqual(e as? LevitonClient.Error, .badCredentials)
    }

    /// A 200 that isn't the reply we expect is a `malformed("login")`, not a crash — including
    /// the case where `id` is there but is not a string.
    func testLoginMalformedReply() async {
        let (client, http) = MockHTTP.makeClient()
        http.stub("POST", "Person/login", .json(200, ["ttl": 60, "userId": 7] as [String: Any]))
        let noId = await failure { try await client.login(email: "a@b.com", password: "pw") }
        XCTAssertEqual(noId as? LevitonClient.Error, .malformed("login"))

        let (client2, http2) = MockHTTP.makeClient()
        http2.stub("POST", "Person/login", .json(200, ["id": 12345, "userId": 7] as [String: Any]))
        let numericId = await failure { try await client2.login(email: "a@b.com", password: "pw") }
        XCTAssertEqual(numericId as? LevitonClient.Error, .malformed("login"))
    }

    // MARK: Error mapping

    /// The statuses that mean something specific. 403 splits on the message: only "too many"
    /// is the account lockout, anything else is just a rejected session.
    func testAuthStatusesMapToTheirOwnErrors() async {
        var e = await roomsFailure(.json(401, Fixtures.loopbackError(status: 401, message: "Authorization Required")))
        XCTAssertEqual(e, .unauthorized)

        e = await roomsFailure(.json(403, Fixtures.loopbackError(status: 403, message: "Too many failed attempts")))
        XCTAssertEqual(e, .lockedOut)

        e = await roomsFailure(.json(403, Fixtures.loopbackError(status: 403, message: "Access denied")))
        XCTAssertEqual(e, .unauthorized)

        e = await roomsFailure(.json(406, Fixtures.loopbackError(status: 406, message: "Verification code required")))
        XCTAssertEqual(e, .twoFactorRequired)

        e = await roomsFailure(.json(406, Fixtures.loopbackError(status: 406, message: "Two Factor authentication")))
        XCTAssertEqual(e, .twoFactorRequired)

        e = await roomsFailure(.json(408, Fixtures.loopbackError(status: 408, message: "code expired")))
        XCTAssertEqual(e, .badTwoFactorCode)

        // 406 without either word is not the 2FA case; it falls through to .server.
        e = await roomsFailure(.json(406, Fixtures.loopbackError(status: 406, message: "Not Acceptable")))
        XCTAssertEqual(e, .server(406, "Not Acceptable"))
    }

    /// Anything else is `.server(status, message)`: the LoopBack envelope's message, with its
    /// `code` appended when there is one, and the localized status string when there is no
    /// envelope at all.
    func testOtherFailuresCarryTheEnvelopeMessage() async {
        var e = await roomsFailure(.json(500, Fixtures.loopbackError(status: 500, message: "Boom", code: "MODEL_ERR")))
        XCTAssertEqual(e, .server(500, "Boom [MODEL_ERR]"))

        e = await roomsFailure(.json(500, Fixtures.loopbackError(status: 500, message: "Boom")))
        XCTAssertEqual(e, .server(500, "Boom"))

        e = await roomsFailure(.json(500, ["nothing": "useful"]))
        XCTAssertEqual(e, .server(500, HTTPURLResponse.localizedString(forStatusCode: 500)))

        e = await roomsFailure(.data(500, Data("<html>gateway</html>".utf8)))
        XCTAssertEqual(e, .server(500, HTTPURLResponse.localizedString(forStatusCode: 500)))
    }

    /// A 200 whose body isn't JSON becomes `NSNull`, which the list/object accessors reject —
    /// so an HTML error page served with a 200 reads as `malformed`, named for the path.
    func testNonJSONSuccessBodyIsMalformed() async {
        let e = await roomsFailure(.data(200, Data("<html>not json</html>".utf8)))
        XCTAssertEqual(e, .malformed("Residences/100/residentialRooms"))
    }

    // MARK: Retry policy

    /// A gateway hiccup is retried exactly once, and the retry's answer is the one returned.
    func testGatewayFailureIsRetriedOnce() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms",
                  .json(503, Fixtures.loopbackError(status: 503, message: "unavailable")))
        http.stub("GET", "Residences/100/residentialRooms", .json(200, [Fixtures.room(id: 1, name: "Alcove")]))

        let rooms = try await client.rooms(Fixtures.session(), residenceId: "100")
        XCTAssertEqual(rooms.map(\.name), ["Alcove"])
        XCTAssertEqual(http.requests("GET", "Residences/100/residentialRooms").count, 2)
    }

    /// …and only once. The second 503 is the answer, not the trigger for a third attempt.
    func testASecondGatewayFailureIsNotRetriedAgain() async {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms",
                  .json(503, Fixtures.loopbackError(status: 503, message: "unavailable")))

        let e = await failure { try await client.rooms(Fixtures.session(), residenceId: "100") }
        XCTAssertEqual(e as? LevitonClient.Error, .server(503, "unavailable"))
        XCTAssertEqual(http.requests("GET", "Residences/100/residentialRooms").count, 2)
    }

    /// The retry window is 502…504, not 503 alone.
    func testA504IsRetriedToo() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms",
                  .json(504, Fixtures.loopbackError(status: 504, message: "gateway timeout")))
        http.stub("GET", "Residences/100/residentialRooms", .json(200, [Fixtures.room(id: 1, name: "Alcove")]))

        let rooms = try await client.rooms(Fixtures.session(), residenceId: "100")
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(http.requests("GET", "Residences/100/residentialRooms").count, 2)
    }

    /// A keep-alive the server closed under us is the other retryable failure — and it goes
    /// straight round again, without the gateway path's 800 ms pause.
    func testDroppedKeepAliveIsRetriedOnce() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms", .error(.networkConnectionLost))
        http.stub("GET", "Residences/100/residentialRooms", .json(200, [Fixtures.room(id: 1, name: "Alcove")]))

        let rooms = try await client.rooms(Fixtures.session(), residenceId: "100")
        XCTAssertEqual(rooms.count, 1)
        XCTAssertEqual(http.requests("GET", "Residences/100/residentialRooms").count, 2)
    }

    /// Twice is a real network problem: the `URLError` surfaces unmapped, for the caller to
    /// show as it is.
    func testASecondDroppedConnectionSurfaces() async {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms", .error(.networkConnectionLost))

        let e = await failure { try await client.rooms(Fixtures.session(), residenceId: "100") }
        XCTAssertEqual((e as? URLError)?.code, .networkConnectionLost)
        XCTAssertEqual(http.requests("GET", "Residences/100/residentialRooms").count, 2)
    }

    /// Every other transport failure is final on the first attempt — being offline is not a
    /// hiccup, and retrying it would only double the wait.
    func testOtherTransportErrorsAreNotRetried() async {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms", .error(.notConnectedToInternet))

        let e = await failure { try await client.rooms(Fixtures.session(), residenceId: "100") }
        XCTAssertEqual((e as? URLError)?.code, .notConnectedToInternet)
        XCTAssertEqual(http.requests("GET", "Residences/100/residentialRooms").count, 1)
    }

    // MARK: residences()

    /// The owner's case: the account's residences, plus `primaryResidenceId` tried quietly as
    /// an extra because it is not reliably one of them.
    func testAccountResidencesPlusTheQuietPrimaryExtra() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Person/7/residentialPermissions", .json(200, [Fixtures.permissionAccount(55)]))
        http.stub("GET", "ResidentialAccounts/55/residences",
                  .json(200, [Fixtures.residence(id: 100, name: "Home"), Fixtures.residence(id: 101, name: "Loft")]))
        http.stub("GET", "ResidentialAccounts/55", .json(200, ["primaryResidenceId": 200]))
        http.stub("GET", "Residences/200", .json(200, ["name": "Cabin"]))

        let out = try await client.residences(Fixtures.session())
        XCTAssertEqual(out, [ResidenceInfo(id: "100", name: "Home"),
                             ResidenceInfo(id: "101", name: "Loft"),
                             ResidenceInfo(id: "200", name: "Cabin")])
    }

    /// When the primary is already listed it is not fetched at all — the `seen` check comes
    /// before the request, so the common case costs nothing.
    func testAPrimaryAlreadyListedIsNeitherRefetchedNorDuplicated() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Person/7/residentialPermissions", .json(200, [Fixtures.permissionAccount(55)]))
        http.stub("GET", "ResidentialAccounts/55/residences", .json(200, [Fixtures.residence(id: 100, name: "Home")]))
        http.stub("GET", "ResidentialAccounts/55", .json(200, ["primaryResidenceId": 100]))

        let out = try await client.residences(Fixtures.session())
        XCTAssertEqual(out, [ResidenceInfo(id: "100", name: "Home")])
        XCTAssertTrue(http.requests("GET", "Residences/100").isEmpty)
    }

    /// The reason it is quiet: newer accounts 401 on the primary residence
    /// (homebridge-leviton #6). It has to vanish, not fail the whole refresh.
    func testAPrimaryThat401sIsSilentlyDropped() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Person/7/residentialPermissions", .json(200, [Fixtures.permissionAccount(55)]))
        http.stub("GET", "ResidentialAccounts/55/residences", .json(200, [Fixtures.residence(id: 100, name: "Home")]))
        http.stub("GET", "ResidentialAccounts/55", .json(200, ["primaryResidenceId": 200]))
        http.stub("GET", "Residences/200",
                  .json(401, Fixtures.loopbackError(status: 401, message: "Authorization Required")))

        let out = try await client.residences(Fixtures.session())
        XCTAssertEqual(out, [ResidenceInfo(id: "100", name: "Home")])
        XCTAssertEqual(http.requests("GET", "Residences/200").count, 1)   // it was tried, and swallowed
    }

    func testSharedResidenceTakesItsNameFromTheResidence() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Person/7/residentialPermissions", .json(200, [Fixtures.permissionResidence(300)]))
        http.stub("GET", "Residences/300", .json(200, Fixtures.residence(id: 300, name: "Nan's")))

        let out = try await client.residences(Fixtures.session())
        XCTAssertEqual(out, [ResidenceInfo(id: "300", name: "Nan's")])
    }

    /// A share whose residence object we cannot read still appears — the permission is proof
    /// enough that it exists, and its devices are fetched by id.
    func testSharedResidenceFallsBackToAPlaceholderName() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Person/7/residentialPermissions", .json(200, [Fixtures.permissionResidence(300)]))
        http.stub("GET", "Residences/300", .json(500, Fixtures.loopbackError(status: 500, message: "nope")))

        let out = try await client.residences(Fixtures.session())
        XCTAssertEqual(out, [ResidenceInfo(id: "300", name: "Shared home")])
    }

    /// Both permission kinds at once: the union, deduped by id, in the order the permissions
    /// arrived.
    func testResidencesUnionDedupesAndKeepsOrder() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Person/7/residentialPermissions",
                  .json(200, [Fixtures.permissionAccount(55),
                              Fixtures.permissionResidence(100),     // the same residence, shared as well
                              Fixtures.permissionResidence(300)]))
        http.stub("GET", "ResidentialAccounts/55/residences", .json(200, [Fixtures.residence(id: 100, name: "Home")]))
        http.stub("GET", "ResidentialAccounts/55", .json(200, [String: Any]()))   // no primaryResidenceId
        http.stub("GET", "Residences/100", .json(200, Fixtures.residence(id: 100, name: "Home")))
        http.stub("GET", "Residences/300", .json(200, Fixtures.residence(id: 300, name: "Nan's")))

        let out = try await client.residences(Fixtures.session())
        XCTAssertEqual(out, [ResidenceInfo(id: "100", name: "Home"), ResidenceInfo(id: "300", name: "Nan's")])
    }

    // MARK: devices() / rooms()

    func testDevicesMapRecordsAndDropDeletedOnes() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/iotSwitches",
                  .json(200, [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 70,
                                                 canSetLevel: true, minLevel: 5, model: "D26HD",
                                                 roomId: 9, presetLevel: 30),
                              Fixtures.iotSwitch(id: 6, name: "Removed", extra: ["deleted": true]),
                              Fixtures.iotSwitch(id: 7, name: "Porch")]))

        let devices = try await client.devices(Fixtures.session(), residenceId: "100")
        XCTAssertEqual(devices.map(\.id), ["5", "7"])
        let desk = devices[0]
        XCTAssertEqual(desk.name, "Desk")
        XCTAssertEqual(desk.residenceId, "100")
        XCTAssertEqual(desk.roomId, "9")
        XCTAssertTrue(desk.power)
        XCTAssertEqual(desk.brightness, 70)
        XCTAssertEqual(desk.minLevel, 5)
        XCTAssertEqual(desk.maxLevel, 100)
        XCTAssertTrue(desk.canSetLevel)
        XCTAssertEqual(desk.presetLevel, 30)
        XCTAssertEqual(desk.model, "D26HD")
        XCTAssertEqual(desk.version, "1.0.15")
        XCTAssertTrue(desk.connected)
    }

    /// `power` is compared case-insensitively (the API says "ON", but nothing guarantees it),
    /// and a nameless room still gets a label rather than being dropped.
    func testRoomsParseCaseInsensitivePowerAndFallBackOnTheName() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms",
                  .json(200, [["id": 1, "name": "Alcove", "power": "ON"],
                              ["id": 2, "name": "Den", "power": "off"],
                              ["id": 3, "power": "on"],
                              ["id": 4, "name": "Dark"],
                              ["name": "no id at all"]] as [[String: Any]]))

        let rooms = try await client.rooms(Fixtures.session(), residenceId: "100")
        XCTAssertEqual(rooms, [Room(id: "1", name: "Alcove", power: true),
                               Room(id: "2", name: "Den", power: false),
                               Room(id: "3", name: "Room 3", power: true),
                               Room(id: "4", name: "Dark", power: false)])
    }

    // MARK: roomOrders()

    /// The user's room order lives on the *person*, one `Preference` row per residence, with
    /// the id list as a JSON **string** inside the JSON. Rows that don't match the key shape,
    /// or whose value doesn't parse, are skipped rather than throwing.
    func testRoomOrdersParsesOnlyTheRowsItRecognises() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Person/7/preferences",
                  .json(200, [Fixtures.roomOrderPreference(residenceId: 100, roomIds: [3, 1, 2]),
                              // The same prefix covers lists we don't read.
                              ["appId": "DECORA_SMART", "key": "sorting$residence:100$iotSwitches$", "value": "[9]"],
                              ["appId": "DECORA_SMART", "key": "sorting$unassignedRoomIotSwitches", "value": "[9]"],
                              // A value that isn't JSON at all.
                              ["appId": "DECORA_SMART", "key": "sorting$residence:101$rooms", "value": "nope"],
                              // …and a key with no residence id in it.
                              ["appId": "DECORA_SMART", "key": "sorting$residence:$rooms", "value": "[1]"]]
                             as [[String: Any]]))

        let orders = try await client.roomOrders(Fixtures.session())
        XCTAssertEqual(orders, ["100": ["3", "1", "2"]])
    }

    /// If some other client ever wrote the same key, the app's own `DECORA_SMART` row wins —
    /// whichever order the two arrive in.
    func testRoomOrdersPrefersDecoraSmartInEitherOrder() async throws {
        let decora = Fixtures.roomOrderPreference(residenceId: 100, roomIds: [3, 4])
        let other = Fixtures.roomOrderPreference(residenceId: 100, roomIds: [1, 2], appId: "SOME_OTHER_APP")

        for rows in [[other, decora], [decora, other]] {
            let (client, http) = MockHTTP.makeClient()
            http.stub("GET", "Person/7/preferences", .json(200, rows))
            let orders = try await client.roomOrders(Fixtures.session())
            XCTAssertEqual(orders, ["100": ["3", "4"]])
        }
    }

    // MARK: activities()

    /// The `include` pulls the actions in the same request, exactly as the web app spells it.
    /// Button activities belong to a 4-button controller and never reach the menu.
    func testActivitiesSendTheIncludeFilterAndDropButtonActivities() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialActivities",
                  .json(200, [Fixtures.activity(id: 1, name: "Good Night"),
                              Fixtures.activity(id: 2, name: "Button 1", isButtonActivity: true)]))

        let acts = try await client.activities(Fixtures.session(), residenceId: "100")
        XCTAssertEqual(acts.map(\.name), ["Good Night"])
        XCTAssertEqual(http.requests("GET", "Residences/100/residentialActivities")[0].query["filter"],
                       #"{"include":["residentialActions"]}"#)
    }

    /// Both `residentialAction` shapes live on this account: the usual JSON-string blob under
    /// `targetProperty: "properties"`, and a bare property with the value unwrapped (and, for
    /// brightness, stringified). Non-IotSwitch targets are dropped.
    func testActivitiesParseBothActionShapes() async throws {
        var row = Fixtures.activity(id: 8, name: "unused",
                                    actions: [Fixtures.actionProperties(deviceId: 5, power: "ON", brightness: 40),
                                              Fixtures.actionBare(deviceId: 6, property: "power", value: "ON"),
                                              Fixtures.actionBare(deviceId: 7, property: "brightness", value: "40"),
                                              ["targetModelName": "ResidentialRoom", "targetModelId": 9,
                                               "targetProperty": "power", "targetValue": "ON"]])
        row.removeValue(forKey: "name")               // …so the "Scene {id}" fallback shows

        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialActivities", .json(200, [row]))

        let acts = try await client.activities(Fixtures.session(), residenceId: "100")
        XCTAssertEqual(acts, [Activity(id: "8", residenceId: "100", name: "Scene 8", icon: "goodnight",
                                       actions: [SceneAction(deviceId: "5", fields: .init(power: true, brightness: 40)),
                                                 SceneAction(deviceId: "6", fields: .init(power: true)),
                                                 SceneAction(deviceId: "7", fields: .init(brightness: 40))])])
    }

    func testActivitiesNonArrayReplyIsMalformed() async {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialActivities", .json(200, ["count": 0]))

        let e = await failure { try await client.activities(Fixtures.session(), residenceId: "100") }
        XCTAssertEqual(e as? LevitonClient.Error, .malformed("residentialActivities"))
    }

    // MARK: The two server-side switches

    /// Both of these are POSTs with the id in the **query** and an empty JSON object as the
    /// body — the shape the web app uses, not a REST-shaped path parameter.
    func testExecuteActivityPostsTheIdInTheQuery() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("POST", "ResidentialActivities/execute", .json(200, [String: Any]()))
        try await client.executeActivity(Fixtures.session(), id: "12")

        let req = http.requests("POST", "ResidentialActivities/execute")
        XCTAssertEqual(req.count, 1)
        XCTAssertEqual(req[0].query["id"], "12")
        XCTAssertEqual(req[0].bodyData, Data("{}".utf8))
    }

    func testSetRoomPowerPicksTurnOnOrTurnOff() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("POST", "ResidentialRooms/turnOn", .json(200, [String: Any]()))
        http.stub("POST", "ResidentialRooms/turnOff", .json(200, [String: Any]()))
        try await client.setRoomPower(Fixtures.session(), roomId: "9", on: true)
        try await client.setRoomPower(Fixtures.session(), roomId: "9", on: false)

        XCTAssertEqual(http.requests("POST", "ResidentialRooms/turnOn").map { $0.query["id"] }, ["9"])
        XCTAssertEqual(http.requests("POST", "ResidentialRooms/turnOff").map { $0.query["id"] }, ["9"])
        XCTAssertEqual(http.requests("POST", "ResidentialRooms/turnOn")[0].bodyData, Data("{}".utf8))
    }

    // MARK: update() / rawGet()

    /// A PUT carries exactly the fields that were set and nothing else — a toggle must send
    /// `power` alone, or the dimmer's own on-behaviour is overridden.
    func testUpdateSendsOnlyTheSetFields() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("PUT", "IotSwitches/5", .json(200, Fixtures.iotSwitch(id: 5, name: "Desk")))
        _ = try await client.update(Fixtures.session(), deviceId: "5", fields: .init(power: false))
        _ = try await client.update(Fixtures.session(), deviceId: "5", fields: .init(brightness: 55))
        _ = try await client.update(Fixtures.session(), deviceId: "5", fields: .init(power: true, brightness: 55))

        let reqs = http.requests("PUT", "IotSwitches/5")
        XCTAssertEqual(reqs[0].body?.count, 1)
        XCTAssertEqual(reqs[0].body?["power"] as? String, "OFF")
        XCTAssertEqual(reqs[1].body?.count, 1)
        XCTAssertEqual(reqs[1].body?["brightness"] as? Int, 55)
        XCTAssertEqual(reqs[2].body?.count, 2)
        XCTAssertEqual(reqs[2].body?["power"] as? String, "ON")
    }

    /// The reply is the whole record; only our four keys are picked out of it. (What the
    /// record *says* right after an On is not necessarily what the device will settle at —
    /// see the `presetLevel` notes in CLAUDE.md — but that is the store's problem, not this
    /// parser's.)
    func testUpdateParsesTheEcho() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 70, connected: false)))

        let echo = try await client.update(Fixtures.session(), deviceId: "5", fields: .init(power: true))
        XCTAssertEqual(echo, LevitonClient.DeviceFields(power: true, brightness: 70,
                                                        connected: false, name: "Desk"))
    }

    /// `--get` takes a whole path with its query attached; the tail is split off into real
    /// query items so a LoopBack `filter={…}` survives the round trip. The reply comes back
    /// decoded but otherwise untouched.
    func testRawGetSplitsPathFromQuery() async throws {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "a/b", .json(200, ["rows": [1, 2], "name": "x"] as [String: Any]))

        let out = try await client.rawGet(Fixtures.session(), #"a/b?x=1&filter={"include":["c"]}"#)
        let req = http.requests("GET", "a/b")
        XCTAssertEqual(req.count, 1)
        XCTAssertEqual(req[0].query, ["x": "1", "filter": #"{"include":["c"]}"#])
        XCTAssertEqual((out as? [String: Any])?["rows"] as? [Int], [1, 2])
        XCTAssertEqual((out as? [String: Any])?["name"] as? String, "x")
    }
}
