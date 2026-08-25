// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpdater

/// What the app is doing on the network, live: the state of My Leviton's push feed, every
/// REST request with its body and its reply, every websocket frame, and the app's own
/// milestones. Opened with ⌥ over the version line at the bottom of the menu — it is a
/// diagnostic, not a feature of the lights.
///
/// The buffer behind it (`Diagnostics`) fills from launch whether this window has ever been
/// opened or not, so the interesting failures — an auth backoff started an hour ago, a feed
/// that stopped delivering — are already in it by the time anyone looks.
///
/// It is a floating utility panel on purpose: the whole point is watching a frame arrive
/// while you click a light in the menu above it. Nothing here can change a device; the three
/// actions reconnect the feed, force a fetch, and force a re-login.
@MainActor
final class InternalsPanel: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private weak var store: DeviceStore?
    private let updater: Updater?

    private let panel: NSPanel
    private let header = NSTextField(wrappingLabelWithString: "")
    private let filter = NSSegmentedControl(labels: ["All", "REST", "Feed", "App"],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let table = NSTableView()
    private let detail = NSTextView()

    private var rows: [Diagnostics.Event] = []
    private var shownVersion = -1
    private var paused = false
    private var timer: Timer?

    private static let column = (time: NSUserInterfaceItemIdentifier("time"),
                                 kind: NSUserInterfaceItemIdentifier("kind"),
                                 title: NSUserInterfaceItemIdentifier("title"))

    init(store: DeviceStore, updater: Updater?) {
        self.store = store
        self.updater = updater
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()

        panel.title = "Internals — Nimbus Leviton Bar"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        // A closed panel that releases itself is a crash the next time the menu item is used.
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setFrameAutosaveName("InternalsPanel")
        panel.contentView = buildContent()
        if panel.frame.origin == .zero { panel.center() }
    }

    // MARK: Showing

    func show() {
        // An accessory app has no Dock icon to click, so nothing else would bring this
        // forward — and it has to become key for the detail pane's text to be selectable.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startTicking()
        reload(force: true)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    /// 4 Hz, and each tick does nothing unless `Diagnostics.version` moved. `.common` so it
    /// keeps running while a menu is being tracked — which is exactly when someone is
    /// watching this window to see what their click did.
    private func startTicking() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard panel.isVisible else { return }
        updateHeader()
        guard !paused else { return }
        reload(force: false)
    }

    // MARK: Content

    private func buildContent() -> NSView {
        header.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        header.translatesAutoresizingMaskIntoConstraints = false
        // Both of these are wanted at their natural height: without it the wrapping label
        // takes the window's spare vertical space and the list below it gets none.
        header.setContentHuggingPriority(.required, for: .vertical)
        header.setContentCompressionResistancePriority(.required, for: .vertical)

        filter.target = self
        filter.action = #selector(filterChanged)
        filter.selectedSegment = 0
        filter.segmentDistribution = .fillEqually

        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.bezelStyle = .rounded

        let controls = NSStackView(views: [filter, pauseButton,
                                           button("Copy", #selector(copyLog)),
                                           button("Clear", #selector(clearLog)),
                                           NSView(),
                                           button("Reconnect Feed", #selector(reconnectFeed)),
                                           button("Fetch Now", #selector(fetchNow)),
                                           button("Sign In Again", #selector(forceRelogin))])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setHuggingPriority(.required, for: .vertical)
        controls.setContentCompressionResistancePriority(.required, for: .vertical)
        filter.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The split view sizes its panes from the frames they already have, so the starting
        // frames *are* the divider position: roughly two thirds list, one third detail.
        let list = tableScrollView(), body = detailScrollView()
        list.frame = NSRect(x: 0, y: 0, width: 760, height: 320)
        body.frame = NSRect(x: 0, y: 0, width: 760, height: 160)
        split.addArrangedSubview(list)
        split.addArrangedSubview(body)
        split.autosaveName = "InternalsSplit"

        let content = NSView()
        content.addSubview(header)
        content.addSubview(controls)
        content.addSubview(split)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            controls.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            split.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        return content
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        return b
    }

    private func tableScrollView() -> NSScrollView {
        for (id, title, width) in [(Self.column.time, "Time", CGFloat(102)),
                                   (Self.column.kind, "", CGFloat(38)),
                                   (Self.column.title, "Event", CGFloat(560))] {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            if id == Self.column.title { c.resizingMask = [.autoresizingMask, .userResizingMask] }
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.headerView = nil
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        return scroll
    }

    private func detailScrollView() -> NSScrollView {
        detail.isEditable = false
        detail.isSelectable = true
        detail.drawsBackground = true
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textContainerInset = NSSize(width: 8, height: 8)
        // JSON reads far better scrolled sideways than wrapped.
        detail.isHorizontallyResizable = true
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detail.textContainer?.widthTracksTextView = false
        detail.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = detail
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        return scroll
    }

    // MARK: The list

    private func reload(force: Bool) {
        let version = Diagnostics.shared.version
        guard force || version != shownVersion else { return }
        shownVersion = version

        // Follow the tail unless the user has taken hold of the list — a selected row, or a
        // scroll away from the bottom, means they are reading rather than watching.
        let following = table.selectedRow < 0 && isNearBottom
        let selectedID = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].id : nil

        let kind: Diagnostics.Kind? = switch filter.selectedSegment {
        case 1: .rest
        case 2: .ws
        case 3: .app
        default: nil
        }
        let all = Diagnostics.shared.snapshot
        rows = kind.map { k in all.filter { $0.kind == k } } ?? all
        table.reloadData()

        if let selectedID, let i = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else if following, !rows.isEmpty {
            table.scrollRowToVisible(rows.count - 1)
        }
    }

    private var isNearBottom: Bool {
        guard let clip = table.enclosingScrollView?.contentView else { return true }
        let bottom = clip.documentRect.height - clip.bounds.height
        return bottom <= 0 || clip.bounds.origin.y >= bottom - table.rowHeight * 2
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let event = rows[row]
        let cell = reusableCell(column.identifier)
        switch column.identifier {
        case Self.column.time:
            cell.textField?.stringValue = Self.clock.string(from: event.at)
            cell.textField?.textColor = .secondaryLabelColor
        case Self.column.kind:
            cell.textField?.stringValue = event.kind.rawValue
            cell.textField?.textColor = .tertiaryLabelColor
        default:
            cell.textField?.stringValue = event.title
            cell.textField?.textColor = event.isError ? .systemRed
                : event.kind == .app ? .secondaryLabelColor : .labelColor
        }
        return cell
    }

    private func reusableCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let v = table.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return v }
        let v = NSTableCellView()
        v.identifier = id
        let f = NSTextField(labelWithString: "")
        f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        f.lineBreakMode = .byTruncatingTail
        f.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(f)
        v.textField = f
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            f.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            f.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else { detail.string = ""; return }
        let e = rows[row]
        var text = "\(Self.stamp.string(from: e.at))  \(e.kind.rawValue)  \(e.title)\n"
        text += String(repeating: "─", count: 72) + "\n"
        if let d = e.detail {
            // Bodies are stored raw and prettied here: one line per section, each parsed on
            // its own, so a request body and its reply both come out readable.
            text += d.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let s = String(line)
                    guard s.hasPrefix("{") || s.hasPrefix("[") else { return s }
                    return Diagnostics.pretty(s)
                }
                .joined(separator: "\n")
        } else {
            text += "(the body of this one has been let go — only the newest "
                + "\(Diagnostics.detailWindow) events keep theirs)"
        }
        detail.string = text
        detail.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    // MARK: The header

    private func updateHeader() {
        let feed = Diagnostics.shared.feed
        let rest = Diagnostics.shared.rest
        let session = Diagnostics.shared.session
        let store = self.store

        // The dot is the feed's own account of itself; the store's `isLive` is what the menu
        // shows, and the two disagreeing is itself worth seeing.
        let live = feed.state == "live"
        var line1 = "\(live ? "●" : "○") feed \(feed.state)"
        if let since = feed.since { line1 += " for \(Self.age(since))" }
        line1 += " · \(feed.subscriptions) subscriptions · \(feed.frames) frames"
        if let f = feed.lastFrame { line1 += " · last \(Self.age(f)) ago" }
        if let p = feed.lastPong { line1 += " · pong \(Diagnostics.ms(p))" }
        else if feed.lastPing != nil { line1 += " · ping unanswered" }
        if let next = feed.nextReconnect, next > Date() {
            line1 += " · retry in \(Int(next.timeIntervalSinceNow) + 1) s"
        }
        line1 += " · \(feed.connects) connects, \(feed.drops) drops"
        if let store, store.isLive != live { line1 += " · the menu says \(store.isLive ? "live" : "not live")" }

        var line2 = "REST \(rest.requests) requests · \(rest.failures) failed"
            + " · \(Diagnostics.bytes(rest.bytesIn)) in"
        if let d = rest.lastDuration { line2 += " · last \(Diagnostics.ms(d))" }
        line2 += " · \(rest.inFlight) in flight"
        if let store { line2 += " · \(store.writesInFlight) device writes pending" }

        var line3: String
        if let s = session {
            line3 = "session \(s.fingerprint) · user \(s.userId) · issued \(Self.age(s.created)) ago"
            line3 += s.expiry.map { " · expires \(Self.age($0, future: true))" } ?? " · no ttl"
            line3 += s.fresh ? "" : " · STALE"
        } else {
            line3 = "no session"
        }
        if let store {
            line3 += " · \(store.devices.count) devices, \(store.devicesOn) on, \(store.devicesOffline) offline"
            line3 += store.pollActive ? " · polling every \(Int(DeviceStore.pollInterval)) s" : " · not polling"
            line3 += store.lastRefresh.map { " · fetched \(Self.age($0)) ago" } ?? " · never fetched"
        }

        var line4 = "\(StatusBarController.versionString()) · \(Bundle.main.bundlePath)"
        line4 += " · login item \(LoginItem.statusDescription)"
        if let updater {
            line4 += " · updater \(Self.describe(updater.state))"
            line4 += updater.lastCheck.map { ", checked \(Self.age($0)) ago" } ?? ", never checked"
        }
        if let e = store?.lastError { line4 += "\n⚠︎ \(e)" }

        let text = NSMutableAttributedString(string: [line1, line2, line3, line4].joined(separator: "\n"),
                                             attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                                          .foregroundColor: NSColor.secondaryLabelColor])
        // The dot is the one thing worth finding at a glance.
        text.addAttribute(.foregroundColor,
                          value: live ? NSColor.systemGreen : NSColor.systemRed,
                          range: NSRange(location: 0, length: 1))
        header.attributedStringValue = text
    }

    private static func describe(_ state: Updater.State) -> String {
        switch state {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "up to date"
        case .available(let r): return "\(r.version) available"
        case .downloading(let r): return "downloading \(r.version)"
        case .ready(let r): return "\(r.version) ready"
        case .installing: return "installing"
        case .failed(let why, _): return "failed: \(why)"
        }
    }

    // MARK: Actions

    @objc private func filterChanged() { reload(force: true) }

    @objc private func togglePause() {
        paused.toggle()
        pauseButton.title = paused ? "Resume" : "Pause"
        if !paused { reload(force: true) }
    }

    /// The whole visible log, with the state block on top — everything here is already
    /// redacted, so it can go straight into a bug report.
    @objc private func copyLog() {
        var out = header.stringValue + "\n\n"
        for e in rows {
            out += "\(Self.stamp.string(from: e.at))  \(e.kind.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0))  \(e.title)\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
    }

    @objc private func clearLog() {
        Diagnostics.shared.clear()
        detail.string = ""
        reload(force: true)
    }

    @objc private func reconnectFeed() { store?.reconnectFeed() }

    @objc private func fetchNow() { store?.refresh() }

    /// Deliberately behind a confirmation: My Leviton locks an account that sees repeated
    /// sign-ins, and this is the one button here that spends one.
    @objc private func forceRelogin() {
        let alert = NSAlert()
        alert.messageText = "Sign in to My Leviton again?"
        alert.informativeText = "This drops the current session token and replays the saved "
            + "password once. My Leviton locks an account after repeated failed sign-ins, so "
            + "don't do this in a loop."
        alert.addButton(withTitle: "Sign In Again")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store?.forceRelogin() }
    }

    /// `--dump-internals` only: the laid-out content view, with one row selected so the
    /// detail pane has something in it.
    fileprivate func previewContent(selecting row: Int) -> NSView? {
        guard let content = panel.contentView else { return nil }
        content.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        reload(force: true)
        updateHeader()
        if row < rows.count { table.selectRowIndexes([row], byExtendingSelection: false) }
        content.layoutSubtreeIfNeeded()
        return content
    }

    // MARK: Formatting

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// "12 s", "4 min", "3 h" — short enough for a header that re-renders four times a second.
    private static func age(_ t: Date, future: Bool = false) -> String {
        let s = abs(future ? t.timeIntervalSinceNow : Date().timeIntervalSince(t))
        switch s {
        case ..<90: return "\(Int(s)) s"
        case ..<5400: return "\(Int(s / 60)) min"
        case ..<172_800: return "\(Int(s / 3600)) h"
        default: return "\(Int(s / 86_400)) days"
        }
    }
}

/// `--dump-internals`: the panel with a plausible session's worth of events in it, rendered
/// to a PNG in both appearances. The same trick as `--dump-menu`, for the same reason — the
/// window is as invisible to the accessibility API as the menu's view rows are.
@MainActor
enum InternalsPreview {
    static func write(to path: String) -> Bool {
        _ = NSApplication.shared        // a window cannot be made before the app object exists
        seed()
        // Held here for the length of the render: the panel keeps the store weakly, and a
        // temporary would be gone before the header was drawn.
        let store = DeviceStore()
        let panel = InternalsPanel(store: store, updater: nil)
        guard let content = panel.previewContent(selecting: 6) else { return false }
        defer { withExtendedLifetime(store) {} }

        var images: [NSImage] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            content.appearance = NSAppearance(named: name)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
            content.cacheDisplay(in: content.bounds, to: rep)
            let img = NSImage(size: content.bounds.size)
            img.addRepresentation(rep)
            images.append(img)
        }
        let size = NSSize(width: content.bounds.width * 2 + 30, height: content.bounds.height + 20)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: content.bounds.width + 20, height: size.height).fill()
        NSColor(white: 0.18, alpha: 1).setFill()
        NSRect(x: content.bounds.width + 20, y: 0, width: content.bounds.width + 10, height: size.height).fill()
        images[0].draw(at: NSPoint(x: 10, y: 10), from: .zero, operation: .sourceOver, fraction: 1)
        images[1].draw(at: NSPoint(x: content.bounds.width + 25, y: 10), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = out.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// A minute in the life of the app: a launch, a fetch, the feed coming up, a dimmer being
    /// set (the two-write kind), and something going wrong.
    private static func seed() {
        let d = Diagnostics.shared
        d.clear()
        d.setSession(Keychain.Session(token: "sample-token", userId: "402118",
                                      created: Date().addingTimeInterval(-86_400 * 3), ttl: 5_184_000))
        d.record(.app, "launch: using the saved session")
        d.record(.app, "fetched 13 devices in 1 residence")
        d.record(.app, "feed: connecting")
        d.record(.ws, "→ token", detail: ##"{"token":{"created":"2026-08-22T09:14:02.104Z","id":"#a3f19c","rememberMe":true,"ttl":5184000,"userId":402118}}"##)
        d.record(.ws, "← status ready", detail: #"{"type":"status","status":"ready"}"#)
        d.record(.ws, "→ subscribe 1613723", detail: #"{"subscription":{"modelId":1613723,"modelName":"IotSwitch"},"type":"subscribe"}"#)
        let put = d.beginRequest(method: "PUT", url: URL(string: "https://my.leviton.com/api/IotSwitches/1613723")!,
                                 path: "IotSwitches/1613723", body: ["power": "ON", "brightness": 70])
        d.endRequest(put, method: "PUT", path: "IotSwitches/1613723",
                     url: URL(string: "https://my.leviton.com/api/IotSwitches/1613723")!,
                     status: 200, started: Date().addingTimeInterval(-0.184),
                     data: Data(#"{"id":1613723,"name":"Entrance Track Lights","power":"ON","brightness":70,"presetLevel":30,"minLevel":10,"maxLevel":100,"canSetLevel":true,"connected":true,"model":"D36HD","residenceId":186779}"#.utf8))
        d.record(.app, "Entrance Track Lights: ON, then (after 2 seconds) 70%  [comes on at preset 30]")
        d.record(.ws, "← saved 1613723 30%", detail: #"{"type":"notification","notification":{"event":"saved","modelName":"IotSwitch","modelId":1613723,"data":{"brightness":30}}}"#)
        d.record(.ws, "← saved 1613723 70%", detail: #"{"type":"notification","notification":{"event":"saved","modelName":"IotSwitch","modelId":1613723,"data":{"brightness":70}}}"#)
        let get = d.beginRequest(method: "GET", url: URL(string: "https://my.leviton.com/api/Residences/186779/iotSwitches")!,
                                 path: "Residences/186779/iotSwitches", body: nil)
        d.failRequest(get, method: "GET", path: "Residences/186779/iotSwitches",
                      url: URL(string: "https://my.leviton.com/api/Residences/186779/iotSwitches")!,
                      started: Date().addingTimeInterval(-20), error: URLError(.timedOut))
        d.record(.app, "feed: no pong in 10 s — the connection is open but dead", isError: true)
        d.record(.app, "feed: reconnecting in 2 s")
        d.feed {
            $0.state = "live"
            $0.since = Date().addingTimeInterval(-742)
            $0.frames = 412
            $0.lastFrame = Date().addingTimeInterval(-3)
            $0.subscriptions = 13
            $0.lastPing = Date().addingTimeInterval(-8)
            $0.lastPong = 0.041
            $0.connects = 2
            $0.drops = 1
        }
        d.rest {
            $0.requests = 61
            $0.failures = 1
            $0.bytesIn = 1_284_221
            $0.lastDuration = 0.184
        }
    }
}
