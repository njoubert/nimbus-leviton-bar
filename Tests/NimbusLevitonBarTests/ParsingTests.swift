// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusLevitonBar

/// `LevitonClient`'s parsing statics: the layer between My Leviton's undocumented JSON and
/// every value type above it. Pure functions, so this is where the wire shapes measured
/// against the live account (CLAUDE.md, Aug 2026) get pinned.
final class ParsingTests: XCTestCase {

    // MARK: idString

    func testIdStringNormalisesTheWireTypes() {
        XCTAssertEqual(LevitonClient.idString(42), "42")
        XCTAssertEqual(LevitonClient.idString(42.0), "42")
        XCTAssertEqual(LevitonClient.idString(42.9), "42")      // truncates, as Int(_:) does
        XCTAssertEqual(LevitonClient.idString("431325"), "431325")
        XCTAssertEqual(LevitonClient.idString("not-a-number"), "not-a-number")
    }

    func testIdStringRejectsTheEmptyString() {
        // An empty id is no id: it would otherwise become a device keyed on "", which the
        // store would happily hold and never be able to address.
        XCTAssertNil(LevitonClient.idString(""))
    }

    func testIdStringRejectsNilAndOtherTypes() {
        XCTAssertNil(LevitonClient.idString(nil))
        XCTAssertNil(LevitonClient.idString(NSNull()))
        XCTAssertNil(LevitonClient.idString([1, 2]))
        XCTAssertNil(LevitonClient.idString(["id": 1]))
        // A *Swift* Bool is not an Int and falls through to nil.
        XCTAssertNil(LevitonClient.idString(true))
    }

