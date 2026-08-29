// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest
@testable import NimbusLevitonBar

/// The menu's rows, offscreen. Every row is a view rather than an `NSMenuItem` (so the menu
/// stays open), which is exactly why the interesting decisions — the 5 % detents, the room
/// knob sitting at the *lowest* dimmer, the ⌥ reveal — live in view code that no eyeball check
/// can pin down. `--dump-menu` stays the layout check; this is the logic check, so nothing
/// here asserts a pixel.
///
/// Nothing in this file builds a `DeviceStore`, an `NSStatusBar` item or a run loop: the views
/// are made, driven and read directly.
@MainActor
final class MenuLogicTests: XCTestCase {

    /// `NSApp` is an implicitly-unwrapped global that stays nil until an NSApplication exists,
    /// and `LevelControl.changed()` reads `NSApp.currentEvent` to tell a drag from a release —
    /// so the tests make one. Creating it is all: no `run()`, no `finishLaunching()`, and the
    /// accessory policy is the app's own, so no Dock icon appears.
    @discardableResult
    private func appKitUp() -> NSApplication {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }

    /// The percent label inside a `LevelControl` — the only other text field it owns.
    private func percentText(_ control: LevelControl) -> String? {
        control.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first
    }

    private func sliderCell(_ control: LevelControl) -> RangeSliderCell? {
        control.subviews.compactMap { $0 as? NSSlider }.first?.cell as? RangeSliderCell
    }

