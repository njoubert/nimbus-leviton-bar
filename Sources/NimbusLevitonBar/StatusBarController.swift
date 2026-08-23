// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpdater

/// The status item (a lightbulb, filled when any light is on, with the count) and its
/// dropdown: rooms in My Leviton's order, one row per device under each — click to toggle,
/// drag a dimmer's slider — and the rows that keep the menu open are views (`MenuRows.swift`).
///
/// The menu is rebuilt each time it opens and updated *in place* while it is open
/// (`removeAllItems()` under tracking flickers and loses hover), so every row that can
/// change keeps a handle in `deviceRows` / `roomRows` / `allRow` / `statusRow`.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let store: DeviceStore
    /// nil when this launch has no business updating anything (the `--dump-bar` screenshot run).
    private let updater: Updater?
    private var menuOpen = false

    private var deviceRows: [String: DeviceRow] = [:]
    private var roomRows: [String: RoomRow] = [:]
    private var allRow: RoomRow?
    private var statusRow: TextRow?
    private var lastBar: (on: Int, summary: String, signedIn: Bool)?
    private var askingForCode = false
    private var versionItem: NSMenuItem?

    init(store: DeviceStore, updater: Updater? = nil) {
        self.store = store
        self.updater = updater
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        store.onChange = { [weak self] in self?.storeChanged() }
        updateBar()
    }

    private func storeChanged() {
        updateBar()
        if let login = store.awaitingCode, !askingForCode {
            askingForCode = true
            defer { askingForCode = false }
            if let code = SignInDialog.askCode(email: login.email) { store.signIn(login, code: code) }
        }
        guard menuOpen else { return }
        // Rows for devices we already show update in place; anything structural (a device
        // appearing, sign-in state changing) waits for the next open.
        for r in store.residences {
            for d in r.devices { deviceRows[d.id]?.device = d }
            for room in r.rooms { roomRows[room.id]?.update(room: room, devices: r.devices(in: room)) }
        }
        updateAllRow()
        updateStatusRow()
    }

    /// Render the status button itself (layout check without a screen grab).
    func dumpBar(to path: String) -> Bool {
        guard let b = item.button, let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { return false }
        b.cacheDisplay(in: b.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: Bar

    private func updateBar() {
        let on = store.devicesOn, summary = store.summary + (store.lastError ?? ""), signedIn = store.isSignedIn
        if let l = lastBar, l == (on, summary, signedIn) { return }
        lastBar = (on, summary, signedIn)
        guard let button = item.button else { return }
        let name = !signedIn ? "lightbulb.slash" : on > 0 ? "lightbulb.fill" : "lightbulb"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "lights")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        button.image = image
        button.imagePosition = on > 0 ? .imageLeading : .imageOnly
        button.title = on > 0 ? "\(on)" : ""
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.toolTip = "Nimbus Leviton Bar — \(summary)" + (store.lastError.map { "\n⚠︎ \($0)" } ?? "")
    }

    // MARK: Menu lifecycle

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        store.refreshIfStale()
        updater?.checkIfStale()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        for v in menu.items.compactMap({ $0.view as? MenuRow }) { v.clearHover() }
    }

    private func rebuild() {
        menu.removeAllItems()
        deviceRows = [:]
        roomRows = [:]
        allRow = nil
        statusRow = nil

        switch store.state {
        case .signedOut:
            menu.addItem(action("Sign in to My Leviton…", #selector(signIn)))
        case .signingIn:
            menu.addItem(disabled("Signing in…"))
        case .loading:
            menu.addItem(disabled("Loading your devices…"))
        case .error(let message):
            menu.addItem(disabled("Could not reach My Leviton", detail: message))
            menu.addItem(action("Retry", #selector(retry)))
            if store.isSignedIn == false, store.email != nil {
                menu.addItem(action("Sign in again…", #selector(signIn)))
            }
        case .ready:
            addDevices()
        }

        menu.addItem(.separator())

        // Refresh, with when the list was last fetched — or the last error — as its detail.
        let status = TextRow { [weak self] in self?.store.refresh() }
        status.isEnabled = store.isSignedIn
        menu.addItem(viewItem(status))
        statusRow = status
        updateStatusRow()

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        if LoginItem.status == .requiresApproval { login.title = "Launch at Login (approve in System Settings)" }
        if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            login.toolTip = "This copy runs from \(Bundle.main.bundlePath). Registering it points the Login Item at this path — use ./build.sh install for the real thing."
        }
        menu.addItem(login)
        addUpdateItems()
        menu.addItem(action("Open My Leviton on the Web", #selector(openWeb)))
        if store.isSignedIn || store.email != nil {
            menu.addItem(action("Sign Out\(store.email.map { " (\($0))" } ?? "")", #selector(signOut)))
        }
        menu.addItem(.separator())

        let versionText = Self.versionString()
        let version = NSMenuItem(title: versionText, action: #selector(copyValue(_:)), keyEquivalent: "")
        version.target = self
        version.representedObject = versionText   // copy the version, not the update note
        version.toolTip = "Click to copy"
        menu.addItem(version)
        versionItem = version
        updateVersionRow()
        menu.addItem(NSMenuItem(title: "Quit Nimbus Leviton Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Device rows

    private func addDevices() {
        if store.devices.isEmpty {
            menu.addItem(disabled("No devices on this account"))
            return
        }
        // The master switch first, then the rooms.
        let all = RoomRow(dimmers: store.devices.contains { $0.canSetLevel },
                          toggle: { [weak self] in
                              guard let self else { return }
                              self.store.setAll(on: self.store.devicesOn == 0)
                          },
                          setLevel: { [weak self] level in self?.store.setBrightness(ofAll: nil, level) })
        menu.addItem(viewItem(all))
        allRow = all
        updateAllRow()

        let several = store.residences.count > 1
        var first = false
        for r in store.residences {
            if several {
                if !first { menu.addItem(.separator()) }
                let h = disabled(r.name)
                h.attributedTitle = NSAttributedString(string: r.name.uppercased(), attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize).withWeight(.semibold),
                    .foregroundColor: NSColor.secondaryLabelColor])
                menu.addItem(h)
            }
            // Rooms in My Leviton's order, all-offline rooms last; within a room, offline
            // devices last. Rooms with no Wi-Fi device are left out.
            for room in r.displayRooms {
                let inRoom = r.displayDevices(in: room)
                if !first { menu.addItem(.separator()) }
                first = false
                let row = RoomRow(dimmers: inRoom.contains { $0.canSetLevel },
                                  toggle: { [weak self] in self?.store.toggleRoom(room.id) },
                                  setLevel: { [weak self] level in self?.store.setBrightness(ofAll: room.id, level) })
                row.update(room: room, devices: inRoom)
                menu.addItem(viewItem(row))
                roomRows[room.id] = row
                for d in inRoom { addDevice(d, indent: 18) }
            }
            let rest = r.unassigned
            if !rest.isEmpty {
                if !first { menu.addItem(.separator()) }
                first = false
                let h = disabled("No room")
                h.attributedTitle = NSAttributedString(string: "No room", attributes: [
                    .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold), .foregroundColor: NSColor.secondaryLabelColor])
                menu.addItem(h)
                for d in rest { addDevice(d, indent: 18) }
            }
        }
    }

    private func addDevice(_ d: Device, indent: CGFloat) {
        let row = DeviceRow(device: d, indent: indent,
                            toggle: { [weak self] in self?.store.toggle(d.id) },
                            setLevel: { [weak self] level in self?.store.setBrightness(d.id, level) })
        menu.addItem(viewItem(row))
        deviceRows[d.id] = row
    }

    /// ● All Devices      6 of 13 on · 3 offline — green when anything is on, hollow when all
    /// off, red when nothing is reachable or the last request failed.
    private func updateAllRow() {
        guard let row = allRow else { return }
        let trouble = store.lastError != nil || { if case .error = store.state { return true } else { return false } }()
        let dot: MenuRow.Dot = trouble || store.devicesReachable == 0 ? .offline : store.devicesOn > 0 ? .on : .off
        row.set(dot: dot, name: "All Devices", detail: store.tally, enabled: store.devicesReachable > 0, devices: store.devices)
        row.toolTip = store.summary + "\n"
            + (store.devicesReachable == 0 ? "Nothing is reachable right now"
               : "Click to turn everything \(store.devicesOn > 0 ? "off" : "on")\nThe slider sets every dimmer in the home")
            + (store.lastError.map { "\n⚠︎ \($0)" } ?? "")
    }

    private func updateStatusRow() {
        guard let row = statusRow else { return }
        if let e = store.lastError {
            row.set("Refresh", detail: "⚠︎ \(e)", warning: true)
            row.toolTip = e
        } else if let t = store.lastRefresh {
            row.set("Refresh", detail: "updated \(Self.clock.string(from: t))")
            row.toolTip = "Fetched from My Leviton at \(Self.clock.string(from: t)); refreshes by itself every minute"
        } else {
            row.set("Refresh", detail: "not updated yet")
            row.toolTip = nil
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium; return f
    }()

    // MARK: Actions

    @objc private func retry() { store.retry() }
    @objc private func openWeb() { NSWorkspace.shared.open(URL(string: "https://my.leviton.com")!) }

    @objc private func signIn() {
        guard let login = SignInDialog.run(email: store.email) else { return }
        store.signIn(login)
    }

    @objc private func signOut() { store.signOut() }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
            UserDefaults.standard.set(true, forKey: LoginItem.registeredDefaultsKey)
        } catch { NSLog("login item: \(error)") }
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Updates

    /// Above "Open My Leviton on the Web": what the updater has, if anything, and the two
    /// controls. Nothing here appears when the app runs from anywhere but /Applications
    /// except the manual check, which then just opens the release page.
    private func addUpdateItems() {
        guard let updater else { return }
        switch updater.state {
        case .ready(let release) where updater.canInstall:
            let install = action("Install Update \(release.version) and Relaunch", #selector(installUpdate))
            let firstLines = release.notes.split(separator: "\n").prefix(3).joined(separator: "\n")
            install.toolTip = firstLines.isEmpty
                ? "Downloaded and checked against this app's Developer ID. Installs in a few seconds."
                : firstLines
            menu.addItem(install)
        case .available(let release):
            let item = action("Update \(release.version) Available…", #selector(openUpdatePage))
            item.toolTip = updater.canInstall
                ? "That release has no installable download; this opens its page."
                : "Updates install only into /Applications, and this copy runs from \(Bundle.main.bundlePath). Opens the release page."
            menu.addItem(item)
        case .downloading(let release):
            menu.addItem(disabled("Downloading \(release.version)…"))
        case .installing:
            menu.addItem(disabled("Installing…"))
        default:
            break
        }

        let check = action("Check for Updates…", #selector(checkForUpdates))
        switch updater.state {
        case .checking, .downloading, .installing: check.isEnabled = false
        default: break
        }
        menu.addItem(check)

        if updater.canInstall {
            let auto = NSMenuItem(title: "Check for Updates Automatically",
                                  action: #selector(toggleAutomaticUpdates(_:)), keyEquivalent: "")
            auto.target = self
            auto.state = updater.automaticChecks ? .on : .off
            auto.toolTip = "Once a day, asks github.com for the newest release and downloads it."
            menu.addItem(auto)
        }
    }

    /// The updater moved. Structural changes wait for the next open (the menu must not be
    /// rebuilt under the cursor), but the version line can say so straight away.
    func updaterChanged() {
        guard menuOpen else { return }
        updateVersionRow()
    }

    private func updateVersionRow() {
        guard let item = versionItem else { return }
        var text = Self.versionString()
        if let updater, case .ready(let release) = updater.state { text += "  ·  \(release.version) ready" }
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor])
    }

    @objc private func installUpdate() { updater?.installAndRelaunch() }

    @objc private func openUpdatePage() { updater?.openReleasePage() }

    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        guard let updater else { return }
        updater.automaticChecks.toggle()
        sender.state = updater.automaticChecks ? .on : .off
    }

    /// The manual check always goes to the network and always says what happened — the one
    /// place the updater is allowed to put something on screen.
    @objc private func checkForUpdates() {
        guard let updater else { return }
        Task { @MainActor in
            let state = await updater.checkNow()
            let alert = NSAlert()
            switch state {
            case .ready(let release):
                alert.messageText = "Update \(release.version) is ready"
                alert.informativeText = "Choose \u{201C}Install Update \(release.version) and Relaunch\u{201D} in the menu."
            case .available(let release):
                alert.messageText = "Version \(release.version) is available"
                alert.informativeText = updater.canInstall
                    ? "That release has no installable download — open its page to get it."
                    : "Updates install only into /Applications, and this copy runs from \(Bundle.main.bundlePath)."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Release Page")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn { updater.openReleasePage() }
                return
            case .failed(let message, _):
                alert.messageText = "Could not check for updates"
                alert.informativeText = message
                alert.alertStyle = .warning
            default:
                alert.messageText = "You\u{2019}re up to date"
                alert.informativeText = "\(Self.versionString()) is the newest release."
            }
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Helpers

    private func viewItem(_ v: NSView) -> NSMenuItem {
        let it = NSMenuItem()
        it.view = v
        return it
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        return it
    }

    private func disabled(_ title: String, detail: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        if let detail {
            let t = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            t.append(NSAttributedString(string: detail, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
            it.attributedTitle = t
        }
        return it
    }

    static func versionString() -> String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "dev build" }
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return "v\(short)\(build)"
    }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let d = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}
