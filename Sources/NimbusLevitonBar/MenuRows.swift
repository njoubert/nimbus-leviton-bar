// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The menu's clickable rows are views, not plain NSMenuItems, for one reason: a view that
/// handles its own mouse-up does not close the menu (only `NSMenu.cancelTracking()` does),
/// so you can flip several lights in one visit. The price is that the view has to look like
/// a menu row itself — the hover highlight below mimics AppKit's — and that keyboard
/// navigation skips these rows.
///
/// `MenuRow` is the base: fixed height, hover highlight, click → `onClick`, an enabled flag.
/// `DeviceRow` / `RoomRow` / `TextRow` lay their content over it.
@MainActor
class MenuRow: NSView {
    static let height: CGFloat = 24
    static let width: CGFloat = 360
    /// The highlight's inset from the menu edge, and the text's inset — AppKit's own, which
    /// includes the state (checkmark) column that "Launch at Login" brings into the menu.
    static let edgeInset: CGFloat = 5
    static let textInset: CGFloat = 24

    var onClick: (() -> Void)?
    var isEnabled = true { didSet { if !isEnabled { hovered = false }; refreshAppearance() } }
    private(set) var hovered = false { didSet { highlight.isHidden = !hovered; refreshAppearance() } }

    private let highlight: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .selection
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.isHidden = true
        return v
    }()
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuRow.width, height: MenuRow.height))
        autoresizingMask = [.width]
        highlight.frame = bounds.insetBy(dx: MenuRow.edgeInset, dy: 0)
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { hovered = true } }
    override func mouseExited(with event: NSEvent) { hovered = false }
    /// The menu closing sends no mouseExited; the controller calls this from menuDidClose.
    func clearHover() { hovered = false }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    /// Text turns white on the highlight, as in a real menu; disabled rows are dimmed.
    var textColor: NSColor { !isEnabled ? .tertiaryLabelColor : hovered ? .selectedMenuItemTextColor : .labelColor }
    var secondaryTextColor: NSColor { !isEnabled ? .quaternaryLabelColor : hovered ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.7) : .secondaryLabelColor }

    /// Subclasses recolour their labels here.
    func refreshAppearance() {}

    // MARK: Shared pieces

    /// NSTextField under-reports its intrinsic width by about a character once its line
    /// break mode is a truncating one ("2 of 4 on" came out as "2 of 4…" with room to spare),
    /// so truncating labels pad it back.
    final class Label: NSTextField {
        override var intrinsicContentSize: NSSize {
            var s = super.intrinsicContentSize
            if lineBreakMode == .byTruncatingTail { s.width += 6 }
            return s
        }
    }

    static func label(_ size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular, mono: Bool = false) -> NSTextField {
        let l = Label(labelWithString: "")
        l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .menuFont(ofSize: size).withWeight(weight)
        // Numbers never truncate, so they clip — and they never give way, the name on the left does.
        l.lineBreakMode = mono ? .byClipping : .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentCompressionResistancePriority(mono ? .required : .defaultLow, for: .horizontal)
        l.setContentHuggingPriority(mono ? .required : .defaultLow, for: .horizontal)
        return l
    }

    enum Dot { case on, off, offline }

    /// A 10 pt disc: green for on, hollow grey for off, dim red for unreachable.
    static func dotImage(_ dot: Dot) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let img = NSImage(size: size, flipped: false) { _ in
            let r = NSRect(x: 2, y: 2, width: 10, height: 10)
            let p = NSBezierPath(ovalIn: r)
            switch dot {
            case .on: NSColor.systemGreen.setFill(); p.fill()
            case .off: NSColor.tertiaryLabelColor.setStroke(); p.lineWidth = 1.2; p.stroke()
            case .offline: NSColor.systemRed.withAlphaComponent(0.55).setFill(); p.fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// A slider with its percent label. `level` 0 means off; anything above is floored at
/// `minLevel`. Dragging updates the label live; `onCommit` fires once, on release (the cloud
/// round-trip is slow and there is no point sending thirty intermediate levels).
@MainActor
final class LevelControl: NSView {
    static let sliderWidth: CGFloat = 100
    static let width: CGFloat = sliderWidth + 6 + 34

    var minLevel = 1
    var onCommit: ((Int) -> Void)?
    private(set) var dragging = false
    private let slider = NSSlider()
    private let percent = MenuRow.label(NSFont.smallSystemFontSize, mono: true)

    var level: Int {
        get { Int(slider.doubleValue.rounded()) }
        set { slider.doubleValue = Double(newValue); percent.stringValue = "\(newValue)%" }
    }
    var isEnabled: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue }
    }
    var textColor: NSColor {
        get { percent.textColor ?? .secondaryLabelColor }
        set { percent.textColor = newValue }
    }

    init(maxLevel: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        slider.minValue = 0
        slider.maxValue = Double(maxLevel)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        percent.alignment = .right
        addSubview(slider); addSubview(percent)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.widthAnchor.constraint(equalToConstant: Self.sliderWidth),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            percent.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            percent.trailingAnchor.constraint(equalTo: trailingAnchor),
            percent.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: MenuRow.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        var v = Int(slider.doubleValue.rounded())
        if v > 0 { v = max(v, minLevel) }   // the dimmer's floor; 0 means off
        percent.stringValue = "\(v)%"
        // isContinuous fires for every mouse move; the release comes as a leftMouseUp event.
        if NSApp.currentEvent?.type == .leftMouseUp {
            dragging = false
            onCommit?(v)
        } else {
            dragging = true
        }
    }
}