    /// Text on a row, in no particular order — the labels are private and their order is a
    /// layout detail, so the tests compare sets rather than positions.
    private func texts(_ row: NSView) -> [String] {
        row.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    /// `LevelControl.changed()` tells a drag from a release by `NSApp.currentEvent`, which is
    /// process-wide and *sticky*: an event one test pumps through it is still sitting there for
    /// the next one. So every test that drives the slider states which of the two it wants,
    /// rather than relying on the event queue being empty.
    ///
    /// Returns whether `currentEvent` ended up as asked. A host with no event queue to pump
    /// leaves it nil, which is the drag case — so only the release tests can fail to get what
    /// they want, and they skip.
    private func setCurrentEvent(release: Bool) -> Bool {
        if let e = NSEvent.mouseEvent(with: release ? .leftMouseUp : .leftMouseDragged, location: .zero,
                                      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 0) {
            NSApp.postEvent(e, atStart: true)
            _ = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
        }
        return (NSApp.currentEvent?.type == .leftMouseUp) == release
    }

    /// The mouse is down and moving: `changed()` must update the label and commit nothing.
    private func startDrag(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(setCurrentEvent(release: false),
                      "a stale mouse-up is still in NSApp.currentEvent", file: file, line: line)
    }

    // MARK: LevelControl — the detents

    /// A drag rounds to the nearest multiple of `step` (5): nobody wants 34 % when 35 % will do,
    /// and the knob is then put back into the detent rather than left under the mouse.
    func testDragSnapsToMultiplesOfFive() {
        appKitUp()
        startDrag()
        XCTAssertEqual(LevelControl.step, 5)
        let c = LevelControl(maxLevel: 100)
        c.minLevel = 1
        for (dragged, snapped) in [(42, 40), (43, 45), (13, 15), (97, 95), (98, 100), (75, 75)] {
            c.level = dragged
            c.changed()
            XCTAssertEqual(c.level, snapped, "\(dragged) % should snap to \(snapped) %")
            XCTAssertEqual(percentText(c), "\(snapped)%")
        }
    }

    /// Above zero the dimmer's own floor applies…
    func testNonZeroSnapsUpToMinLevel() {
        appKitUp()
        let c = LevelControl(maxLevel: 100)
        c.minLevel = 10
        startDrag()
        c.level = 3            // → 5 by the detent, → 10 by the floor
        c.changed()
        XCTAssertEqual(c.level, 10)
        XCTAssertEqual(percentText(c), "10%")
    }

    /// …but 0 is off, and the floor does not lift it. A drag to 2 % lands on the detent below,
    /// which is off — not on `minLevel`.
    func testZeroMeansOffAndIsNotFloored() {
        appKitUp()
        let c = LevelControl(maxLevel: 100)
        c.minLevel = 10
        startDrag()
        c.level = 0
        c.changed()
        XCTAssertEqual(c.level, 0)
        c.level = 2
        c.changed()
        XCTAssertEqual(c.level, 0)
        XCTAssertEqual(percentText(c), "0%")
    }

    /// The slider runs 0…maxLevel, not minLevel…maxLevel: an off dimmer with a floor of 20 %
    /// still has to be able to sit at the bottom of the track.
    func testRangeIsZeroToMaxLevel() {
        appKitUp()
        let c = LevelControl(maxLevel: 80)
        c.minLevel = 20
        c.level = 0
        XCTAssertEqual(c.level, 0, "0 must be representable, so minValue is 0 and not minLevel")
        c.level = 200          // the slider clamps an assignment to its own range
        XCTAssertEqual(c.level, 80)
        c.level = -5
        XCTAssertEqual(c.level, 0)
    }

    /// `maxValue` may not be a multiple of the step, so the clamp comes after the snap.
    func testSnapNeverOvershootsAMaxLevelOffTheStep() {
        appKitUp()
        let c = LevelControl(maxLevel: 98)
        c.minLevel = 1
        startDrag()
        c.level = 98
        c.changed()            // snaps to 100, then clamps back to 98
        XCTAssertEqual(c.level, 98)
    }

    /// A level *reported* by a device is shown as it is — only a drag snaps.
    func testReportedLevelIsNotSnapped() {
        appKitUp()
        let c = LevelControl(maxLevel: 100)
        c.minLevel = 1
        c.level = 37
        XCTAssertEqual(c.level, 37)
        XCTAssertEqual(percentText(c), "37%")
        XCTAssertFalse(c.dragging)
    }

    /// `isContinuous` fires for every mouse move; the cloud round trip is slow, so nothing is
    /// sent until the release. With no mouse-up event in flight this is the mid-drag case.
    func testMidDragDoesNotCommit() {
        appKitUp()
        var committed: [Int] = []
        let c = LevelControl(maxLevel: 100)
        c.minLevel = 1
        c.onCommit = { committed.append($0) }
        startDrag()
        c.level = 62
        c.changed()
        XCTAssertEqual(c.level, 60)
        XCTAssertTrue(c.dragging)
        XCTAssertEqual(committed, [], "no PUT until the mouse comes up")
    }

    /// …and exactly one commit on the release, carrying the snapped level.
    func testCommitOnMouseUp() throws {
        appKitUp()
        var committed: [Int] = []
        let c = LevelControl(maxLevel: 100)
        c.minLevel = 10
        c.onCommit = { committed.append($0) }
        c.level = 62
        try XCTSkipUnless(setCurrentEvent(release: true),
                          "no event queue in this test host: NSApp.currentEvent never becomes a mouse-up")
        c.changed()
        XCTAssertEqual(committed, [60])
        XCTAssertFalse(c.dragging)
    }

    /// The band is display only, and it reaches the cell it is drawn from.
    func testRangeTopReachesTheCell() {
        appKitUp()
        let c = LevelControl(maxLevel: 100)
        XCTAssertNotNil(sliderCell(c), "the slider's cell is the RangeSliderCell that draws the band")
        XCTAssertNil(sliderCell(c)?.rangeTop)
        c.rangeTop = 80
        XCTAssertEqual(sliderCell(c)?.rangeTop, 80)
        c.rangeTop = nil
        XCTAssertNil(sliderCell(c)?.rangeTop)
    }

    // MARK: RoomRow — the knob is the minimum, the band is the spread

    private func roomRow() -> RoomRow { RoomRow(dimmers: true, toggle: {}, setLevel: { _ in }) }

    private func setRoom(_ row: RoomRow, _ devices: [Device], detail: String = "") {
        row.set(dot: .on, name: "Study", detail: detail, enabled: true, devices: devices)
    }

    /// Not the average: one gesture moves every dimmer, so the knob has to be the level the
    /// room is at *least* at, or a small nudge blasts the dim half of the room.
    func testKnobSitsAtTheLowestDimmer() {
        appKitUp()
        let row = roomRow()
        setRoom(row, [Fixtures.device(id: "1", power: true, brightness: 80),
                      Fixtures.device(id: "2", power: true, brightness: 30),
                      Fixtures.device(id: "3", power: true, brightness: 55)])
        XCTAssertEqual(row.level?.level, 30)
        XCTAssertEqual(row.level?.rangeTop, 80)
        XCTAssertEqual(row.spread, "Its dimmers are 30–80% right now")
    }

    /// An off dimmer counts as 0 — it is a dimmer sitting at the bottom, not an absence — so a
    /// room with one off dimmer reads 0.
    func testOneOffDimmerTakesTheKnobToZero() {
        appKitUp()
        let row = roomRow()
        setRoom(row, [Fixtures.device(id: "1", power: true, brightness: 80),
                      Fixtures.device(id: "2", power: false, brightness: 40)])
        XCTAssertEqual(row.level?.level, 0)
        XCTAssertEqual(row.level?.rangeTop, 80)
        XCTAssertEqual(row.spread, "Its dimmers run from off up to 80%")
    }

    /// Exactly the devices `setBrightness(ofAll:)` would move: `canSetLevel && connected`. A
    /// plain switch and an unreachable dimmer are neither the floor nor the top.
    func testSwitchesAndUnreachableDevicesAreLeftOut() {
        appKitUp()
        let row = roomRow()
        setRoom(row, [Fixtures.device(id: "1", power: true, brightness: 60),
                      Fixtures.device(id: "2", power: false, canSetLevel: false),          // a switch, off
                      Fixtures.device(id: "3", power: true, brightness: 10, connected: false)])
        XCTAssertEqual(row.level?.level, 60)
        XCTAssertNil(row.level?.rangeTop)
        XCTAssertNil(row.spread)
    }

    /// The reported level is clamped to the device's own limits before it is compared.
    func testLevelsAreClampedBeforeTheyAreCompared() {
        appKitUp()
        let row = roomRow()
        setRoom(row, [Fixtures.device(id: "1", power: true, brightness: 3, minLevel: 20),
                      Fixtures.device(id: "2", power: true, brightness: 250, maxLevel: 90)])
        XCTAssertEqual(row.level?.level, 20)
        XCTAssertEqual(row.level?.rangeTop, 90)
    }

    /// Every lit dimmer at one level: no band, and nothing to say in the tooltip.
    func testNoBandWhenEveryDimmerMatches() {
        appKitUp()
        let row = roomRow()
        setRoom(row, [Fixtures.device(id: "1", power: true, brightness: 45),
                      Fixtures.device(id: "2", power: true, brightness: 45)])
        XCTAssertEqual(row.level?.level, 45)
        XCTAssertNil(row.level?.rangeTop)
        XCTAssertNil(row.spread)
    }

    /// A room with no dimmer in it has a dead slider, not a slider at 0 that would do something.
    func testARoomWithNoDimmersDisablesTheSlider() {
        appKitUp()
        let row = roomRow()
        setRoom(row, [Fixtures.device(id: "1", power: true, canSetLevel: false)])
        XCTAssertEqual(row.level?.level, 0)
        XCTAssertEqual(row.level?.isEnabled, false)
        XCTAssertNil(row.spread)
    }

    /// A refresh landing mid-drag must not yank the knob out from under the mouse.
    func testAnUpdateMidDragLeavesTheKnobAlone() {
        appKitUp()
        let row = roomRow()
        setRoom(row, [Fixtures.device(id: "1", power: true, brightness: 80)])
        XCTAssertEqual(row.level?.level, 80)
        startDrag()
        row.level?.level = 20
        row.level?.changed()                       // a drag in progress: no mouse-up yet
        XCTAssertEqual(row.level?.dragging, true)
        setRoom(row, [Fixtures.device(id: "1", power: true, brightness: 55)])
        XCTAssertEqual(row.level?.level, 20, "the drag owns the knob until it is released")
    }

    /// `update(room:devices:)` is the room case of the same row: the tally counts reachable
    /// devices and the tooltip says which way a click would go.
    func testRoomUpdateCountsReachableDevicesAndTellsTheTooltip() throws {
        appKitUp()
        let row = roomRow()
        let devices = [Fixtures.device(id: "1", name: "Desk", power: true, brightness: 60),
                       Fixtures.device(id: "2", name: "Lamp", power: false, brightness: 20),
                       Fixtures.device(id: "3", name: "Gone", power: true, connected: false)]
        row.update(room: Room(id: "r", name: "Alcove", power: true), devices: devices)
        XCTAssertTrue(row.isEnabled)
        XCTAssertTrue(texts(row).contains("Alcove"))
        XCTAssertTrue(texts(row).contains("1 of 2 on"), "the unreachable device is in neither half")
        let tip = try XCTUnwrap(row.toolTip)
        XCTAssertTrue(tip.contains("Click to turn the whole room off"), tip)
        XCTAssertTrue(tip.contains("The slider sets every dimmer in it"), tip)
        XCTAssertTrue(tip.contains("Its dimmers run from off up to 60%"), tip)
    }

    /// Nothing reachable: the row goes dead and says so rather than showing "0 of 0 on".
    func testAnAllOfflineRoomIsDisabled() {
        appKitUp()
        let row = roomRow()
        row.update(room: Room(id: "r", name: "Alcove", power: false),
                   devices: [Fixtures.device(id: "1", connected: false)])
        XCTAssertFalse(row.isEnabled)
        XCTAssertTrue(texts(row).contains("offline"))
    }

    // MARK: DeviceRow — the ⌥ reveal

    private func deviceRow(_ d: Device, setLevel: @escaping (Int) -> Void = { _ in }) -> DeviceRow {
        DeviceRow(device: d, indent: 18, toggle: {}, setLevel: setLevel)
    }

    /// ⌥ swaps the level UI for `model · firmware` and back. Both views exist all along; two
    /// `isHidden` flags and one constraint are the whole of it, so the menu's structure never
    /// changes while it is open.
    func testOptionRevealSwapsTheSliderForModelAndFirmware() {
        appKitUp()
        let row = deviceRow(Fixtures.device(id: "1", name: "Desk", model: "D36HD",
                                            power: true, brightness: 70))
        XCTAssertFalse(row.showsDetail)
        XCTAssertEqual(row.level?.isHidden, false)
        XCTAssertTrue(row.info.isHidden)

        row.showsDetail = true
        XCTAssertEqual(row.level?.isHidden, true)
        XCTAssertFalse(row.info.isHidden)
        XCTAssertEqual(row.info.stringValue, "D36HD · 1.0.15")

        row.showsDetail = false
        XCTAssertEqual(row.level?.isHidden, false)
        XCTAssertTrue(row.info.isHidden)
    }

    /// A plain switch has no slider at all, and ⌥ still has to do something visible.
    func testOptionRevealOnASwitch() {
        appKitUp()
        let row = deviceRow(Fixtures.device(id: "1", name: "Bookcase", model: "DW15S",
                                            canSetLevel: false))
        XCTAssertNil(row.level)
        row.showsDetail = true
        XCTAssertFalse(row.info.isHidden)
        XCTAssertEqual(row.info.stringValue, "DW15S · 1.0.15")
    }

    /// Either half can be missing off a record; both missing is a dash, never an empty row.
    func testDetailFallsBackToADash() {
        appKitUp()
        func bare(model: String, version: String) -> Device {
            Device(id: "1", residenceId: "100", roomId: nil, name: "Lamp", model: model,
                   version: version, serial: "SER", power: false, brightness: 0, minLevel: 5,
                   maxLevel: 100, canSetLevel: true, connected: true, includeInRoomOnOff: true)
        }
        XCTAssertEqual(deviceRow(bare(model: "", version: "")).info.stringValue, "—")
        XCTAssertEqual(deviceRow(bare(model: "D26HD", version: "")).info.stringValue, "D26HD")
        XCTAssertEqual(deviceRow(bare(model: "", version: "1.7.1; CP 1.13")).info.stringValue, "1.7.1; CP 1.13")
    }

    /// A reveal asked for mid-drag waits: hiding a slider that is tracking does not stop the
    /// cell's loop, and the level would still be committed from a control that had vanished.
    func testRevealMidDragIsDeferred() {
        appKitUp()
        let row = deviceRow(Fixtures.device(id: "1", power: true, brightness: 70))
        startDrag()
        row.level?.level = 45
        row.level?.changed()
        XCTAssertEqual(row.level?.dragging, true)
        row.showsDetail = true
        XCTAssertTrue(row.showsDetail, "the flag moves…")
        XCTAssertEqual(row.level?.isHidden, false, "…but the views do not, until the release")
        XCTAssertTrue(row.info.isHidden)
    }

    /// An update arriving while the slider is being dragged is likewise ignored.
    func testDeviceUpdateMidDragLeavesTheKnobAlone() {
        appKitUp()
        let row = deviceRow(Fixtures.device(id: "1", power: true, brightness: 70))
        XCTAssertEqual(row.level?.level, 70)
        startDrag()
        row.level?.level = 45
        row.level?.changed()
        row.device = Fixtures.device(id: "1", power: true, brightness: 20)
        XCTAssertEqual(row.level?.level, 45)
    }

    /// The row follows its device: off reads 0 %, and a reported level is clamped to the
    /// device's own limits before it is shown.
    func testRowFollowsItsDevice() {
        appKitUp()
        let row = deviceRow(Fixtures.device(id: "1", name: "Desk", power: true, brightness: 70))
        XCTAssertEqual(row.level?.level, 70)
        row.device = Fixtures.device(id: "1", name: "Desk", power: false, brightness: 70)
        XCTAssertEqual(row.level?.level, 0, "an off dimmer reads 0 %, as in the My Leviton app")
        row.device = Fixtures.device(id: "1", name: "Desk", power: true, brightness: 2, minLevel: 5)
        XCTAssertEqual(row.level?.level, 5)
    }

    /// Unreachable: the row goes dead, the slider with it, and the name carries the reason.
    func testAnOfflineDeviceRowIsDisabled() {
        appKitUp()
        let row = deviceRow(Fixtures.device(id: "1", name: "760 Fridge", power: true,
                                            brightness: 40, connected: false))
        XCTAssertFalse(row.isEnabled)
        XCTAssertEqual(row.level?.isEnabled, false)
        XCTAssertTrue(texts(row).contains("760 Fridge  —  offline"))
        XCTAssertTrue(row.toolTip?.contains("Not reachable by My Leviton") ?? false)
    }

    /// The slider's release is the only thing that writes a level, and it carries the snapped
    /// value through to the row's `setLevel`.
    func testSliderReleaseWritesTheLevel() throws {
        appKitUp()
        var written: [Int] = []
        let row = deviceRow(Fixtures.device(id: "1", power: true, brightness: 70, minLevel: 5),
                            setLevel: { written.append($0) })
        row.level?.level = 43
        try XCTSkipUnless(setCurrentEvent(release: true),
                          "no event queue in this test host: NSApp.currentEvent never becomes a mouse-up")
        row.level?.changed()
        XCTAssertEqual(written, [45])
    }

    // MARK: MenuRow / TextRow basics

    /// The text inset is AppKit's own, including the state (checkmark) column that "Launch at
    /// Login" brings into the menu — a view-based row that ignores it is visibly out of line
    /// with the plain items above and below it.
    func testRowMetrics() {
        appKitUp()
        XCTAssertEqual(MenuRow.textInset, 24)
        XCTAssertEqual(MenuRow.edgeInset, 5)
        XCTAssertEqual(MenuRow.height, 24)
        XCTAssertEqual(MenuRow.width, 360)
    }

    /// The rows draw their own hover highlight, because a view-based row gets none from the
    /// menu — and the menu closing sends no `mouseExited`, so the controller clears it by hand.
    func testHoverIsTheRowsOwnBusiness() {
        appKitUp()
        let row = TextRow {}
        row.set("Refresh", detail: "live")
        XCTAssertFalse(row.hovered)
        XCTAssertEqual(row.textColor, NSColor.labelColor)
        row.mouseEntered(with: NSEvent())
        XCTAssertTrue(row.hovered)
        XCTAssertEqual(row.textColor, NSColor.selectedMenuItemTextColor)
        row.clearHover()
        XCTAssertFalse(row.hovered)
    }

    /// A disabled row neither highlights nor dims into the hovered colours.
    func testDisabledRowsDoNotHover() {
        appKitUp()
        let row = TextRow {}
        row.mouseEntered(with: NSEvent())
        XCTAssertTrue(row.hovered)
        row.isEnabled = false
        XCTAssertFalse(row.hovered, "turning a row off clears a highlight it already has")
        row.mouseEntered(with: NSEvent())
        XCTAssertFalse(row.hovered)
        XCTAssertEqual(row.textColor, NSColor.tertiaryLabelColor)
    }

    /// The last error rides on the Refresh row in orange — except under the highlight, where
    /// orange on blue is worse than the menu's own selected colour.
    func testTextRowWarningColour() {
        appKitUp()
        let row = TextRow {}
        row.set("Refresh", detail: "⚠︎ Desk: my.leviton.com timed out", warning: true)
        XCTAssertEqual(Set(texts(row)), ["Refresh", "⚠︎ Desk: my.leviton.com timed out"])
        let detail = row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("⚠︎") }
        XCTAssertEqual(detail?.textColor, NSColor.systemOrange)
        row.mouseEntered(with: NSEvent())
        row.set("Refresh", detail: "⚠︎ Desk: my.leviton.com timed out", warning: true)
        XCTAssertNotEqual(detail?.textColor, NSColor.systemOrange)
    }

