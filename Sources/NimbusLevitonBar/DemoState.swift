// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `--demo`: the real app on staged sample data — the menu bar item, the menu, the rows, the
/// tooltips, all live and clickable — with no account, no network and no Keychain. Clicks
/// flip rows optimistically and go nowhere (there is no session). The staging includes the
/// drift warning, since eyeballing states the real service rarely shows is the whole point;
/// `--dump-menu` remains the two-appearance PNG check, this is the hands-on one.
@MainActor
enum DemoState {
    /// The staged store, hermetically sealed: an inert Keychain (a Sign Out click in the demo
    /// menu must not delete the real items), and a client whose every request fails on the
    /// spot (a sign-in typed into the demo's own dialog must not reach my.leviton.com).
    static func store() -> DeviceStore {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [BlackholeURLProtocol.self]
        let store = DeviceStore(client: LevitonClient(configuration: c), credentials: InertCredentials())
        stage(store)
        return store
    }

    private struct InertCredentials: CredentialStore {
        func loadLogin() -> Keychain.Login? { nil }
        func saveLogin(_ login: Keychain.Login) throws {}
        func deleteLogin() {}
        func loadSession() -> Keychain.Session? { nil }
        func saveSession(_ s: Keychain.Session) throws {}
        func deleteSession() {}
        var readFailureHint: String { "" }
    }

    private static func stage(_ store: DeviceStore) {
        func device(_ id: Int, _ name: String, room: String?, model: String, version: String,
                    on: Bool = false, level: Int = 0, dim: Bool = false,
                    connected: Bool = true, preset: Int? = nil) -> Device {
            Device(id: String(id), residenceId: "demo", roomId: room, name: name, model: model,
                   version: version, serial: "1000_0000_0000", power: on, brightness: level,
                   minLevel: 10, maxLevel: 100, canSetLevel: dim, connected: connected,
                   includeInRoomOnOff: true, presetLevel: preset)
        }
        // The shapes worth checking by hand: a lit dimmer, one off at a preset, a plain
        // switch, an offline plug, a name long enough to truncate.
        let devices = [
            device(1, "Desk", room: "office", model: "DW3HL", version: "1.7.1; CP 1.13", on: true, level: 100, dim: true),
            device(2, "Nightstand", room: "office", model: "D36HD", version: "1.0.15", level: 40, dim: true, preset: 30),
            device(3, "Bookcase", room: "office", model: "DW15P", version: "1.6.4"),
            device(4, "Entrance Track Lights", room: "hall", model: "D26HD", version: "1.7.3", on: true, level: 73, dim: true),
            device(5, "760 Fridge", room: "hall", model: "D215P", version: "1.6.4", connected: false),
            device(6, "A very long lamp name that truncates", room: "hall", model: "D26HD", version: "1.7.3", dim: true),
        ]
        let rooms = [Room(id: "office", name: "Niels' Room", power: true),
                     Room(id: "hall", name: "Entrance Hall", power: true)]
        let activities = [
            Activity(id: "a1", residenceId: "demo", name: "Evening Glow", icon: "goodnight",
                     actions: [SceneAction(deviceId: "1", fields: .init(power: true, brightness: 40))]),
            Activity(id: "a2", residenceId: "demo", name: "All Off", icon: "all-off",
                     actions: devices.map { SceneAction(deviceId: $0.id, fields: .init(power: false)) }),
        ]
        store.seedForDemo(
            [Residence(id: "demo", name: "Demo Home", rooms: rooms, devices: devices,
                       roomOrder: ["office", "hall"], activities: activities)],
            anomaly: "the feed missed 3 changes in 30 min — my.leviton.com may have drifted")
        Diagnostics.shared.record(.app, "demo mode: staged sample data, nothing here talks to my.leviton.com")
    }
}

/// Fails every request instantly, so even a deliberately-triggered network path in the demo
/// (a sign-in, a forced refresh) dies at the URL loading system rather than leaving the Mac.
final class BlackholeURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
