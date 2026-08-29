// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusLevitonBar

/// The pure model — `Device`'s derived properties and `Residence`'s ordering rules. These are
/// what the menu is drawn from, and every one of them encodes a decision that was argued out
/// against the real account, so they are pinned here rather than left to the eyeball check.
final class DeviceModelTests: XCTestCase {

    // MARK: Device.kind

    func testFanWinsOverDimmer() {
        // The "*SF" test comes first on purpose: a fan controller sets `canSetLevel` too (its
        // "brightness" is the speed, in steps of 25), so ordering the checks the other way
        // would call every fan a dimmer.
        XCTAssertEqual(Fixtures.device(id: "1", model: "DW4SF", canSetLevel: true).kind, .fan)
        XCTAssertEqual(Fixtures.device(id: "1", model: "D24SF", canSetLevel: false).kind, .fan)
    }

    func testDimmerIsCanSetLevelNotTheModel() {
        XCTAssertEqual(Fixtures.device(id: "1", model: "D26HD", canSetLevel: true).kind, .dimmer)
        XCTAssertEqual(Fixtures.device(id: "1", model: "DW3HL", canSetLevel: true).kind, .dimmer)
        XCTAssertEqual(Fixtures.device(id: "1", model: "D23LP", canSetLevel: true).kind, .dimmer)
        // The same model without the capability is not a dimmer: nothing in the string decides it.
        XCTAssertEqual(Fixtures.device(id: "1", model: "D26HD", canSetLevel: false).kind, .other)
    }

    func testPlugSuffixes() {
        for model in ["DW15P", "D215P", "DW15A", "DW15R", "D215O"] {
            XCTAssertEqual(Fixtures.device(id: "1", model: model, canSetLevel: false).kind, .plug, model)
        }
    }

    func testSwitchSuffix() {
        for model in ["DW15S", "D215S"] {
            XCTAssertEqual(Fixtures.device(id: "1", model: model, canSetLevel: false).kind, .switch, model)
        }
    }

    func testEverythingElseIsOther() {
        // A 4-button controller, and a record whose `model` never arrived.
        XCTAssertEqual(Fixtures.device(id: "1", model: "DW4BC", canSetLevel: false).kind, .other)
        XCTAssertEqual(Fixtures.device(id: "1", model: "", canSetLevel: false).kind, .other)
    }

    // MARK: comesOnAtPreset

    func testUnknownPresetCountsAsHavingOne() {
        // Deliberate, and the reason `presetLevel` is an Optional rather than defaulted to 0:
        // guessing "no preset" wrong costs a wrong level on screen, guessing "preset" wrong
        // only costs the slow two-write path.
        XCTAssertTrue(Fixtures.device(id: "1", presetLevel: nil).comesOnAtPreset)
    }

    func testPresetZeroMeansLastLevel() {
        XCTAssertFalse(Fixtures.device(id: "1", presetLevel: 0).comesOnAtPreset)
    }

    func testNonZeroPresetComesOnAtIt() {
        XCTAssertTrue(Fixtures.device(id: "1", presetLevel: 30).comesOnAtPreset)
        XCTAssertTrue(Fixtures.device(id: "1", presetLevel: 100).comesOnAtPreset)
    }

    // MARK: isOn, levelClamped

    func testIsOnRequiresConnected() {
        // My Leviton keeps reporting the last known power for a switch that has dropped off
        // Wi-Fi, so "on" in the menu has to mean "on and reachable".
        XCTAssertTrue(Fixtures.device(id: "1", power: true, connected: true).isOn)
        XCTAssertFalse(Fixtures.device(id: "1", power: true, connected: false).isOn)
        XCTAssertFalse(Fixtures.device(id: "1", power: false, connected: true).isOn)
        XCTAssertFalse(Fixtures.device(id: "1", power: false, connected: false).isOn)
    }

    func testLevelClamped() {
        XCTAssertEqual(Fixtures.device(id: "1", brightness: 50, minLevel: 5, maxLevel: 100).levelClamped, 50)
        // An off dimmer reports 0, which clamps up to its own minimum rather than to nothing.
        XCTAssertEqual(Fixtures.device(id: "1", brightness: 0, minLevel: 5, maxLevel: 100).levelClamped, 5)
        XCTAssertEqual(Fixtures.device(id: "1", brightness: 150, minLevel: 5, maxLevel: 90).levelClamped, 90)
        XCTAssertEqual(Fixtures.device(id: "1", brightness: 50, minLevel: 0, maxLevel: 100).levelClamped, 50)
    }

    // MARK: Residence.displayRooms

    func testDisplayRoomsAppliesTheUsersOrder() {
        let r = residence(rooms: [room("1", "Alcove"), room("2", "Bedroom"), room("3", "Cellar")],
                          devices: [lamp("a", room: "1"), lamp("b", room: "2"), lamp("c", room: "3")],
                          order: ["3", "1", "2"])
        XCTAssertEqual(r.displayRooms.map(\.id), ["3", "1", "2"])
    }

