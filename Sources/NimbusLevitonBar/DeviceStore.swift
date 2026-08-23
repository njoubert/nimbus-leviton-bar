// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

/// Owns what the menu shows: the residences and their devices, the sign-in state, and the
/// one client talking to my.leviton.com. All on the main actor; the client's calls are
/// awaited from Tasks that hop back here to publish results.
///
/// Writes are optimistic — a click flips the row at once and the request follows; if the
/// request fails, the row snaps back and an error is surfaced. Reads happen on launch, on
/// every menu open (throttled), on a slow timer so the bar icon stays right without the
/// menu ever being opened, and on every realtime push when the socket is up.
@MainActor
final class DeviceStore {

    enum State: Equatable {
        case signedOut
        case signingIn
        case loading            // signed in, first device list not yet back
        case ready
        case error(String)      // last refresh or command failed; devices may be stale
    }

    private(set) var state: State = .signedOut
    private(set) var residences: [Residence] = []
    private(set) var email: String?
    private(set) var lastRefresh: Date?
    /// True while the websocket is authenticated and subscribed, i.e. while changes arrive as
    /// they happen rather than on the next poll. Device *state* only — a device added, removed
    /// or renamed still comes from a fetch.
    private(set) var isLive = false
    /// Last transient error (a failed command, a failed poll) — shown in the menu, cleared
    /// by the next success.
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    private let client = LevitonClient()
    private var session: Keychain.Session?
    /// When the saved password was last replayed because a token was rejected. A second
    /// rejection inside `reloginCooldown` is *not* answered with another login: a 401 that
    /// survives a fresh token is not an expired token, and repeated logins are what gets a
    /// My Leviton account locked.
    private var lastRelogin: Date?
    /// Devices with a write in flight. Their realtime pushes are dropped: between the two PUTs
    /// of an off→on level change the device reports its preset, which is true but is not where
    /// it is going, and showing it makes the row jump.
    /// Counted, not a flag: a room slider can start a second write for a device while the first
    /// is still going, and the first one finishing must not drop the guard for the second.
    private var inFlight: [String: Int] = [:]
    static let reloginCooldown: TimeInterval = 600
    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var realtime: LevitonRealtime?
    private var wakeObserver: NSObjectProtocol?

    /// How often to poll while the menu is closed. Each poll is one small GET per residence.
    static let pollInterval: TimeInterval = 60
    /// Opening the menu refreshes unless the list is at most this old.
    static let openRefreshMinAge: TimeInterval = 3

    var devices: [Device] { residences.flatMap(\.devices) }
    var devicesOn: Int { devices.filter(\.isOn).count }
    var devicesReachable: Int { devices.filter(\.connected).count }
    var devicesOffline: Int { devices.count - devicesReachable }
    var isSignedIn: Bool { session != nil }

    /// "6 of 13 on" — the All Devices row's tally.
    var tally: String {
        guard isSignedIn else { return "signed out" }
        guard devicesReachable > 0 else { return devices.isEmpty ? "no devices" : "all offline" }
        return "\(devicesOn) of \(devicesReachable) on"
    }

    /// "6 of 13 on · 3 offline" — the bar's tooltip.
    var summary: String {
        guard isSignedIn else { return "Not signed in to My Leviton" }
        guard !devices.isEmpty else { return "No devices" }
        var t = "\(devicesOn) of \(devicesReachable) on"
        if devicesOffline > 0 { t += " · \(devicesOffline) offline" }
        return t
    }

    // MARK: Lifecycle