/// ● Name ————slider———— 42%   (slider and percent only for dimmers). Click the name or
/// the dot to toggle; drag the slider to set the level (sent on release, and the device is
/// switched on with it). As in the My Leviton app, an off dimmer reads 0 % with the slider
/// at the bottom, and dragging it to 0 turns the dimmer off; dragging above 0 turns it on at
/// that level (no lower than its minLevel).
@MainActor
final class DeviceRow: MenuRow {
    var device: Device { didSet { if !(level?.dragging ?? false) { sync() } } }
    private let dot = NSImageView()
    private let name = MenuRow.label()
    private var level: LevelControl?

    init(device: Device, indent: CGFloat, toggle: @escaping () -> Void, setLevel: @escaping (Int) -> Void) {
        self.device = device
        super.init()
        onClick = toggle
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot); addSubview(name)
        var constraints = [
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuRow.textInset + indent),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14), dot.heightAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if device.canSetLevel {
            let l = LevelControl(maxLevel: device.maxLevel)
            l.minLevel = device.minLevel
            l.onCommit = setLevel
            addSubview(l)
            level = l
            constraints += [
                name.trailingAnchor.constraint(lessThanOrEqualTo: l.leadingAnchor, constant: -8),
                l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuRow.textInset),
                l.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        } else {
            constraints.append(name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MenuRow.textInset))
        }
        NSLayoutConstraint.activate(constraints)
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func sync() {
        let d = device
        isEnabled = d.connected
        dot.image = MenuRow.dotImage(!d.connected ? .offline : d.power ? .on : .off)
        name.stringValue = d.connected ? d.name : "\(d.name)  —  offline"
        if let l = level {
            l.level = d.power ? d.levelClamped : 0
            l.isEnabled = d.connected
        }
        toolTip = "\(d.model) · \(d.serial)\n"
            + (d.connected ? "Click to turn \(d.power ? "off" : "on")" : "Not reachable by My Leviton")
        refreshAppearance()
    }

    override func refreshAppearance() {
        name.textColor = textColor
        level?.textColor = device.power ? secondaryTextColor : (hovered ? secondaryTextColor : .tertiaryLabelColor)
    }
}

/// ● Room name   2 of 3 on ————slider———— 42%   — click to switch the room (My Leviton's
/// room On/Off, which moves every device in the room); the slider, present when the room has
/// a dimmer, sets every reachable dimmer in it (0 = all off). Also used for "All Devices".
@MainActor
final class RoomRow: MenuRow {
    private let dot = NSImageView()
    private let name = MenuRow.label(weight: .semibold)
    private let count = MenuRow.label(NSFont.smallSystemFontSize, mono: true)
    private var level: LevelControl?

    /// `dimmers`: true adds the slider (it cannot be added later; the row is rebuilt on open).
    init(dimmers: Bool, toggle: @escaping () -> Void, setLevel: ((Int) -> Void)? = nil) {
        super.init()
        onClick = toggle
        dot.translatesAutoresizingMaskIntoConstraints = false
        count.alignment = .right
        addSubview(dot); addSubview(name); addSubview(count)
        var constraints = [
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuRow.textInset),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14), dot.heightAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if dimmers {
            let l = LevelControl(maxLevel: 100)
            l.onCommit = setLevel
            addSubview(l)
            level = l
            constraints += [
                count.trailingAnchor.constraint(equalTo: l.leadingAnchor, constant: -10),
                l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuRow.textInset),
                l.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        } else {
            constraints.append(count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuRow.textInset))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(room: Room, devices: [Device]) {
        let reachable = devices.filter(\.connected)
        let on = reachable.filter(\.power).count
        set(dot: reachable.isEmpty ? .offline : room.power ? .on : .off, name: room.name,
            detail: reachable.isEmpty ? "offline" : "\(on) of \(reachable.count) on", enabled: !reachable.isEmpty, devices: devices)
        toolTip = "Click to turn the whole room \(room.power ? "off" : "on")"
            + (level != nil ? "\nThe slider sets every dimmer in it" : "")
    }

    /// The same row for something that is not a room (All Devices). The slider, if any,
    /// shows the average level of the dimmers that are on.
    func set(dot d: MenuRow.Dot, name n: String, detail: String, enabled: Bool, devices: [Device]) {
        dot.image = MenuRow.dotImage(d)
        name.stringValue = n
        count.stringValue = detail
        isEnabled = enabled
        if let l = level, !l.dragging {
            let lit = devices.filter { $0.canSetLevel && $0.isOn }
            l.level = lit.isEmpty ? 0 : lit.map(\.levelClamped).reduce(0, +) / lit.count
            l.isEnabled = devices.contains { $0.canSetLevel && $0.connected }
        }
        refreshAppearance()
    }