    /// A click on a row runs its action (and the menu stays open — that is what the view is
    /// for). A disabled row swallows it.
    func testClickRunsTheAction() throws {
        appKitUp()
        var clicks = 0
        let row = TextRow { clicks += 1 }
        row.set("All Lights On")
        let inside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp,
                                                      location: NSPoint(x: 40, y: 12),
                                                      modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        row.mouseUp(with: inside)
        XCTAssertEqual(clicks, 1)
        row.isEnabled = false
        row.mouseUp(with: inside)
        XCTAssertEqual(clicks, 1)
    }

    /// Autolayout has to resolve offscreen: an ambiguous frame here is a row that draws
    /// nothing in the real menu.
    func testRowsLayOutWithoutAWindow() {
        appKitUp()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: MenuRow.width, height: MenuRow.height * 3))
        let device = deviceRow(Fixtures.device(id: "1", name: "Desk", power: true, brightness: 70))
        let room = roomRow()
        setRoom(room, [Fixtures.device(id: "1", power: true, brightness: 70)], detail: "1 of 1 on")
        let text = TextRow {}
        text.set("Refresh", detail: "live")
        for (i, row) in [device, room, text].enumerated() {
            row.frame = NSRect(x: 0, y: MenuRow.height * CGFloat(i), width: MenuRow.width, height: MenuRow.height)
            host.addSubview(row)
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(device.hasAmbiguousLayout)
        XCTAssertFalse(room.hasAmbiguousLayout)
        XCTAssertFalse(text.hasAmbiguousLayout)
        device.showsDetail = true
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(device.hasAmbiguousLayout, "the ⌥ swap must not leave a view without a frame")
    }
}
