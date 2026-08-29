// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import NimbusLevitonBar

/// `DeviceStore` against a fake my.leviton.com (`MockHTTP`), a fake Keychain
/// (`FakeCredentialStore`) and no websocket at all — `realtimeFactory` is switched off before
/// every `start()`, which is what guarantees nothing in this file opens a socket to the real
/// service or reads the owner's real credentials.
///
/// The store does its work in main-actor Tasks, so nearly every assertion sits behind a
/// `waitUntil`. The one piece of real time that cannot be faked away is `onSettle` (2 s), the
/// gap between the two PUTs of an off→on level change; the two tests that need it are the only
/// slow ones here and the file still runs in well under half a minute.
@MainActor
final class DeviceStoreTests: XCTestCase {

    // MARK: Setup

    /// One healthy residence (100 "Home") under one owned account (55), seen by the session's
    /// user (7). `ResidentialAccounts/55` itself is deliberately left unstubbed: the client
    /// fetches it inside a `try?` for the `primaryResidenceId` quirk, so the mock's 599 there
    /// is exactly the quiet nothing the app already copes with.
    private func stubHome(_ http: MockHTTP, devices: [[String: Any]],
                          rooms: [[String: Any]] = [], activities: [[String: Any]] = [],
                          permissions: [MockHTTP.Reply]? = nil) {
        for r in permissions ?? [.json(200, [Fixtures.permissionAccount(55)])] {
            http.stub("GET", "Person/7/residentialPermissions", r)
        }
        http.stub("GET", "ResidentialAccounts/55/residences", .json(200, [Fixtures.residence(id: 100)]))
        http.stub("GET", "Person/7/preferences", .json(200, []))
        http.stub("GET", "Residences/100/residentialRooms", .json(200, rooms))
        http.stub("GET", "Residences/100/iotSwitches", .json(200, devices))
        http.stub("GET", "Residences/100/residentialActivities", .json(200, activities))
    }

    private func makeStore(session: Keychain.Session? = Fixtures.session(),
                           login: Keychain.Login? = Fixtures.login())
        -> (DeviceStore, MockHTTP, FakeCredentialStore) {
        let (client, http) = MockHTTP.makeClient()
        let creds = FakeCredentialStore(login: login, session: session)
        let store = DeviceStore(client: client, credentials: creds)
        store.realtimeFactory = { _, _ in nil }   // before any start()/refresh(): no real socket
        return (store, http, creds)
    }

    /// The common opening: a signed-in store with `devices` already loaded.
    private func readyStore(devices: [[String: Any]], rooms: [[String: Any]] = [],
                            activities: [[String: Any]] = []) async
        -> (DeviceStore, MockHTTP, FakeCredentialStore) {
        let (store, http, creds) = makeStore()
        stubHome(http, devices: devices, rooms: rooms, activities: activities)
        XCTAssertTrue(store.start())
        await waitUntil("the first fetch") { store.state == .ready }
        return (store, http, creds)
    }

    private func dev(_ store: DeviceStore, _ id: String) -> Device? { store.devices.first { $0.id == id } }

    /// One recorded PUT body, flattened to strings so the *set of keys* is as easy to assert as
    /// the values — the write shapes are about which keys are present at all.
    private func putBody(_ http: MockHTTP, _ deviceId: String, _ n: Int) -> [String: String] {
        let r = http.requests("PUT", "IotSwitches/\(deviceId)")
        guard n < r.count, let b = r[n].body else { return [:] }
        return b.mapValues { "\($0)" }
    }

    private func puts(_ http: MockHTTP, _ deviceId: String) -> Int {
        http.requests("PUT", "IotSwitches/\(deviceId)").count
    }

    private let denied = Fixtures.loopbackError(status: 401, message: "Authorization Required")
    private let boom = Fixtures.loopbackError(status: 500, message: "boom")

    // MARK: Sign-in and start