    func testIdStringTakesAJsonBooleanForOne() {
        // Verified on macOS with the compiler this repo builds with: JSONSerialization turns
        // `true` into an NSNumber, and `NSNumber as? Int` succeeds — so a JSON boolean where
        // an id was expected comes back as "1" rather than nil, unlike the Swift literal
        // above. Harmless (no id field is ever a boolean) but it is the reason the literal
        // and the parsed value have to be tested separately.
        let j = json(#"{"flag": true}"#)
        XCTAssertEqual(LevitonClient.idString(j["flag"]), "1")
    }

    // MARK: device(from:)

    func testDeviceMapsEveryFieldOfAFullRecord() {
        let j = Fixtures.iotSwitch(id: 431325, name: "Entrance Track Lights", power: "ON",
                                   brightness: 70, canSetLevel: true, minLevel: 10, maxLevel: 90,
                                   model: "D36HD", version: "1.0.15", serial: "SN-9",
                                   connected: true, roomId: 1613723, residenceId: 100,
                                   presetLevel: 30, includeInRoomOnOff: true)
        let expected = Device(id: "431325", residenceId: "100", roomId: "1613723",
                              name: "Entrance Track Lights", model: "D36HD", version: "1.0.15",
                              serial: "SN-9", power: true, brightness: 70, minLevel: 10,
                              maxLevel: 90, canSetLevel: true, connected: true,
                              includeInRoomOnOff: true, presetLevel: 30)
        XCTAssertEqual(LevitonClient.device(from: j, residenceId: "999"), expected)
    }

    func testMissingOptionalsTakeTheDocumentedDefaults() throws {
        // A record stripped to the one field that is not optional. The defaults matter:
        // `connected` true keeps a device usable when the field is absent, and `maxLevel` 100
        // keeps a slider from collapsing to a point.
        let d = try XCTUnwrap(LevitonClient.device(from: ["id": 5], residenceId: "77"))
        XCTAssertEqual(d.id, "5")
        XCTAssertEqual(d.name, "Switch 5")
        XCTAssertEqual(d.model, "")
        XCTAssertEqual(d.version, "")
        XCTAssertEqual(d.serial, "")
        XCTAssertEqual(d.power, false)
        XCTAssertEqual(d.brightness, 0)
        XCTAssertEqual(d.minLevel, 0)
        XCTAssertEqual(d.maxLevel, 100)
        XCTAssertEqual(d.canSetLevel, false)
        XCTAssertEqual(d.connected, true)
        XCTAssertEqual(d.includeInRoomOnOff, false)
        XCTAssertNil(d.presetLevel)
        XCTAssertNil(d.roomId)
    }

    func testDeletedRecordsAreDropped() {
        let j = Fixtures.iotSwitch(id: 5, name: "Old Lamp", extra: ["deleted": true])
        XCTAssertNil(LevitonClient.device(from: j, residenceId: "100"))
        // Only `true` drops it; the field is usually present and false.
        let live = Fixtures.iotSwitch(id: 5, name: "Old Lamp", extra: ["deleted": false])
        XCTAssertNotNil(LevitonClient.device(from: live, residenceId: "100"))
    }

    func testRecordWithoutAnIdIsDropped() {
        XCTAssertNil(LevitonClient.device(from: ["name": "Nameless"], residenceId: "100"))
    }

    func testResidenceIdFallsBackToTheArgument() throws {
        // `IotSwitches/{id}` and the realtime feed can hand back a record without one; the
        // residence we asked for is then the right answer.
        var j = Fixtures.iotSwitch(id: 5, name: "Desk")
        j["residenceId"] = nil
        let d = try XCTUnwrap(LevitonClient.device(from: j, residenceId: "77"))
        XCTAssertEqual(d.residenceId, "77")
    }

    func testRoomIdIsNilWhenTheRecordCarriesNone() {
        // My Leviton's "unassigned" devices; `Residence.unassigned` is what picks them up.
        let j = Fixtures.iotSwitch(id: 5, name: "Desk", roomId: nil)
        XCTAssertNil(LevitonClient.device(from: j, residenceId: "100")?.roomId)
    }

    // MARK: DeviceFields(json:)

    func testPowerIsCaseInsensitive() {
        // The API sends "ON"/"OFF"; the uppercasing is a cheap guard, not an observed shape.
        XCTAssertEqual(LevitonClient.DeviceFields(json: ["power": "ON"]).power, true)
        XCTAssertEqual(LevitonClient.DeviceFields(json: ["power": "on"]).power, true)
        XCTAssertEqual(LevitonClient.DeviceFields(json: ["power": "OFF"]).power, false)
        XCTAssertEqual(LevitonClient.DeviceFields(json: ["power": "off"]).power, false)
        // Anything that is not a string leaves it unset rather than guessing.
        XCTAssertNil(LevitonClient.DeviceFields(json: ["power": 1]).power)
    }

    func testBrightnessAcceptsIntAndDouble() {
        XCTAssertEqual(LevitonClient.DeviceFields(json: ["brightness": 40]).brightness, 40)
        // The Double branch: a literal Swift Double does not cast to Int. (JSONSerialization
        // would have made this an NSNumber, which takes the Int branch — so the branch is
        // only reachable from code that builds the dictionary itself.)
        XCTAssertEqual(LevitonClient.DeviceFields(json: ["brightness": 40.0]).brightness, 40)
        XCTAssertEqual(LevitonClient.DeviceFields(json: ["brightness": 40.7]).brightness, 40)
    }

    func testNameAndConnectedAreCarried() {
        let f = LevitonClient.DeviceFields(json: ["name": "Desk Lamp", "connected": false])
        XCTAssertEqual(f.name, "Desk Lamp")
        XCTAssertEqual(f.connected, false)
    }

    func testEmptyJsonGivesTheEmptyFields() {
        // `sceneAction` leans on this: an action that set nothing we understand compares equal
        // to the empty value and is dropped.
        XCTAssertEqual(LevitonClient.DeviceFields(json: [:]), LevitonClient.DeviceFields())
    }

    func testBodyEmitsOnlyPowerAndBrightness() {
        // `connected` and `name` are readable state, never something we write back.
        let body = LevitonClient.DeviceFields(power: true, brightness: 70,
                                              connected: true, name: "Desk").body
        XCTAssertEqual(Set(body.keys), ["power", "brightness"])
        XCTAssertEqual(body["power"] as? String, "ON")
        XCTAssertEqual(body["brightness"] as? Int, 70)

        XCTAssertEqual(LevitonClient.DeviceFields(power: false).body["power"] as? String, "OFF")
        XCTAssertTrue(LevitonClient.DeviceFields().body.isEmpty)
        // A level-only write is one key: this is the "already on" path, which sticks at once.
        XCTAssertEqual(Set(LevitonClient.DeviceFields(brightness: 40).body.keys), ["brightness"])
    }

    // MARK: sceneAction(from:)

    func testPropertiesShapeNeedsASecondParse() {
        // The common shape: `targetValue` is a JSON *string* holding the object.
        let a = LevitonClient.sceneAction(from: Fixtures.actionProperties(deviceId: 431325,
                                                                         power: "ON", brightness: 40))
        XCTAssertEqual(a, SceneAction(deviceId: "431325",
                                      fields: LevitonClient.DeviceFields(power: true, brightness: 40)))
    }

    func testBareShapeCarriesTheValueUnwrapped() {
        // "Good Morning" on the live account: targetProperty is the property itself.
        let a = LevitonClient.sceneAction(from: Fixtures.actionBare(deviceId: 431325,
                                                                   property: "power", value: "ON"))
        XCTAssertEqual(a, SceneAction(deviceId: "431325",
                                      fields: LevitonClient.DeviceFields(power: true)))
    }

    func testBareBrightnessAsAStringIsParsed() {
        // The special case in `sceneAction`: a bare brightness arrives as "40", and
        // `DeviceFields(json:)` only reads numbers, so it is converted before the handoff.
        let a = LevitonClient.sceneAction(from: Fixtures.actionBare(deviceId: 7,
                                                                   property: "brightness", value: "40"))
        XCTAssertEqual(a, SceneAction(deviceId: "7",
                                      fields: LevitonClient.DeviceFields(brightness: 40)))
    }

    func testBareBrightnessAsAnIntIsParsed() {
        let a = LevitonClient.sceneAction(from: Fixtures.actionBare(deviceId: 7,
                                                                   property: "brightness", value: 40))
        XCTAssertEqual(a, SceneAction(deviceId: "7",
                                      fields: LevitonClient.DeviceFields(brightness: 40)))
    }

    func testNonIotSwitchTargetsAreDropped() {
        // Activities also carry sonos/schlage actions; the app has no business with them.
        var j = Fixtures.actionProperties(deviceId: 431325, power: "ON")
        j["targetModelName"] = "SonosDevice"
        XCTAssertNil(LevitonClient.sceneAction(from: j))
        j["targetModelName"] = nil
        XCTAssertNil(LevitonClient.sceneAction(from: j))
    }

    func testMissingTargetModelIdIsDropped() {
        let j: [String: Any] = ["targetModelName": "IotSwitch",
                                "targetProperty": "power", "targetValue": "ON"]
        XCTAssertNil(LevitonClient.sceneAction(from: j))
    }

    func testUnparseablePropertiesBlobIsDropped() {
        // Better to lose one action than to invent a level for someone's lights.
        var j = Fixtures.actionProperties(deviceId: 431325, power: "ON")
        j["targetValue"] = "not json at all"
        XCTAssertNil(LevitonClient.sceneAction(from: j))
        j["targetValue"] = "[1,2]"                    // valid JSON, wrong shape
        XCTAssertNil(LevitonClient.sceneAction(from: j))
        j["targetValue"] = ["power": "ON"]            // already an object, not the string shape
        XCTAssertNil(LevitonClient.sceneAction(from: j))
    }

    func testBareShapeWithAPropertyWeDoNotUnderstandIsDropped() {
        // `DeviceFields(json:)` comes out empty for it, and an action that changes nothing we
        // model would otherwise paint a device with a no-op.
        XCTAssertNil(LevitonClient.sceneAction(from: Fixtures.actionBare(deviceId: 7,
                                                                        property: "color", value: "red")))
    }

    // MARK: Helper

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
}
