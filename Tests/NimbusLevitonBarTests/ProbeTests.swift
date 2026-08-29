// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusLevitonBar

/// `--probe` is the tripwire for an undocumented API, so it has to be trustworthy in both
/// directions: silent on an account that still answers the way the parser expects, and loud —
/// with the offending field and the device's name — the moment a shape moves. These tests run
/// it entirely against `MockHTTP`; nothing here reaches my.leviton.com.
final class ProbeTests: XCTestCase {

    // MARK: A healthy account

    func testHealthyAccountPassesAndReportsWhatItProbed() async {
        let (client, http) = MockHTTP.makeClient()
        Account().install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 0, out.text)
        XCTAssertEqual(out.failures, [], out.text)
        // One ✓ per check family, so a family that silently stops running is visible.
        for family in ["residentialPermissions:", "ResidentialAccounts/9/residences:",
                       "iotSwitches [Home]:", "residentialRooms [Home]: 2 rooms",
                       "ascending id order", "position still null",
                       "preferences:", "residentialActivities [Home]: 2 activities",
                       "residentialActions [Home]: every IotSwitch action decodes"] {
            XCTAssertTrue(out.passes.contains { $0.contains(family) },
                          "no ✓ line for \(family)\n\(out.text)")
        }
        XCTAssertTrue(out.text.contains("probed 1 residence, 2 devices, 2 rooms, 2 activities"), out.text)
        XCTAssertTrue(out.summary.hasSuffix("0 failures"), out.summary)
        XCTAssertTrue(out.summary.contains(" checks, "), out.summary)
    }

    /// The point of the whole exercise: it must never write, and never spend a sign-in.
    func testProbeIssuesNothingButGets() async {
        let (client, http) = MockHTTP.makeClient()
        Account().install(http)

        _ = await probe(client)

        XCTAssertFalse(http.requests.isEmpty)
        for r in http.requests {
            XCTAssertEqual(r.method, "GET", "\(r.method) \(r.path)")
            XCTAssertNil(r.bodyData, "\(r.method) \(r.path) carried a body")
            XCTAssertFalse(r.path.contains("login"), r.path)
            XCTAssertFalse(r.path.contains("execute"), r.path)
            XCTAssertFalse(r.path.contains("turnOn") || r.path.contains("turnOff"), r.path)
        }
    }

    /// The activities call is the one with a LoopBack `filter`; if the include stops being
    /// sent, every scene comes back empty and the probe would be checking nothing.
    func testActivitiesRequestCarriesTheIncludeFilter() async {
        let (client, http) = MockHTTP.makeClient()
        Account().install(http)

        _ = await probe(client)

        let sent = http.requests("GET", "Residences/100/residentialActivities")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.query["filter"], #"{"include":["residentialActions"]}"#)
    }

    // MARK: Drift — each of these is a bug that would otherwise arrive as a mystery

    func testPowerAsANumberIsDrift() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.devices = [Fixtures.iotSwitch(id: 5, name: "Desk", extra: ["power": 1, "chgReason": 3])]
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.failed("iotSwitches [Home]"), out.text)
        XCTAssertTrue(out.evidence.contains { $0.contains("Desk") && $0.contains("power = 1") }, out.text)
    }

    func testBrightnessOutOfRangeIsDrift() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.devices = [Fixtures.iotSwitch(id: 5, name: "Desk", brightness: 255,
                                        canSetLevel: true, extra: ["chgReason": 3])]
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.evidence.contains { $0.contains("Desk") && $0.contains("brightness = 255") }, out.text)
    }

    func testARoomWithAPositionIsDrift() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        // `position` is null on every room today; a number means Leviton woke the field up and
        // the room order may have moved off the person's preferences.
        a.rooms = [["id": 10, "name": "Kitchen", "power": "OFF", "position": 1, "allConnected": true],
                   Fixtures.room(id: 20, name: "Office")]
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.failed("position still null"), out.text)
        XCTAssertTrue(out.evidence.contains { $0.contains("Kitchen") && $0.contains("position = 1") }, out.text)
    }

    func testRoomsOutOfIdOrderIsDrift() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.rooms = [Fixtures.room(id: 20, name: "Office"), Fixtures.room(id: 10, name: "Kitchen")]
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.failed("ascending id order"), out.text)
        XCTAssertTrue(out.evidence.contains { $0.contains("room 20 is listed before room 10") }, out.text)
    }

    /// The silent one: `value` becoming a real array instead of a JSON string would make
    /// `roomOrders` drop every row, and the menu would quietly revert to id order.
    func testRoomOrderPreferenceAsARealArrayIsDrift() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.preferences = [["appId": "DECORA_SMART", "key": "sorting$residence:100$rooms", "value": [20, 10]]]
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.failed("preferences:"), out.text)
        XCTAssertTrue(out.evidence.contains { $0.contains("sorting$residence:100$rooms")
                                              && $0.contains("an array, not a JSON string") }, out.text)
    }

    func testUnparseableActionBlobIsDrift() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.activities = [Fixtures.activity(id: 1, name: "Good Night", actions: [
            ["targetModelName": "IotSwitch", "targetModelId": 5,
             "targetProperty": "properties", "targetValue": "power=OFF"],
        ])]
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.failed("every IotSwitch action decodes"), out.text)
        XCTAssertTrue(out.evidence.contains { $0.contains("Good Night") && $0.contains("does not decode") }, out.text)
    }

    func testIncludeNotHonouredIsDrift() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.activities = [["id": 1, "residenceId": 100, "name": "Good Night",
                         "customIcon": "goodnight", "isButtonActivity": false]]
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.failed("the include was not honoured"), out.text)
    }

    func testAPermissionRowWithNoIdIsDrift() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.permissions = [Fixtures.permissionAccount(9), ["role": "owner"]]
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.failed("residentialPermissions:"), out.text)
        XCTAssertTrue(out.evidence.contains { $0.contains("row 1") }, out.text)
    }

    func testAnEndpointThatFailsIsDriftNotASilentSkip() async {
        let (client, http) = MockHTTP.makeClient()
        // Stubs are a FIFO, so this one is served before the healthy list `install` adds.
        http.stub("GET", "Residences/100/iotSwitches",
                  .json(500, Fixtures.loopbackError(status: 500, message: "boom")))
        Account().install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.failures.contains { $0.contains("iotSwitches") && $0.contains("500") }, out.text)
    }

    func testAnEndpointThatStopsReturningAnArrayIsDrift() async {
        let (client, http) = MockHTTP.makeClient()
        http.stub("GET", "Residences/100/residentialRooms", .json(200, ["rooms": []]))
        Account().install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 1, out.text)
        XCTAssertTrue(out.failures.contains { $0.contains("residentialRooms")
                                              && $0.contains("not an array of objects") }, out.text)
    }

    // MARK: Advisories — visible, but not a failure

    func testIncludeInRoomOnOffFalseIsOnlyAWarning() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.devices = [Fixtures.iotSwitch(id: 5, name: "Desk", includeInRoomOnOff: false,
                                        extra: ["chgReason": 3])]
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 0, out.text)
        XCTAssertTrue(out.warnings.contains { $0.contains("includeInRoomOnOff=false on 1 of 1 devices") }, out.text)
        XCTAssertTrue(out.evidence.contains("Desk"), out.text)
    }

    func testMissingChgReasonIsOnlyAWarning() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.devices = [Fixtures.iotSwitch(id: 5, name: "Desk")]     // no chgReason
        a.install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 0, out.text)
        XCTAssertTrue(out.warnings.contains { $0.contains("chgReason absent") }, out.text)
    }

    /// The output doubles as a record of the account, so the models and the counts are printed
    /// whether or not anything is wrong.
    func testModelsAndActionShapesAreReportedForTheRecord() async {
        let (client, http) = MockHTTP.makeClient()
        Account().install(http)

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 0, out.text)
        XCTAssertTrue(out.warnings.contains { $0.contains("models [Home]: 2 devices, 2 models — D26HD, DW15P") }, out.text)
        XCTAssertTrue(out.warnings.contains { $0.contains("action shapes [Home]: 1 properties-blob, 1 bare") }, out.text)
        XCTAssertTrue(out.warnings.contains { $0.contains("sorting$ rows: 1") }, out.text)
    }

    // MARK: A shared residence takes the other branch of the permissions list

    func testASharedResidenceIsProbedToo() async {
        let (client, http) = MockHTTP.makeClient()
        var a = Account()
        a.permissions = [Fixtures.permissionResidence(100)]
        a.install(http)
        http.stub("GET", "Residences/100", .json(200, Fixtures.residence(id: 100, name: "Home")))

        let (code, out) = await probe(client)

        XCTAssertEqual(code, 0, out.text)
        XCTAssertTrue(out.passes.contains { $0.contains("Residences/100 (shared)") }, out.text)
        XCTAssertTrue(out.text.contains("probed 1 residence, 2 devices"), out.text)
    }

    // MARK: Harness

    private func probe(_ client: LevitonClient) async -> (Int32, Output) {
        let out = Output()
        let code = await Probe.run(client: client, session: Fixtures.session(userId: "7"),
                                   out: { out.add($0) })
        return (code, out)
    }

    /// Everything the probe reads, in one place, so a drift test changes exactly one field.
    private struct Account {
        var permissions: [[String: Any]] = [Fixtures.permissionAccount(9)]
        var residences: [[String: Any]] = [Fixtures.residence(id: 100, name: "Home")]
        var devices: [[String: Any]] = [
            Fixtures.iotSwitch(id: 5, name: "Desk", power: "ON", brightness: 70, canSetLevel: true,
                               minLevel: 5, model: "D26HD", roomId: 10, presetLevel: 30,
                               extra: ["chgReason": 3]),
            Fixtures.iotSwitch(id: 6, name: "Fridge", model: "DW15P", roomId: 20,
                               extra: ["chgReason": 6, "deleted": false]),
        ]
        var rooms: [[String: Any]] = [Fixtures.room(id: 10, name: "Kitchen", power: "ON"),
                                      Fixtures.room(id: 20, name: "Office")]
        var preferences: [[String: Any]] = [
            Fixtures.roomOrderPreference(residenceId: 100, roomIds: [20, 10]),
            ["appId": "DECORA_SMART", "key": "temperatureUnit", "value": "F"],
        ]
        var activities: [[String: Any]] = [
            // Both live action shapes on the one activity, plus a button activity to prove it
            // is still listed (the probe checks every row; only the menu filters them).
            Fixtures.activity(id: 1, name: "Good Night", actions: [
                Fixtures.actionProperties(deviceId: 5, power: "OFF"),
                Fixtures.actionBare(deviceId: 6, property: "power", value: "ON"),
            ]),
            Fixtures.activity(id: 2, name: "Button 1", isButtonActivity: true, actions: []),
        ]

        func install(_ http: MockHTTP) {
            http.stub("GET", "Person/7/residentialPermissions", .json(200, permissions))
            http.stub("GET", "ResidentialAccounts/9/residences", .json(200, residences))
            http.stub("GET", "Person/7/preferences", .json(200, preferences))
            http.stub("GET", "Residences/100/iotSwitches", .json(200, devices))
            http.stub("GET", "Residences/100/residentialRooms", .json(200, rooms))
            http.stub("GET", "Residences/100/residentialActivities", .json(200, activities))
        }
    }

    /// The probe's lines, split by glyph. Detail lines are indented, so `evidence` is where a
    /// failure's offending value ends up.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        var text: String { all.joined(separator: "\n") }

        var passes: [String] { body("✓ ") }
        var warnings: [String] { body("⚠ ") }
        var failures: [String] { body("✗ ") }
        var evidence: [String] { all.filter { $0.hasPrefix("    ") }.map { String($0.dropFirst(4)) } }
        var summary: String { all.last ?? "" }

        func failed(_ needle: String) -> Bool { failures.contains { $0.contains(needle) } }

        private func body(_ glyph: String) -> [String] {
            all.filter { $0.hasPrefix(glyph) }.map { String($0.dropFirst(glyph.count)) }
        }
    }
}