    func testStartWithSavedSessionLoadsSortsAndRecomputesRoomPower() async {
        // The server calls the room OFF; a device in it is on, so the local recompute wins.
        let (store, _, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Zeta lamp", roomId: 1),
                      Fixtures.iotSwitch(id: 6, name: "alpha lamp", power: "ON", roomId: 1),
                      Fixtures.iotSwitch(id: 7, name: "Mid lamp", roomId: 1)],
            rooms: [Fixtures.room(id: 1, name: "Alcove", power: "OFF")])
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.email, "test@example.com")
        XCTAssertEqual(store.residences.map(\.id), ["100"])
        XCTAssertEqual(store.residences[0].name, "Home")
        XCTAssertEqual(store.devices.map(\.name), ["alpha lamp", "Mid lamp", "Zeta lamp"])
        XCTAssertEqual(store.residences[0].rooms.map(\.power), [true])
        XCTAssertNotNil(store.lastRefresh)
        XCTAssertNil(store.lastError)
        store.stop()
    }

    func testStartWithOnlyASavedLoginSignsInAndSavesTheSessionOnly() async {
        let (store, http, creds) = makeStore(session: nil)
        http.stub("POST", "Person/login", .json(200, Fixtures.loginReply()))
        stubHome(http, devices: [Fixtures.iotSwitch(id: 5, name: "Desk")])
        XCTAssertTrue(store.start())
        await waitUntil("the sign-in and first fetch") { store.state == .ready }
        XCTAssertEqual(http.requests("POST", "Person/login").count, 1)
        XCTAssertEqual(store.devices.map(\.name), ["Desk"])
        // start() replays the password with remember:false — the session is worth caching, the
        // password is already there and must not be rewritten.
        XCTAssertTrue(creds.calls.contains("saveSession"))
        XCTAssertFalse(creds.calls.contains("saveLogin"))
        XCTAssertEqual(creds.session?.token, "tok-test-000")
        store.stop()
    }

    func testStartWithNothingSavedReportsSignedOut() async {
        let (store, _, _) = makeStore(session: nil, login: nil)
        XCTAssertFalse(store.start())
        XCTAssertEqual(store.state, .signedOut)
        store.stop()
    }

    func testSignInWithABadPassword() async {
        let (store, http, creds) = makeStore(session: nil, login: nil)
        http.stub("POST", "Person/login", .json(401, Fixtures.loopbackError(status: 401, message: "login failed")))
        store.signIn(Fixtures.login())
        await waitUntil("the refusal") { store.state != .signingIn }
        XCTAssertEqual(store.state, .error("email or password not accepted"))
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.awaitingCode)
        XCTAssertFalse(creds.calls.contains("saveLogin"))
        store.stop()
    }

    func testSignInThatWantsATwoFactorCodeParksTheLogin() async {
        let (store, http, _) = makeStore(session: nil, login: nil)
        http.stub("POST", "Person/login",
                  .json(406, Fixtures.loopbackError(status: 406, message: "This account requires code")))
        store.signIn(Fixtures.login())
        await waitUntil("the 406") { store.state != .signingIn }
        XCTAssertEqual(store.state, .error("two-factor code required"))
        XCTAssertEqual(store.awaitingCode, Fixtures.login())
        XCTAssertFalse(store.isSignedIn)
        store.stop()
    }

    func testSignInLockout() async {
        let (store, http, _) = makeStore(session: nil, login: nil)
        http.stub("POST", "Person/login",
                  .json(403, Fixtures.loopbackError(status: 403, message: "Too many failed attempts")))
        store.signIn(Fixtures.login())
        await waitUntil("the lockout") { store.state != .signingIn }
        guard case .error(let msg) = store.state else { return XCTFail("expected .error, got \(store.state)") }
        XCTAssertTrue(msg.contains("locked"), msg)
        XCTAssertNil(store.awaitingCode)     // nothing automatic may retry this
        store.stop()
    }

    // MARK: The 401 dance

    func testTokenDeathReplaysThePasswordExactlyOnce() async {
        let (store, http, creds) = await readyStore(devices: [Fixtures.iotSwitch(id: 5, name: "Desk")])
        // From here every permissions read 401s, and the login always works. reset() clears the
        // recorded requests too, so the login count below starts from zero.
        http.reset()
        stubHome(http, devices: [Fixtures.iotSwitch(id: 5, name: "Desk")],
                 permissions: [.json(401, denied)])
        http.stub("POST", "Person/login", .json(200, Fixtures.loginReply()))

        store.refresh()
        await waitUntil("the second rejection") {
            if case .error(let m) = store.state { return m.contains("keeps rejecting") }
            return false
        }
        // One replay, and the 401 that survives it is *not* answered with another login: that
        // is the loop that locks a My Leviton account.
        XCTAssertEqual(http.requests("POST", "Person/login").count, 1)
        XCTAssertEqual(http.requests("GET", "Person/7/residentialPermissions").count, 2,
                       "the fresh token really was tried before giving up")
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(creds.session)
        XCTAssertTrue(creds.calls.contains("deleteSession"))
        // The old device list stays on screen while the session is being sorted out.
        XCTAssertEqual(store.devices.map(\.name), ["Desk"])
        store.stop()
    }

    func testTokenDeathRecoversWhenTheReplayWorks() async {
        let (store, http, creds) = await readyStore(devices: [Fixtures.iotSwitch(id: 5, name: "Desk")])
        http.reset()
        stubHome(http, devices: [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON")],
                 permissions: [.json(401, denied), .json(200, [Fixtures.permissionAccount(55)])])
        http.stub("POST", "Person/login", .json(200, Fixtures.loginReply(token: "tok-fresh")))

        store.refresh()
        await waitUntil("the recovery") { store.state == .ready && store.devices.first?.power == true }
        XCTAssertEqual(http.requests("POST", "Person/login").count, 1)
        XCTAssertEqual(http.requests("GET", "Person/7/residentialPermissions").count, 2)
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(creds.session?.token, "tok-fresh")
        XCTAssertEqual(store.state, .ready)
        store.stop()
    }

    // MARK: Per-residence 401

    private func stubTwoResidences(_ http: MockHTTP, secondReply: MockHTTP.Reply) {
        http.stub("GET", "Person/7/residentialPermissions", .json(200, [Fixtures.permissionAccount(55)]))
        http.stub("GET", "ResidentialAccounts/55/residences",
                  .json(200, [Fixtures.residence(id: 100, name: "Home"), Fixtures.residence(id: 200, name: "Cabin")]))
        http.stub("GET", "Person/7/preferences", .json(200, []))
        for r in ["100", "200"] {
            http.stub("GET", "Residences/\(r)/residentialRooms", r == "100" ? .json(200, []) : secondReply)
            http.stub("GET", "Residences/\(r)/iotSwitches",
                      r == "100" ? .json(200, [Fixtures.iotSwitch(id: 5, name: "Desk")]) : secondReply)
            http.stub("GET", "Residences/\(r)/residentialActivities", r == "100" ? .json(200, []) : secondReply)
        }
    }

    func testOneResidenceThat401sIsSkippedAndNamed() async {
        let (store, http, _) = makeStore()
        stubTwoResidences(http, secondReply: .json(401, denied))
        XCTAssertTrue(store.start())
        await waitUntil("the fetch") { store.state == .ready }
        XCTAssertEqual(store.residences.map(\.id), ["100"])
        XCTAssertEqual(store.lastError, "no access to Cabin")
        XCTAssertTrue(store.isSignedIn)          // one residence's 401 is not the token's fault
        store.stop()
    }

    func testEveryResidence401IsTreatedAsTokenDeath() async {
        // No saved password, so the dance stops at "session expired" instead of replaying.
        let (store, http, creds) = makeStore(login: nil)
        http.stub("GET", "Person/7/residentialPermissions", .json(200, [Fixtures.permissionAccount(55)]))
        http.stub("GET", "ResidentialAccounts/55/residences",
                  .json(200, [Fixtures.residence(id: 100, name: "Home"), Fixtures.residence(id: 200, name: "Cabin")]))
        http.stub("GET", "Person/7/preferences", .json(200, []))
        for r in ["100", "200"] {
            http.stub("GET", "Residences/\(r)/residentialRooms", .json(401, denied))
            http.stub("GET", "Residences/\(r)/iotSwitches", .json(401, denied))
            http.stub("GET", "Residences/\(r)/residentialActivities", .json(401, denied))
        }
        XCTAssertTrue(store.start())
        await waitUntil("the verdict") { store.state != .loading }
        XCTAssertEqual(store.state, .error("session expired"))
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(creds.session)
        XCTAssertEqual(http.requests("POST", "Person/login").count, 0)
        store.stop()
    }

    // MARK: Optimistic writes

    func testFailedWriteSnapsTheRowBackAndNamesTheDevice() async {
        let (store, http, _) = await readyStore(devices: [Fixtures.iotSwitch(id: 5, name: "Desk Lamp")])
        http.stub("PUT", "IotSwitches/5", .json(500, boom))
        var changes = 0
        store.onChange = { changes += 1 }

        store.setPower("5", on: true)
        XCTAssertEqual(dev(store, "5")?.power, true, "the row flips before the request goes out")
        XCTAssertEqual(changes, 1)

        await waitUntil("the rollback") { store.lastError != nil }
        XCTAssertEqual(dev(store, "5")?.power, false)
        XCTAssertEqual(store.lastError, "Desk Lamp: my.leviton.com: 500 boom")
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(store.writesInFlight, 0)
        store.stop()
    }

    // MARK: The three setBrightness shapes

    func testBrightnessOnADeviceAlreadyOnIsOneWrite() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 40, canSetLevel: true)])
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 60, canSetLevel: true)))
        store.setBrightness("5", 60)
        await waitUntil("the write") { store.writesInFlight == 0 }
        XCTAssertEqual(puts(http, "5"), 1)
        XCTAssertEqual(putBody(http, "5", 0), ["brightness": "60"])   // no power key at all
        XCTAssertEqual(dev(store, "5")?.brightness, 60)
        store.stop()
    }

    func testBrightnessOnAnOffDimmerWithAPresetIsTwoWritesASettleApart() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", canSetLevel: true, presetLevel: 30)])
        // The first echo is the lie the preset trap is about: only the last one is trusted.
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 30, canSetLevel: true)))
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 70, canSetLevel: true)))

        store.setBrightness("5", 70)
        await waitUntil("the On") { puts(http, "5") >= 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(puts(http, "5"), 1, "the level must wait for the device to report its preset")

        await waitUntil("the level", timeout: 6) { store.writesInFlight == 0 }
        XCTAssertEqual(puts(http, "5"), 2)
        XCTAssertEqual(putBody(http, "5", 0), ["power": "ON"])
        XCTAssertEqual(putBody(http, "5", 1), ["brightness": "70"])
        XCTAssertEqual(dev(store, "5")?.brightness, 70)
        store.stop()
    }

    func testBrightnessOnAnOffLastLevelDimmerIsOneCombinedWrite() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", canSetLevel: true, presetLevel: 0)])
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 75, canSetLevel: true)))
        store.setBrightness("5", 75)
        await waitUntil("the write") { store.writesInFlight == 0 }
        XCTAssertEqual(puts(http, "5"), 1)
        XCTAssertEqual(putBody(http, "5", 0), ["power": "ON", "brightness": "75"])
        XCTAssertEqual(dev(store, "5")?.brightness, 75)
        store.stop()
    }

    func testBrightnessOnAnOffDimmerWithNoPresetFieldIsTreatedAsHavingOne() async {
        // The deliberate guess: an absent presetLevel counts as a preset, because guessing the
        // other way lands the light on the wrong level.
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", canSetLevel: true, presetLevel: nil)])
        XCTAssertNil(dev(store, "5")?.presetLevel)
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 70, canSetLevel: true)))
        store.setBrightness("5", 70)
        await waitUntil("both writes", timeout: 6) { store.writesInFlight == 0 }
        XCTAssertEqual(puts(http, "5"), 2)
        XCTAssertEqual(putBody(http, "5", 0), ["power": "ON"])
        XCTAssertEqual(putBody(http, "5", 1), ["brightness": "70"])
        store.stop()
    }

    func testBrightnessZeroSwitchesOffAndKeepsTheRememberedLevel() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 60, canSetLevel: true)])
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "OFF", brightness: 60, canSetLevel: true)))
        store.setBrightness("5", 0)
        await waitUntil("the write") { store.writesInFlight == 0 }
        XCTAssertEqual(puts(http, "5"), 1)
        XCTAssertEqual(putBody(http, "5", 0), ["power": "OFF"])       // no brightness key
        XCTAssertEqual(dev(store, "5")?.power, false)
        XCTAssertEqual(dev(store, "5")?.brightness, 60)
        store.stop()
    }

    func testBrightnessIsClampedToTheDevicesOwnRange() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 40,
                                         canSetLevel: true, minLevel: 5, maxLevel: 100)])
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 5, canSetLevel: true)))
        store.setBrightness("5", 3)                                   // below minLevel
        await waitUntil("the floored write") { puts(http, "5") == 1 }
        XCTAssertEqual(putBody(http, "5", 0), ["brightness": "5"])

        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 100, canSetLevel: true)))
        store.setBrightness("5", 200)                                 // above maxLevel
        await waitUntil("the capped write") { puts(http, "5") == 2 }
        XCTAssertEqual(putBody(http, "5", 1), ["brightness": "100"])
        store.stop()
    }

    func testTheServersEchoBeatsTheOptimisticGuess() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", canSetLevel: true, presetLevel: 0)])
        // Asked for 70, the record comes back at 55 — the record wins.
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 55, canSetLevel: true)))
        store.setBrightness("5", 70)
        XCTAssertEqual(dev(store, "5")?.brightness, 70)
        await waitUntil("the echo") { store.writesInFlight == 0 }
        XCTAssertEqual(dev(store, "5")?.brightness, 55)
        XCTAssertNil(store.lastError)
        store.stop()
    }

    // MARK: The realtime path

    func testRealtimePushesAreDroppedWhileAWriteIsInFlight() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", canSetLevel: true, presetLevel: 30)])
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 30, canSetLevel: true)))
        http.stub("PUT", "IotSwitches/5",
                  .json(200, Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 70, canSetLevel: true)))

        store.setBrightness("5", 70)
        await waitUntil("the On") { puts(http, "5") >= 1 }
        // Between the two PUTs the device honestly reports its preset. True, but not where the
        // row is going — showing it makes the slider jump.
        store.applyRealtimeForTesting(id: "5", fields: .init(power: true, brightness: 30))
        XCTAssertEqual(dev(store, "5")?.brightness, 70)

        await waitUntil("both writes", timeout: 6) { store.writesInFlight == 0 }
        XCTAssertEqual(dev(store, "5")?.brightness, 70)
        // …and once the write is done the feed is listened to again.
        store.applyRealtimeForTesting(id: "5", fields: .init(brightness: 45))
        XCTAssertEqual(dev(store, "5")?.brightness, 45)
        store.stop()
    }

    func testRealtimeNoOpPushesChangeNothing() async {
        let (store, _, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", roomId: 1)],
            rooms: [Fixtures.room(id: 1, name: "Alcove")])
        var changes = 0
        store.onChange = { changes += 1 }

        store.applyRealtimeForTesting(id: "999", fields: .init(power: true))   // a device we don't hold
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(dev(store, "5")?.power, false)

        // A frame that says exactly what we already believe: no notify, or the menu redraws on
        // every heartbeat.
        store.applyRealtimeForTesting(id: "5", fields: .init(power: false, brightness: 0, connected: true, name: "Desk"))
        XCTAssertEqual(changes, 0)

        store.applyRealtimeForTesting(id: "5", fields: .init(power: true))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(dev(store, "5")?.power, true)
        XCTAssertEqual(store.residences[0].rooms[0].power, true)   // the room follows at once
        store.stop()
    }

    // MARK: checkFeedDelivered

    func testAPollThatContradictsWhatWeHoldDropsLive() async {
        let (store, http, _) = await readyStore(devices: [Fixtures.iotSwitch(id: 5, name: "Desk")])
        store.overrideLiveForTesting(true)
        http.reset()
        // The device is now on at 50 % and the feed never said so — the subscriptions are not
        // being honoured. (realtime is nil here, so the reconnect it asks for is a no-op.)
        stubHome(http, devices: [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 50)])
        store.refresh()
        await waitUntil("the poll") { store.devices.first?.brightness == 50 }
        XCTAssertFalse(store.isLive)
        store.stop()
    }

    func testAPollThatOnlyChangesConnectedKeepsLive() async {
        let (store, http, _) = await readyStore(devices: [Fixtures.iotSwitch(id: 5, name: "Desk")])
        store.overrideLiveForTesting(true)
        http.reset()
        // A device that falls off Wi-Fi may never announce it; that is not the feed's fault.
        stubHome(http, devices: [Fixtures.iotSwitch(id: 5, name: "Desk", connected: false)])
        store.refresh()
        await waitUntil("the poll") { store.devices.first?.connected == false }
        XCTAssertTrue(store.isLive)
        store.stop()
    }

    // MARK: Rooms

    private func alcove() -> ([[String: Any]], [[String: Any]]) {
        ([Fixtures.iotSwitch(id: 5, name: "Desk", roomId: 1),
          Fixtures.iotSwitch(id: 6, name: "Shelf", roomId: 1),
          Fixtures.iotSwitch(id: 7, name: "Fridge", connected: false, roomId: 1)],
         [Fixtures.room(id: 1, name: "Alcove")])
    }

    func testToggleRoomPaintsOnlyTheConnectedDevices() async {
        let (devices, rooms) = alcove()
        let (store, http, _) = await readyStore(devices: devices, rooms: rooms)
        http.stub("POST", "ResidentialRooms/turnOn", .json(200, ["ok": true]))

        store.toggleRoom("1")
        XCTAssertEqual(dev(store, "5")?.power, true)
        XCTAssertEqual(dev(store, "6")?.power, true)
        XCTAssertEqual(dev(store, "7")?.power, false, "an offline device is not painted")
        XCTAssertEqual(store.residences[0].rooms[0].power, true)

        await waitUntil("the room switch") { http.requests("POST", "ResidentialRooms/turnOn").count == 1 }
        XCTAssertEqual(http.requests("POST", "ResidentialRooms/turnOn")[0].query["id"], "1")
        XCTAssertEqual(http.requests("POST", "ResidentialRooms/turnOff").count, 0)
        // The success path sleeps 1.5 s and then refreshes; signing out drops the session so
        // that straggler is a no-op instead of leaking into the next test's mock.
        store.signOut()
    }

    func testToggleRoomFailureRollsTheWholeResidenceBack() async {
        let (devices, rooms) = alcove()
        let (store, http, _) = await readyStore(devices: devices, rooms: rooms)
        http.stub("POST", "ResidentialRooms/turnOn", .json(500, boom))

        store.toggleRoom("1")
        await waitUntil("the rollback") { store.lastError != nil }
        XCTAssertEqual(dev(store, "5")?.power, false)
        XCTAssertEqual(dev(store, "6")?.power, false)
        XCTAssertEqual(store.residences[0].rooms[0].power, false)
        XCTAssertEqual(store.lastError, "Alcove: my.leviton.com: 500 boom")
        store.stop()
    }

    // MARK: Scenes

    /// Both live `residentialAction` shapes at once: the JSON-string `properties` blob and the
    /// bare property "Good Morning" uses.
    private func goodNight() -> ([[String: Any]], [[String: Any]]) {
        ([Fixtures.iotSwitch(id: 5, name: "Desk", canSetLevel: true, minLevel: 5, maxLevel: 90),
          Fixtures.iotSwitch(id: 6, name: "Porch"),
          Fixtures.iotSwitch(id: 7, name: "Shelf", canSetLevel: true, minLevel: 5, maxLevel: 100)],
         [Fixtures.activity(id: 20, name: "Good Night", actions: [
            Fixtures.actionProperties(deviceId: 5, power: "ON", brightness: 200),
            Fixtures.actionBare(deviceId: 6, property: "power", value: "ON"),
            Fixtures.actionProperties(deviceId: 7, power: "ON", brightness: 1)])])
    }

    func testRunActivityPaintsBothActionShapesWithClamping() async {
        let (devices, activities) = goodNight()
        let (store, http, _) = await readyStore(devices: devices, activities: activities)
        XCTAssertEqual(store.activities.map(\.name), ["Good Night"])
        XCTAssertEqual(store.activities[0].actions.count, 3)
        http.stub("POST", "ResidentialActivities/execute", .json(200, ["ok": true]))

        store.runActivity("20")
        XCTAssertEqual(dev(store, "5")?.power, true)
        XCTAssertEqual(dev(store, "5")?.brightness, 90, "capped at the device's maxLevel")
        XCTAssertEqual(dev(store, "6")?.power, true)
        XCTAssertEqual(dev(store, "6")?.brightness, 0, "a power-only action leaves the level alone")
        XCTAssertEqual(dev(store, "7")?.brightness, 5, "floored at the device's minLevel")

        await waitUntil("the execute") { http.requests("POST", "ResidentialActivities/execute").count == 1 }
        XCTAssertEqual(http.requests("POST", "ResidentialActivities/execute")[0].query["id"], "20")
        store.signOut()   // as above: kill the delayed refresh this path queues
    }

    func testRunActivityFailureRollsBackAndNamesTheScene() async {
        let (devices, activities) = goodNight()
        let (store, http, _) = await readyStore(devices: devices, activities: activities)
        http.stub("POST", "ResidentialActivities/execute", .json(500, boom))

        store.runActivity("20")
        await waitUntil("the rollback") { store.lastError != nil }
        XCTAssertEqual(dev(store, "5")?.power, false)
        XCTAssertEqual(dev(store, "5")?.brightness, 0)
        XCTAssertEqual(dev(store, "6")?.power, false)
        XCTAssertEqual(store.lastError, "Good Night: my.leviton.com: 500 boom")
        store.stop()
    }

    // MARK: Signing out, and the strings the menu shows

    func testSignOutClearsEverything() async {
        let (store, _, creds) = await readyStore(devices: [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON")])
        store.signOut()
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertTrue(store.residences.isEmpty)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertFalse(store.pollActive)
        XCTAssertTrue(creds.calls.contains("deleteSession"))
        XCTAssertTrue(creds.calls.contains("deleteLogin"))
        XCTAssertNil(creds.session)
        XCTAssertNil(creds.login)
        XCTAssertEqual(store.summary, "Not signed in to My Leviton")
        XCTAssertEqual(store.tally, "signed out")
    }

    func testTallyWithNoDevices() async {
        let (store, _, _) = await readyStore(devices: [])
        XCTAssertEqual(store.tally, "no devices")
        XCTAssertEqual(store.summary, "No devices")
        store.stop()
    }

    func testTallyWithEverythingOffline() async {
        let (store, _, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", connected: false),
                      Fixtures.iotSwitch(id: 6, name: "Shelf", connected: false)])
        XCTAssertEqual(store.tally, "all offline")
        store.stop()
    }

    func testTallyCountsReachableDevices() async {
        let (store, _, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON"),
                      Fixtures.iotSwitch(id: 6, name: "Shelf", power: "ON"),
                      Fixtures.iotSwitch(id: 7, name: "Porch"),
                      Fixtures.iotSwitch(id: 8, name: "Fridge", connected: false)])
        XCTAssertEqual(store.tally, "2 of 3 on")
        XCTAssertEqual(store.summary, "2 of 3 on · 1 offline")
        store.stop()
    }

    // MARK: The drift warning

    /// One `checkFeedDelivered` trip is a race the design accepts; three inside the window is
    /// drift, and that is when the Refresh row earns its ⚠︎.
    func testThreeFeedMissesRaiseTheDriftWarningTwoDoNot() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk", brightness: 10, canSetLevel: true)])
        for round in 1...3 {
            store.overrideLiveForTesting(true)
            http.reset()
            stubHome(http, devices: [Fixtures.iotSwitch(id: 5, name: "Desk",
                                                        brightness: 10 + round, canSetLevel: true)])
            store.refresh()
            await waitUntil("miss \(round) to drop the feed") { store.isLive == false }
            if round < DeviceStore.feedMissThreshold {
                XCTAssertNil(store.apiAnomaly, "warned after only \(round) miss(es)")
            }
        }
        let drift = store.apiAnomaly
        XCTAssertNotNil(drift)
        XCTAssertTrue(drift?.contains("missed 3 changes") == true, drift ?? "nil")
        store.stop()
    }

    /// A reply the parser refuses is drift by definition; an ordinary 500 is not.
    func testMalformedReplyRaisesTheDriftWarningAPlainFailureDoesNot() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk")])
        http.reset()
        stubHome(http, devices: [], permissions: [.json(500, boom)])
        store.refresh()
        await waitUntil("the failed refresh") { store.lastError != nil }
        XCTAssertNil(store.apiAnomaly, "a plain 500 must not raise the drift warning")

        // The malformed reply must be stubbed before stubHome's healthy one — FIFO.
        http.reset()
        http.stub("GET", "Residences/100/iotSwitches", .json(200, ["not": "an array"]))
        stubHome(http, devices: [])
        store.refresh()
        await waitUntil("the drift warning") { store.apiAnomaly != nil }
        XCTAssertTrue(store.apiAnomaly?.contains("could not read") == true, store.apiAnomaly ?? "nil")
        store.stop()
    }

    /// Entries age out lazily an hour after the last sign of trouble — no timer, the row's
    /// read is the clock.
    func testDriftWarningAgesOut() {
        let (store, _, _) = makeStore()
        store.noteAnomaly(.malformed, "old", at: Date().addingTimeInterval(-3700))
        XCTAssertNil(store.apiAnomaly)
        store.noteAnomaly(.malformed, "new", at: Date().addingTimeInterval(-3500))
        XCTAssertEqual(store.apiAnomaly, "new")
    }

    /// A feed-auth anomaly resolves itself the moment the feed authenticates again (a
    /// re-login replaced the token); the other kinds only age out.
    func testFeedAuthAnomalyClearsWhenTheFeedGoesLive() {
        let (store, _, _) = makeStore()
        store.noteAnomaly(.feedAuth, "rejected")
        XCTAssertNotNil(store.apiAnomaly)
        store.overrideLiveForTesting(true)
        XCTAssertNil(store.apiAnomaly, "going live must clear a feed-auth anomaly")

        store.noteAnomaly(.malformed, "unreadable")
        store.overrideLiveForTesting(true)
        XCTAssertNotNil(store.apiAnomaly, "going live must not clear a malformed anomaly")
    }

    func testSignOutClearsTheDriftWarning() async {
        let (store, _, _) = await readyStore(devices: [])
        store.noteAnomaly(.malformed, "unreadable")
        store.signOut()
        XCTAssertNil(store.apiAnomaly)
    }

    /// `--demo` rides on this seam; if it drifts, the showroom silently stops matching the
    /// real states it exists to show.
    func testSeedForDemoStagesAReadyLiveStoreWithTheDriftWarning() {
        let (store, http, _) = makeStore(session: nil, login: nil)
        store.seedForDemo(
            [Residence(id: "demo", name: "Demo", rooms: [Room(id: "r", name: "Room", power: false)],
                       devices: [Fixtures.device(id: "5", name: "Desk", roomId: "r", power: true, brightness: 40)])],
            anomaly: "staged drift")
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.isLive)
        XCTAssertEqual(store.apiAnomaly, "staged drift")
        XCTAssertEqual(store.tally, "1 of 1 on")
        XCTAssertTrue(store.residences[0].rooms[0].power, "room power should be recomputed from the devices")
        XCTAssertTrue(http.requests.isEmpty, "the demo must never talk to the network")
        XCTAssertTrue(store.isSignedIn, "display-only: the staged store must not read as signed out")

        // But every network path gates on the (absent) session, not the display flag.
        store.refresh()
        store.setPower("5", on: false)   // flips the row optimistically, sends nothing
        XCTAssertTrue(http.requests.isEmpty, "a staged store must stay silent on the wire")
        store.signOut()
        XCTAssertFalse(store.isSignedIn)
    }

    // MARK: stop() is sticky

    /// The bug this campaign found: `toggleRoom`/`runActivity` sleep 1.5 s and then
    /// `refresh()`, and a `stop()` landing in that window — the updater's relaunch is exactly
    /// that moment — used to let the delayed refresh rebuild the websocket. Now the latch
    /// holds: after `stop()`, no request goes out and the realtime factory is never asked.
    func testStopIsStickyAgainstTheDelayedRoomRefresh() async {
        let (devices, rooms) = alcove()
        let (store, http, _) = await readyStore(devices: devices, rooms: rooms)
        var factoryCalls = 0
        store.realtimeFactory = { _, _ in factoryCalls += 1; return nil }
        http.stub("POST", "ResidentialRooms/turnOn", .json(200, [:] as [String: Any]))

        store.toggleRoom("1")
        await waitUntil("the room POST") { http.requests("POST", "ResidentialRooms/turnOn").count == 1 }
        store.stop()
        let frozen = http.requests.count
        // Well past the 1.5 s delayed refresh: nothing else may have gone out.
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(http.requests.count, frozen, "the delayed refresh ran after stop()")
        XCTAssertEqual(factoryCalls, 0, "stop() must keep the realtime factory unasked")
        XCTAssertFalse(store.pollActive)
    }

    /// The other window: a refresh already in flight when `stop()` lands still finishes, but
    /// its tail must not build a socket.
    func testStopIsStickyAgainstAnInFlightRefresh() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk")])
        var factoryCalls = 0
        store.realtimeFactory = { _, _ in factoryCalls += 1; return nil }
        // The delayed reply must be stubbed *before* stubHome's, or the FIFO serves the
        // immediate one and the refresh is over before stop() can land in its window.
        http.reset()
        http.stub("GET", "Residences/100/iotSwitches",
                  .delayed(0.5, 200, [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON")]))
        stubHome(http, devices: [Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON")])

        store.refresh()
        await waitUntil("the fetch to be in flight") {
            http.requests("GET", "Residences/100/iotSwitches").count >= 1
        }
        store.stop()
        // Let the delayed reply land and the refresh run to completion.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(factoryCalls, 0, "the in-flight refresh's tail built a socket after stop()")
    }

    /// The latch is not a grave: an explicit sign-in — a person deliberately using this copy —
    /// brings the store back, polling, socket factory and all.
    func testSignInRevivesAStoppedStore() async {
        let (store, http, _) = await readyStore(
            devices: [Fixtures.iotSwitch(id: 5, name: "Desk")])
        store.stop()
        let frozen = http.requests.count
        store.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(http.requests.count, frozen, "refresh() must be dead after stop()")

        var factoryCalls = 0
        store.realtimeFactory = { _, _ in factoryCalls += 1; return nil }
        http.stub("POST", "Person/login", .json(200, Fixtures.loginReply()))
        store.signIn(Fixtures.login(), remember: false)
        await waitUntil("the revived store") { store.state == .ready }
        XCTAssertTrue(store.pollActive)
        XCTAssertEqual(factoryCalls, 1, "the revived store should have asked for a feed again")
        store.stop()
    }
}