    init() {
        // Sleep suspends the ping timer, and a wake usually leaves the websocket half-open with
        // no error to notice — and whatever changed while we slept was never pushed. So: kick
        // the feed and refetch. Nothing else in the app watches sleep or the network.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session != nil else { return }
                self.realtime?.reconnectNow()
                self.refresh()
            }
        }
    }

    /// Pick up the saved session or password from the Keychain. Returns false when there is
    /// nothing saved and the caller should ask the user to sign in.
    func start() -> Bool {
        let login = Keychain.loadLogin()
        email = login?.email
        if let s = Keychain.loadSession(), s.isFresh {
            session = s
            state = .loading
            startPolling()
            refresh()
            return true
        }
        if let login {
            signIn(login, remember: false)
            return true
        }
        state = .signedOut
        notify()
        return false
    }

    /// A sign-in that came back "two-factor code required": the UI asks for the code and
    /// calls `signIn` again with it.
    private(set) var awaitingCode: Keychain.Login?

    func signIn(_ login: Keychain.Login, code: String? = nil, remember: Bool = true) {
        state = .signingIn
        email = login.email
        awaitingCode = nil
        if remember { lastRelogin = nil }   // a deliberate sign-in resets the re-login guard
        notify()
        Task {
            do {
                let s = try await client.login(email: login.email, password: login.password, code: code)
                if remember { try Keychain.saveLogin(login) }
                try? Keychain.saveSession(s)
                session = s
                lastError = nil
                state = .loading
                notify()
                startPolling()
                refresh()
            } catch {
                session = nil
                if case LevitonClient.Error.twoFactorRequired = error { awaitingCode = login }
                state = .error(Self.describe(error))
                notify()
            }
        }
    }

    /// Forget the session and the password. The server side is told too (best effort).
    func signOut() {
        if let s = session { Task { await client.logout(s) } }
        stopPolling()
        session = nil
        residences = []
        Keychain.deleteSession()
        Keychain.deleteLogin()
        state = .signedOut
        notify()
    }

    // MARK: Reading

    /// Reload everything (residences and devices). Coalesces: a refresh already in flight is
    /// left to finish rather than doubled up.
    func refresh() {
        guard let s = session, refreshTask == nil else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            do {
                let rs = try await client.residences(s)
                var out: [Residence] = []
                var skipped: [String] = []
                for r in rs {
                    do {
                        async let rooms = client.rooms(s, residenceId: r.id)
                        async let ds = client.devices(s, residenceId: r.id)
                        let sorted = try await ds.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        var res = Residence(id: r.id, name: r.name, rooms: try await rooms, devices: sorted)
                        Self.recomputeRooms(&res)
                        out.append(res)
                    } catch LevitonClient.Error.unauthorized {
                        // My Leviton 401s on a residence the token cannot see (a stale
                        // primaryResidenceId, a revoked share). Only when *every* residence
                        // does is the token itself the problem.
                        skipped.append(r.name)
                    }
                }
                if out.isEmpty, !skipped.isEmpty { throw LevitonClient.Error.unauthorized }
                checkFeedDelivered(out)
                residences = out
                lastRefresh = Date()
                lastError = skipped.isEmpty ? nil : "no access to \(skipped.joined(separator: ", "))"
                state = .ready
                notify()
                if let rt = realtime { rt.setDeviceIds(devices.map(\.id)) } else { startRealtime() }
            } catch LevitonClient.Error.unauthorized {
                // The token died (expired, or signed in elsewhere) — or keeps dying.
                handleUnauthorized()
            } catch {
                lastError = Self.describe(error)
                state = residences.isEmpty ? .error(lastError!) : .ready
                notify()
            }
        }
    }

    /// The menu's Retry: sign in again if there is no session (a failed sign-in leaves none),
    /// otherwise fetch again.
    func retry() {
        if session == nil, let login = Keychain.loadLogin() { signIn(login, remember: false) }
        else { refresh() }
    }

    /// A token was rejected. Replay the saved password once per cooldown; otherwise give up
    /// on this session and say so — the next poll tries again later.
    private func handleUnauthorized() {
        Keychain.deleteSession()
        session = nil
        stopPolling()
        let recent = lastRelogin.map { Date().timeIntervalSince($0) < Self.reloginCooldown } ?? false
        if !recent, let login = Keychain.loadLogin() {
            lastRelogin = Date()
            signIn(login, remember: false)
        } else {
            state = .error(recent ? "My Leviton keeps rejecting the session — will try again later" : "session expired")
            notify()
            if recent {
                // Try again after the cooldown rather than never.
                let t = Timer(timeInterval: Self.reloginCooldown, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.retry() }
                }
                RunLoop.main.add(t, forMode: .common)
            }
        }
    }

    /// The Refresh row. Unlike the poll, this also kicks a feed that isn't live: a websocket in
    /// its hour-long auth backoff is otherwise unreachable, and clicking Refresh is exactly the
    /// moment someone is telling us they think the app is behind.
    func refreshNow() {
        if !isLive { realtime?.reconnectNow() }
        refresh()
    }

    func refreshIfStale() {
        if let t = lastRefresh, Date().timeIntervalSince(t) < Self.openRefreshMinAge { return }
        refresh()
    }

    /// Put the store to sleep: no poll, no socket. Called before an update swaps the app out
    /// from under us, so the outgoing copy is not still talking while the new one starts.
    func stop() { stopPolling() }

    private func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = Self.pollInterval / 4   // let the kernel batch it with other timers
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        realtime?.stop()
        realtime = nil
        isLive = false   // the feed's own `false` arrives too late, and `realtime` is gone
    }

    private func startRealtime() {
        guard let s = session else { return }
        let rt = LevitonRealtime(session: s, deviceIds: devices.map(\.id))
        rt.onUpdate = { [weak self] id, fields in   // called on the main queue
            MainActor.assumeIsolated { self?.apply(id: id, fields: fields) }
        }
        rt.onLive = { [weak self, weak rt] live in   // also the main queue
            MainActor.assumeIsolated {
                // A feed we have already replaced must not report on the current one: its
                // final `false` can land after the new one is up.
                guard let self, let rt, self.realtime === rt, self.isLive != live else { return }
                self.isLive = live
                self.notify()
            }
        }
        rt.start()
        realtime = rt
    }

    /// The only test of *delivery* there is. A ping proves the connection is open; it says
    /// nothing about whether My Leviton is still honouring our subscriptions, and nothing acks
    /// a subscribe. But the poll refetches every device anyway: if it comes back with a level
    /// or a power state we were never told about, the feed missed a change and "live" is a lie
    /// — so drop it and reconnect.
    ///
    /// Only `power` and `brightness` are compared: those we know the feed reports. `connected`
    /// is deliberately left out — a device that falls off Wi-Fi may never announce it, and that
    /// is not the feed's fault. Devices with a write in flight are skipped, as are ones we have
    /// not seen before.
    ///
    /// A change that lands *during* the fetch trips this too, since the push arrives after the
    /// data was read. That costs one reconnect and a moment of "updated a few seconds ago",
    /// which is the right price for catching a feed that has gone quiet.
    private func checkFeedDelivered(_ fetched: [Residence]) {
        guard isLive else { return }
        let known = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in fetched {
            for d in r.devices {
                guard inFlight[d.id] == nil, let old = known[d.id] else { continue }
                guard old.power != d.power || old.brightness != d.brightness else { continue }
                // %@, not the string itself: a device name is user data and can hold a %.
                NSLog("%@", "realtime: the poll found \(d.name) at \(d.power ? "on" : "off") "
                    + "\(d.brightness)% and the feed never said so — reconnecting")
                isLive = false
                realtime?.reconnectNow()
                return
            }
        }
    }

    /// Merge a partial update (from the realtime feed) into the matching device.
    private func apply(id: String, fields: LevitonClient.DeviceFields) {
        guard inFlight[id] == nil, let (ri, di) = locate(id) else { return }
        var d = residences[ri].devices[di]
        if let p = fields.power { d.power = p }
        if let b = fields.brightness { d.brightness = b }
        if let c = fields.connected { d.connected = c }
        if let n = fields.name { d.name = n }
        if d != residences[ri].devices[di] {
            residences[ri].devices[di] = d
            Self.recomputeRooms(&residences[ri])
            notify()
        }
    }

    /// A room is "on" when any of its devices is — what the server's `power` reflects, and
    /// what the room's dot shows. Kept local so it follows every device change at once.
    private static func recomputeRooms(_ r: inout Residence) {
        for i in r.rooms.indices {
            r.rooms[i].power = r.devices(in: r.rooms[i]).contains(where: \.isOn)
        }
    }

    // MARK: Writing

    func setPower(_ id: String, on: Bool) {
        guard let (ri, di) = locate(id) else { return }
        let before = residences[ri].devices[di]
        residences[ri].devices[di].power = on
        Self.recomputeRooms(&residences[ri])
        notify()
        send(id: id, before: before, writes: [.init(power: on)])
    }

    /// The room switch, My Leviton's way: `turnOn`/`turnOff` moves *every* device in the room.
    /// The per-device `includeInRoomOnOff` flag plays no part — the server ignores it (checked
    /// against this account on 2026-08-22: a `turnOn` on a room where all three devices are
    /// opted out switched all three on), and My Leviton's own web app never reads it either.
    /// A refresh follows shortly to pick up whatever the server actually did (levels, stragglers).
    func toggleRoom(_ roomId: String) {
        guard let s = session, let ri = residences.firstIndex(where: { $0.rooms.contains { $0.id == roomId } }),
              let room = residences[ri].rooms.first(where: { $0.id == roomId }) else { return }
        let on = !room.power
        let before = residences[ri]
        for di in residences[ri].devices.indices where residences[ri].devices[di].roomId == roomId
            && residences[ri].devices[di].connected {
            residences[ri].devices[di].power = on
        }
        Self.recomputeRooms(&residences[ri])
        notify()
        Task {
            do {
                try await client.setRoomPower(s, roomId: roomId, on: on)
                lastError = nil
                notify()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refresh()
            } catch {
                if let i = residences.firstIndex(where: { $0.id == before.id }) { residences[i] = before }
                lastError = "\(room.name): \(Self.describe(error))"
                notify()
                if case LevitonClient.Error.unauthorized = error { refresh() }
            }
        }
    }

    func toggle(_ id: String) {
        guard let (ri, di) = locate(id) else { return }
        setPower(id, on: !residences[ri].devices[di].power)
    }

    /// Set a dimmer's level. The device is also switched on: My Leviton keeps brightness and
    /// power separate, and a level change on a switched-off dimmer is otherwise invisible.
    /// Level 0 is the slider's "off" and just switches the device off, leaving its remembered
    /// brightness alone.
    ///
    /// A dimmer that is off *and* has a preset (`comesOnAtPreset`) needs two writes, in this
    /// order. `{power:ON, brightness:n}` in one PUT does not work for it: the cloud takes the n
    /// and even echoes it back, but the device comes up at its own `presetLevel` and reports
    /// *that* a beat later, overwriting n. Brightness-first-then-On fails the same way, for the
    /// same reason — the device's report is what settles it. So: switch it on, let it report,
    /// then set the level, and the light is visibly at its preset for that moment. A "last
    /// level" dimmer (`presetLevel` 0) has nothing of its own to go to and takes the single
    /// combined write, which lands immediately with no such flash. Both measured 2026-08-22 —
    /// a D36HD at preset 30 and a D26HD at preset 0; see CLAUDE.md.
    func setBrightness(_ id: String, _ level: Int) {
        guard let (ri, di) = locate(id) else { return }
        if level <= 0 { setPower(id, on: false); return }
        let before = residences[ri].devices[di]
        let clamped = min(max(level, before.minLevel), before.maxLevel)
        residences[ri].devices[di].brightness = clamped
        residences[ri].devices[di].power = true
        Self.recomputeRooms(&residences[ri])
        notify()
        let writes: [LevitonClient.DeviceFields]
        if before.power {
            writes = [.init(brightness: clamped)]                                  // already on: just the level
        } else if before.comesOnAtPreset {
            writes = [.init(power: true), .init(brightness: clamped)]              // On, let it settle, then the level
        } else {
            writes = [.init(power: true, brightness: clamped)]                     // "last level": one write does it
        }
        send(id: id, before: before, writes: writes)
    }

    /// The room's (or, with nil, the home's) slider: every reachable dimmer to one level —
    /// each floored at its own minLevel; 0 switches them all off. Our feature, not My Leviton's.
    func setBrightness(ofAll roomId: String?, _ level: Int) {
        for d in devices where d.canSetLevel && d.connected && (roomId == nil || d.roomId == roomId) {
            setBrightness(d.id, level)
        }
    }

    func setAll(on: Bool, in residenceId: String? = nil) {
        for d in devices where d.connected && d.power != on && (residenceId == nil || d.residenceId == residenceId) {
            setPower(d.id, on: on)
        }
    }

    /// How long a dimmer takes to come up and report its own level after an On. The report
    /// landed 1–1.5 s after the PUT on a D36HD (2026-08-22); 2 s leaves margin without making
    /// the correction feel detached from the drag.
    nonisolated static let onSettle = Duration.seconds(2)

    /// One or more PUTs, in order, as one optimistic write: any failure rolls the row back to
    /// `before`, and only the **last** echo is trusted — an earlier one can be a lie (see
    /// `setBrightness`). Realtime pushes for this device are ignored while it is in flight, so
    /// the row doesn't bounce through the level the device passes on its way to the one asked
    /// for.
    private func send(id: String, before: Device, writes: [LevitonClient.DeviceFields]) {
        guard let s = session, let first = writes.first else { return }
        inFlight[id, default: 0] += 1
        Task {
            defer { if let n = inFlight[id], n > 1 { inFlight[id] = n - 1 } else { inFlight[id] = nil } }
            do {
                var updated = try await client.update(s, deviceId: id, fields: first)
                for f in writes.dropFirst() {
                    try await Task.sleep(for: Self.onSettle)
                    updated = try await client.update(s, deviceId: id, fields: f)
                }
                if let (ri, di) = locate(id) {
                    // Trust the server's echo over our optimistic guess.
                    var d = residences[ri].devices[di]
                    if let p = updated.power { d.power = p }
                    if let b = updated.brightness { d.brightness = b }
                    if let c = updated.connected { d.connected = c }
                    residences[ri].devices[di] = d
                    Self.recomputeRooms(&residences[ri])
                }
                lastError = nil
                notify()
            } catch {
                if let (ri, di) = locate(id) { residences[ri].devices[di] = before; Self.recomputeRooms(&residences[ri]) }
                lastError = "\(before.name): \(Self.describe(error))"
                notify()
                if case LevitonClient.Error.unauthorized = error { refresh() }   // triggers re-login
            }
        }
    }

    // MARK: Helpers

    private func locate(_ id: String) -> (Int, Int)? {
        for (ri, r) in residences.enumerated() {
            if let di = r.devices.firstIndex(where: { $0.id == id }) { return (ri, di) }
        }
        return nil
    }

    private func notify() { onChange?() }

    nonisolated static func describe(_ error: Swift.Error) -> String {
        if let e = error as? LevitonClient.Error { return e.description }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "offline"
            case NSURLErrorTimedOut: return "my.leviton.com timed out"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "cannot reach my.leviton.com"
            default: break
            }
        }
        return ns.localizedDescription
    }
}