    func testRoomsTheOrderDoesNotMentionSortLastInTheListsOwnOrder() {
        // A room added since the user last dragged the list has no rank, so it falls to the
        // end — and ties there keep the order `rooms` arrived in. The API returns rooms in id
        // order, so in production that reads as "id order"; the array is what the code
        // actually follows, which is what this deliberately non-id-ordered list pins.
        let r = residence(rooms: [room("4", "Den"), room("2", "Bedroom"), room("3", "Cellar")],
                          devices: [lamp("a", room: "4"), lamp("b", room: "2"), lamp("c", room: "3")],
                          order: ["3"])
        XCTAssertEqual(r.displayRooms.map(\.id), ["3", "4", "2"])
    }

    func testNoRoomOrderLeavesTheApiOrderAlone() {
        // The account that never reordered anything: this is why the menu was accidentally
        // right before `roomOrders` existed.
        let r = residence(rooms: [room("3", "Cellar"), room("1", "Alcove"), room("2", "Bedroom")],
                          devices: [lamp("a", room: "3"), lamp("b", room: "1"), lamp("c", room: "2")],
                          order: [])
        XCTAssertEqual(r.displayRooms.map(\.id), ["3", "1", "2"])
    }

    func testEmptyRoomsAreDropped() {
        // A room with nothing in it would be a header with no rows under it.
        let r = residence(rooms: [room("1", "Alcove"), room("2", "Empty"), room("3", "Cellar")],
                          devices: [lamp("a", room: "1"), lamp("c", room: "3")],
                          order: ["1", "2", "3"])
        XCTAssertEqual(r.displayRooms.map(\.id), ["1", "3"])
    }

    func testWhollyUnreachableRoomsMoveToTheEndAfterOrdering() {
        // The partition runs over the *already ordered* list, so an offline room keeps its
        // place relative to the other offline ones.
        let r = residence(rooms: [room("1", "Alcove"), room("2", "Bedroom"),
                                  room("3", "Cellar"), room("4", "Den")],
                          devices: [lamp("a", room: "1", connected: false),
                                    lamp("b", room: "2"),
                                    lamp("c", room: "3", connected: false),
                                    lamp("d", room: "4")],
                          order: ["4", "3", "2", "1"])
        // Ordered would be 4, 3, 2, 1; the reachable ones (4, 2) come first and the
        // unreachable ones (3, 1) follow in that same relative order.
        XCTAssertEqual(r.displayRooms.map(\.id), ["4", "2", "3", "1"])
    }

    func testOneReachableDeviceKeepsARoomInPlace() {
        let r = residence(rooms: [room("1", "Alcove"), room("2", "Bedroom")],
                          devices: [lamp("a", room: "1", connected: false),
                                    lamp("b", room: "1"),
                                    lamp("c", room: "2")],
                          order: ["1", "2"])
        XCTAssertEqual(r.displayRooms.map(\.id), ["1", "2"])
    }

    func testDuplicateIdInTheOrderTakesItsFirstMention() {
        // `roomOrder` comes off a preference row the app never writes, so a malformed one has
        // to land somewhere predictable: the first mention is the rank.
        let r = residence(rooms: [room("1", "Alcove"), room("2", "Bedroom")],
                          devices: [lamp("a", room: "1"), lamp("b", room: "2")],
                          order: ["2", "1", "2"])
        XCTAssertEqual(r.displayRooms.map(\.id), ["2", "1"])
    }

    // MARK: displayDevices, unassigned

    func testDisplayDevicesPutsOfflineOnesLastWithinEachGroup() {
        // `devices` reaches the store already alphabetical, so each half only has to stay
        // stable for the menu to read alphabetically with the dead ones swept to the bottom.
        let alcove = room("1", "Alcove")
        let r = residence(rooms: [alcove],
                          devices: [lamp("Alpha", room: "1"),
                                    lamp("Bravo", room: "1", connected: false),
                                    lamp("Charlie", room: "1"),
                                    lamp("Delta", room: "1", connected: false)],
                          order: [])
        XCTAssertEqual(r.displayDevices(in: alcove).map(\.name), ["Alpha", "Charlie", "Bravo", "Delta"])
    }

    func testUnassignedCoversNoRoomAndAnUnlistedRoom() {
        let r = residence(rooms: [room("1", "Alcove")],
                          devices: [lamp("in-room", room: "1"),
                                    lamp("no-room", room: nil),
                                    lamp("ghost-room", room: "999")],
                          order: [])
        XCTAssertEqual(r.unassigned.map(\.name), ["no-room", "ghost-room"])
    }

    // MARK: Helpers

    private func residence(rooms: [Room], devices: [Device], order: [String]) -> Residence {
        Residence(id: "100", name: "Home", rooms: rooms, devices: devices, roomOrder: order)
    }

    private func room(_ id: String, _ name: String) -> Room {
        Room(id: id, name: name, power: false)
    }

    /// One device, named after what the test is asserting about it — the id doubles as the name
    /// so failures read back as the list under test.
    private func lamp(_ name: String, room: String?, connected: Bool = true) -> Device {
        Fixtures.device(id: name, name: name, roomId: room, connected: connected)
    }
}