    override func refreshAppearance() {
        name.textColor = textColor
        count.textColor = secondaryTextColor
        level?.textColor = secondaryTextColor
    }
}

/// A command row that keeps the menu open — All Lights On/Off, Refresh — laid out like a
/// plain menu item (same text inset), with an optional right-aligned detail: the time of the
/// last refresh, or the last error in orange.
@MainActor
final class TextRow: MenuRow {
    private let text = MenuRow.label()
    private let detail = MenuRow.label(NSFont.smallSystemFontSize, mono: true)
    private var warning = false

    init(action: @escaping () -> Void) {
        super.init()
        onClick = action
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(text); addSubview(detail)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuRow.textInset),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuRow.textInset),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ s: String, detail d: String = "", warning: Bool = false) {
        text.stringValue = s
        detail.stringValue = d
        self.warning = warning
        refreshAppearance()
    }

    override func refreshAppearance() {
        text.textColor = textColor
        detail.textColor = warning && !hovered ? .systemOrange : secondaryTextColor
    }
}

/// `--dump-menu`: the rows stacked with sample data, one of them hovered, rendered to a PNG
/// in both appearances — the layout check that needs no screen grab.
@MainActor
enum MenuRowPreview {
    static func write(to path: String) -> Bool {
        func device(_ name: String, on: Bool, level: Int = 100, dim: Bool = true, connected: Bool = true) -> Device {
            Device(id: name, residenceId: "1", roomId: "r", name: name, model: dim ? "DW3HL" : "DW15P", serial: "1000_0000_0000",
                   power: on, brightness: level, minLevel: 10, maxLevel: 100, canSetLevel: dim, connected: connected, includeInRoomOnOff: true)
        }
        let devices = [device("Desk", on: true, level: 100), device("Nightstand", on: false, level: 40),
                       device("Bookcase", on: false, dim: false), device("760 Fridge", on: false, dim: false, connected: false),
                       device("A very long lamp name that truncates", on: true, level: 73)]
        let room = Room(id: "r", name: "Niels' Room", power: true)

        var rows: [MenuRow] = []
        let roomRow = RoomRow(dimmers: true, toggle: {}, setLevel: { _ in })
        roomRow.update(room: room, devices: devices)
        rows.append(roomRow)
        for (i, d) in devices.enumerated() {
            let r = DeviceRow(device: d, indent: 18, toggle: {}, setLevel: { _ in })
            if i == 0 { r.mouseEntered(with: NSEvent()) }   // show the highlight on one row
            rows.append(r)
        }
        let all = RoomRow(dimmers: true, toggle: {}, setLevel: { _ in })
        all.set(dot: .on, name: "All Devices", detail: "6 of 13 on", enabled: true, devices: devices)
        let allBad = RoomRow(dimmers: false, toggle: {})
        allBad.set(dot: .offline, name: "All Devices", detail: "all offline", enabled: false, devices: [])
        let status = TextRow {}; status.set("Refresh", detail: "updated 10:36:48 PM")
        let warn = TextRow {}; warn.set("Refresh", detail: "⚠︎ Desk: my.leviton.com timed out", warning: true)
        rows += [all, allBad, status, warn]
        // Rows stacked top to bottom by frame, as the menu does it.
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: MenuRow.width, height: MenuRow.height * CGFloat(rows.count)))
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 0, y: stack.frame.height - MenuRow.height * CGFloat(i + 1), width: MenuRow.width, height: MenuRow.height)
            stack.addSubview(r)
        }

        // Both appearances side by side, on a menu-like background.
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: MenuRow.width * 2 + 30, height: stack.frame.height + 20))
        panel.wantsLayer = true
        var images: [NSImage] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            stack.appearance = NSAppearance(named: name)
            stack.layoutSubtreeIfNeeded()
            guard let rep = stack.bitmapImageRepForCachingDisplay(in: stack.bounds) else { return false }
            stack.cacheDisplay(in: stack.bounds, to: rep)
            let img = NSImage(size: stack.bounds.size); img.addRepresentation(rep)
            images.append(img)
        }
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(panel.frame.width) * 2, pixelsHigh: Int(panel.frame.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        out.size = panel.frame.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: MenuRow.width + 20, height: panel.frame.height).fill()
        NSColor(white: 0.18, alpha: 1).setFill(); NSRect(x: MenuRow.width + 20, y: 0, width: MenuRow.width + 10, height: panel.frame.height).fill()
        images[0].draw(at: NSPoint(x: 10, y: 10), from: .zero, operation: .sourceOver, fraction: 1)
        images[1].draw(at: NSPoint(x: MenuRow.width + 25, y: 10), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = out.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
