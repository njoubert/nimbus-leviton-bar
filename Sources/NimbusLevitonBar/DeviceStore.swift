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

    // MARK: The drift warning

    /// Signals that my.leviton.com is not behaving like the spec this app is written against
    /// — not routine failures. One-off drops, timeouts and 500s are deliberately NOT here: a
    /// warning that cries at those trains its reader to ignore it. What qualifies:
    /// `feedMisses` (the poll caught the feed lying `feedMissThreshold` times inside
    /// `anomalyWindow` — one trip is a race the design accepts, a change landing mid-fetch),
    /// `malformed` (the parser refused a reply's shape — the clearest drift signal there is),
    /// and `feedAuth` (the feed's session rejected, so it is waiting out the hour).
    ///
    /// The Refresh row shows a small ⚠︎ beside "live" while `apiAnomaly` is non-nil, with the
    /// reason in the tooltip pointing at ⌥ Internals and `--probe`. Entries age out lazily
    /// after `anomalyShownFor` (no timer; the row's own 1 s tick re-reads), and `feedAuth`
    /// clears the moment the feed authenticates again.
    enum AnomalyKind { case feedMisses, malformed, feedAuth }
    private var anomalies: [(at: Date, kind: AnomalyKind, what: String)] = []
    /// `checkFeedDelivered` trips, for the threshold below.
    private var feedMisses: [Date] = []
    static let anomalyWindow: TimeInterval = 1800
    static let anomalyShownFor: TimeInterval = 3600
    static let feedMissThreshold = 3

    /// The newest still-current drift reason, or nil when the row should stay plain.
    var apiAnomaly: String? {
        let cutoff = Date().addingTimeInterval(-Self.anomalyShownFor)
        return anomalies.last(where: { $0.at > cutoff })?.what
    }

    /// Internal, and dated, so the tests can backdate entries to prove the aging.
    func noteAnomaly(_ kind: AnomalyKind, _ what: String, at: Date = Date()) {
        anomalies.append((at, kind, what))
        if anomalies.count > 20 { anomalies.removeFirst(anomalies.count - 20) }
        Diagnostics.shared.record(.app, "drift: \(what)", isError: true)
        notify()
    }

    private func noteFeedMiss() {
        let cutoff = Date().addingTimeInterval(-Self.anomalyWindow)
        feedMisses = feedMisses.filter { $0 > cutoff } + [Date()]
        guard feedMisses.count >= Self.feedMissThreshold else { return }
        noteAnomaly(.feedMisses, "the feed missed \(feedMisses.count) changes in "
            + "\(Int(Self.anomalyWindow / 60)) min — my.leviton.com may have drifted")
    }

    /// A reply the parser refused is drift by definition; everything else stays `lastError`'s
    /// business.
    private func noteIfMalformed(_ error: Swift.Error) {
        if case LevitonClient.Error.malformed(let what) = error {
            noteAnomaly(.malformed, "my.leviton.com sent a reply the app could not read (\(what))")
        }
    }

    /// The one path allowed to write `isLive`: going live clears any feed-auth anomaly — the
    /// rejection resolved itself (usually a re-login replaced the token).
    private func setLive(_ live: Bool) {
        isLive = live
        if live { anomalies.removeAll { $0.kind == .feedAuth } }
    }

    private let client: LevitonClient
    private let credentials: CredentialStore
    /// Builds the realtime feed when a refresh succeeds. Injectable so the tests can point
    /// it at a local server or switch it off (nil = poll only); the default is the real one.
    var realtimeFactory: (Keychain.Session, [String]) -> LevitonRealtime? =
        { LevitonRealtime(session: $0, deviceIds: $1) }
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
    /// Latched by `stop()`. The delayed refresh a room toggle or a scene run schedules
    /// (1.5 s after its POST), or a refresh already in flight, used to land after `stop()`
    /// and reopen the websocket via `startRealtime()` — with the poll left dead, so the
    /// outgoing copy of the app held a socket to my.leviton.com while its replacement
    /// started. Cleared only by `start()` and `signIn`: someone deliberately using this
    /// copy again.
    private var stopped = false
    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var realtime: LevitonRealtime?
    private var wakeObserver: NSObjectProtocol?

    /// How often to poll while the menu is closed. Each poll is one small GET per residence.
    static let pollInterval: TimeInterval = 60
    /// Opening the menu refreshes unless the list is at most this old.
    static let openRefreshMinAge: TimeInterval = 3

    var devices: [Device] { residences.flatMap(\.devices) }
    /// Every residence's scenes, in the API's order. Used for the menu's scene section.
    var activities: [Activity] { residences.flatMap(\.activities) }
    var devicesOn: Int { devices.filter(\.isOn).count }
    var devicesReachable: Int { devices.filter(\.connected).count }
    var devicesOffline: Int { devices.count - devicesReachable }
    /// `demoStaged` counts as signed in for *display* only — every network path gates on
    /// `session` directly, which is what keeps `--demo` provably offline.
    var isSignedIn: Bool { session != nil || demoStaged }
    private var demoStaged = false

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

    /// Both parameters exist for the tests; the app takes the defaults (the real client, the
    /// real Keychain).
    init(client: LevitonClient = LevitonClient(), credentials: CredentialStore = KeychainCredentialStore()) {
        self.client = client
        self.credentials = credentials
        // Sleep suspends the ping timer, and a wake usually leaves the websocket half-open with
        // no error to notice — and whatever changed while we slept was never pushed. So: kick
        // the feed and refetch. Nothing else in the app watches sleep or the network.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session != nil else { return }
                Diagnostics.shared.record(.app, "the Mac woke: reconnecting the feed and refetching")
                self.realtime?.reconnectNow()
                self.refresh()
            }
        }
    }

    /// Pick up the saved session or password from the Keychain. Returns false when there is
    /// nothing saved and the caller should ask the user to sign in.
    func start() -> Bool {
        stopped = false
        let login = credentials.loadLogin()
        email = login?.email
        let saved = credentials.loadSession()
        if let s = saved, s.isFresh {
            session = s
            Diagnostics.shared.setSession(s)
            Diagnostics.shared.record(.app, "launch: using the saved session")
            state = .loading
            startPolling()
            refresh()
            return true
        }
        if let login {
            Diagnostics.shared.record(.app, saved == nil ? "launch: no saved session, signing in with the saved password"
                                                         : "launch: the saved session is stale, signing in again")
            signIn(login, remember: false)
            return true
        }
        Diagnostics.shared.record(.app, "launch: nothing saved in the Keychain\(credentials.readFailureHint)")
        state = .signedOut
        notify()
        return false
    }

    /// A sign-in that came back "two-factor code required": the UI asks for the code and
    /// calls `signIn` again with it.
    private(set) var awaitingCode: Keychain.Login?

    func signIn(_ login: Keychain.Login, code: String? = nil, remember: Bool = true) {
        stopped = false   // an explicit sign-in un-latches a stopped store
        Diagnostics.shared.record(.app, "signing in as \(login.email)\(code != nil ? " with a two-factor code" : "")")
        state = .signingIn
        email = login.email
        awaitingCode = nil
        if remember { lastRelogin = nil }   // a deliberate sign-in resets the re-login guard
        notify()
        Task {
            do {
                let s = try await client.login(email: login.email, password: login.password, code: code)
                if remember { try credentials.saveLogin(login) }
                try? credentials.saveSession(s)
                session = s
                Diagnostics.shared.setSession(s)
                Diagnostics.shared.record(.app, "signed in: session \(Diagnostics.fingerprint(s.token))"
                    + (s.expiry.map { ", good until \(LevitonClient.iso.string(from: $0))" } ?? ""))
                lastError = nil
                state = .loading
                notify()
                startPolling()
                refresh()
            } catch {
                session = nil
                Diagnostics.shared.setSession(nil)
                Diagnostics.shared.record(.app, "sign-in failed: \(Self.describe(error))", isError: true)
                if case LevitonClient.Error.twoFactorRequired = error { awaitingCode = login }
                state = .error(Self.describe(error))
                notify()
            }
        }
    }

    /// Forget the session and the password. The server side is told too (best effort).
    func signOut() {
        Diagnostics.shared.record(.app, "signing out: forgetting the session and the password")
        Diagnostics.shared.setSession(nil)
        if let s = session { Task { await client.logout(s) } }
        stopPolling()
        session = nil
        demoStaged = false
        residences = []
        anomalies = []
        feedMisses = []
        credentials.deleteSession()
        credentials.deleteLogin()
        state = .signedOut
        notify()
    }

    // MARK: Reading

    /// Reload everything (residences and devices). Coalesces: a refresh already in flight is
    /// left to finish rather than doubled up.
    func refresh() {
        guard !stopped, let s = session, refreshTask == nil else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            do {
                let rs = try await client.residences(s)
                // The user's room order, one request for every residence. A nicety, so a
                // failure here is not a failed refresh: id order stands, as it does in the
                // My Leviton app when nobody has ever dragged a room.
                let orders = (try? await client.roomOrders(s)) ?? [:]
                var out: [Residence] = []
                var skipped: [String] = []
                for r in rs {
                    do {
                        async let rooms = client.rooms(s, residenceId: r.id)
                        async let ds = client.devices(s, residenceId: r.id)
                        async let acts = self.activitiesOrNone(s, residenceId: r.id)
                        let sorted = try await ds.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        var res = Residence(id: r.id, name: r.name, rooms: try await rooms, devices: sorted,
                                            roomOrder: orders[r.id] ?? [], activities: await acts)
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
                Diagnostics.shared.record(.app, "fetched \(out.map(\.devices.count).reduce(0, +)) devices in "
                    + "\(out.count) residence\(out.count == 1 ? "" : "s")"
                    + (skipped.isEmpty ? "" : ", no access to \(skipped.joined(separator: ", "))"))
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
                Diagnostics.shared.record(.app, "fetch failed: \(lastError!)", isError: true)
                noteIfMalformed(error)
                state = residences.isEmpty ? .error(lastError!) : .ready
                notify()
            }
        }
    }

    /// Scenes must never cost us the device list: if the fetch fails, the section is simply
    /// absent this round. A token that is really dead fails the device fetch too, which is
    /// what raises the 401.
    private nonisolated func activitiesOrNone(_ s: Keychain.Session, residenceId: String) async -> [Activity] {
        (try? await client.activities(s, residenceId: residenceId)) ?? []
    }

    /// The menu's Retry: sign in again if there is no session (a failed sign-in leaves none),
    /// otherwise fetch again.
    func retry() {
        if session == nil, let login = credentials.loadLogin() { signIn(login, remember: false) }
        else { refresh() }
    }

    /// A token was rejected. Replay the saved password once per cooldown; otherwise give up
    /// on this session and say so — the next poll tries again later.
    private func handleUnauthorized() {
        // Mid-shutdown a 401 must change nothing: the incoming copy is about to load the
        // saved session and decide for itself, and this copy must not delete it or spend the
        // one-per-cooldown login replay on its way out.
        guard !stopped else { return }
        credentials.deleteSession()
        session = nil
        Diagnostics.shared.setSession(nil)
        stopPolling()
        let recent = lastRelogin.map { Date().timeIntervalSince($0) < Self.reloginCooldown } ?? false
        if !recent, let login = credentials.loadLogin() {
            Diagnostics.shared.record(.app, "My Leviton rejected the session — replaying the saved password once", isError: true)
            lastRelogin = Date()
            signIn(login, remember: false)
        } else {
            Diagnostics.shared.record(.app, recent
                ? "My Leviton rejected a session that is minutes old — not signing in again for \(Int(Self.reloginCooldown / 60)) min"
                : "session rejected and no password saved", isError: true)
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

    /// The Internals panel's three buttons. They are the same paths the menu and the timers
    /// use — nothing here is a private back door, and none of them touches a device.
    func reconnectFeed() {
        Diagnostics.shared.record(.app, "Internals: reconnect the feed")
        if let rt = realtime { rt.reconnectNow() } else { startRealtime() }
    }

    /// Drop the token and replay the saved password, once, on demand. The cooldown that
    /// guards the automatic path is reset with it: this is a person asking, not a loop.
    func forceRelogin() {
        Diagnostics.shared.record(.app, "Internals: forcing a new sign-in")
        guard let login = credentials.loadLogin() else {
            lastError = "no password saved — sign in from the menu"
            notify()
            return
        }
        if let s = session { Task { await client.logout(s) } }
        credentials.deleteSession()
        session = nil
        Diagnostics.shared.setSession(nil)
        stopPolling()
        lastRelogin = nil
        signIn(login, remember: false)
    }

    /// For the panel's header.
    var writesInFlight: Int { inFlight.values.reduce(0, +) }
    var pollActive: Bool { pollTimer != nil }

    func refreshIfStale() {
        if let t = lastRefresh, Date().timeIntervalSince(t) < Self.openRefreshMinAge { return }
        refresh()
    }

    /// Put the store to sleep: no poll, no socket — and none later either. Called before an
    /// update swaps the app out from under us, so the outgoing copy is not still talking while
    /// the new one starts. Sticky on purpose (see `stopped`); a plain `stopPolling()` here
    /// left the delayed room/scene refresh free to reopen the socket.
    func stop() {
        stopped = true
        stopPolling()
    }

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
        setLive(false)   // the feed's own `false` arrives too late, and `realtime` is gone
    }

    private func startRealtime() {
        // The `stopped` check closes the in-flight window: a refresh that was already running
        // when `stop()` landed still finishes, and its tail must not build a socket.
        guard !stopped, let s = session, let rt = realtimeFactory(s, devices.map(\.id)) else { return }
        rt.onUpdate = { [weak self] id, fields in   // called on the main queue
            MainActor.assumeIsolated { self?.apply(id: id, fields: fields) }
        }
        rt.onLive = { [weak self, weak rt] live in   // also the main queue
            MainActor.assumeIsolated {
                // A feed we have already replaced must not report on the current one: its
                // final `false` can land after the new one is up.
                guard let self, let rt, self.realtime === rt, self.isLive != live else { return }
                self.setLive(live)
                self.notify()
            }
        }
        rt.onAuthBackoff = { [weak self, weak rt] in   // also the main queue
            MainActor.assumeIsolated {
                guard let self, let rt, self.realtime === rt else { return }
                self.noteAnomaly(.feedAuth, "my.leviton.com rejected the feed's session — "
                    + "the feed is paused for an hour (the poll carries on)")
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
                Diagnostics.shared.record(.app, "the feed missed a change: the fetch found \(d.name) at "
                    + "\(d.power ? "on" : "off") \(d.brightness)% (we held \(old.power ? "on" : "off") "
                    + "\(old.brightness)%) — dropping \"live\" and reconnecting", isError: true)
                setLive(false)
                noteFeedMiss()
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
        Diagnostics.shared.record(.app, "\(room.name): room \(on ? "On" : "Off") (My Leviton's own, every device in the room)")
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
                noteIfMalformed(error)
                notify()
                if case LevitonClient.Error.unauthorized = error { refresh() }
            }
        }
    }

    /// Run a scene: `ResidentialActivities/execute`, one POST for the whole thing. The reply
    /// carries no device state, so the rows are painted from the scene's own actions — we know
    /// exactly what it asked for. Each action is applied as stored (a power-only action leaves
    /// the level alone), which is what the server does with it.
    ///
    /// Realtime confirms within a second or two and overwrites the guess; the delayed refresh
    /// is the backstop for a dropped socket. Offline devices are painted too — My Leviton
    /// changes their cloud record regardless, and their row shows "offline" either way.
    func runActivity(_ id: String) {
        guard let s = session,
              let ri = residences.firstIndex(where: { $0.activities.contains { $0.id == id } }),
              let activity = residences[ri].activities.first(where: { $0.id == id }) else { return }
        let before = residences[ri]
        for action in activity.actions {
            guard let di = residences[ri].devices.firstIndex(where: { $0.id == action.deviceId }) else { continue }
            if let p = action.fields.power { residences[ri].devices[di].power = p }
            if let b = action.fields.brightness {
                let d = residences[ri].devices[di]
                residences[ri].devices[di].brightness = min(max(b, d.minLevel), d.maxLevel)
            }
        }
        Self.recomputeRooms(&residences[ri])
        notify()
        Diagnostics.shared.record(.app, "\(activity.name): running the scene (\(activity.actions.count) action\(activity.actions.count == 1 ? "" : "s"))")
        Task {
            do {
                try await client.executeActivity(s, id: id)
                lastError = nil
                notify()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refresh()
            } catch {
                if let i = residences.firstIndex(where: { $0.id == before.id }) { residences[i] = before }
                lastError = "\(activity.name): \(Self.describe(error))"
                noteIfMalformed(error)
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
        Diagnostics.shared.record(.app, "\(before.name): " + writes.map(\.description)
            .joined(separator: ", then (after \(Self.onSettle)) ")
            + (writes.count > 1 ? "  [comes on at preset \(before.presetLevel ?? 0)]" : ""))
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
                Diagnostics.shared.record(.app, "\(before.name): write failed, row snapped back — \(Self.describe(error))", isError: true)
                noteIfMalformed(error)
                notify()
                if case LevitonClient.Error.unauthorized = error { refresh() }   // triggers re-login
            }
        }
    }

    /// `--demo` (see `DemoState`): stage the store with sample data so the real menu can be
    /// eyeballed with no account, no network and no Keychain. There is no session, so a click
    /// flips a row optimistically and `send` quietly does nothing — which is exactly right
    /// for a showroom. Never called outside the demo path and the tests.
    func seedForDemo(_ rs: [Residence], anomaly: String? = nil) {
        demoStaged = true
        residences = rs
        for i in residences.indices { Self.recomputeRooms(&residences[i]) }
        email = "demo@example.com"
        lastRefresh = Date()
        state = .ready
        setLive(true)
        if let anomaly { noteAnomaly(.feedMisses, anomaly) }
        notify()
    }

    // MARK: Test seams

    /// The realtime feed's path into the store, callable directly by the tests — `apply` is
    /// otherwise reachable only through a live socket. Not used by the app.
    func applyRealtimeForTesting(id: String, fields: LevitonClient.DeviceFields) {
        apply(id: id, fields: fields)
    }

    /// `checkFeedDelivered` only runs while the feed reports live, and the tests fake that
    /// rather than stand up a socket. Not used by the app.
    func overrideLiveForTesting(_ live: Bool) {
        setLive(live)
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
