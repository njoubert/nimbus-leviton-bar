// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One Decora Smart Wi-Fi device as the menu sees it — the subset of an `IotSwitch`
/// record that matters for showing and controlling it.
struct Device: Identifiable, Equatable {
    enum Kind: String { case dimmer, `switch`, fan, plug, other }

    let id: String           // IotSwitch id (numeric on the wire; kept as a string)
    var residenceId: String
    var roomId: String?      // residentialRoomId; nil when My Leviton has it in no room
    var name: String
    var model: String        // e.g. DW6HD, D26HD, DW15S, DW4SF, DW15P
    /// Firmware, as the record reports it: "1.0.15", or "1.7.1; CP 1.13" where the radio
    /// co-processor carries its own. Shown in the menu while ⌥ is held; "" if it is missing.
    var version: String
    var serial: String
    var power: Bool
    /// 0–100; only meaningful when `canSetLevel` (dimmers and fan controllers).
    var brightness: Int
    var minLevel: Int
    var maxLevel: Int
    var canSetLevel: Bool
    /// False when the switch has dropped off Wi-Fi: My Leviton still lists it, commands fail.
    var connected: Bool
    /// My Leviton's per-device setting: does the room's On/Off include this device?
    var includeInRoomOnOff: Bool
    /// The level the dimmer comes up at, set in the My Leviton app: 0 means "last level".
    /// nil when the record didn't carry it. See `comesOnAtPreset`.
    var presetLevel: Int?

    /// For display only; `canSetLevel` is what decides whether a slider is shown.
    var kind: Kind {
        if model.hasSuffix("SF") { return .fan }              // DW4SF, D24SF: 4-speed fan controller
        if canSetLevel { return .dimmer }                     // DW6HD, D26HD, DW3HL, D23LP (plug-in dimmer)…
        if model.hasSuffix("P") || model.hasSuffix("A") || model.hasSuffix("R") || model.hasSuffix("O") { return .plug }   // DW15P, D215P, DW15A, DW15R, D215O
        if model.hasSuffix("S") { return .switch }            // DW15S, D215S
        return .other
    }

    var isOn: Bool { connected && power }
    /// True when switching this dimmer on makes it go to a level of its own, overriding a
    /// brightness sent with the On — so the level has to be written afterwards, in a second
    /// write (`DeviceStore.setBrightness`). "Last level" dimmers take both in one write, and
    /// an unknown preset is treated as one, because guessing wrong the other way lands the
    /// light on the wrong level.
    var comesOnAtPreset: Bool { (presetLevel ?? 1) != 0 }
    var levelClamped: Int { min(max(brightness, minLevel), maxLevel) }
}

/// A My Leviton room. Its devices are the ones whose `roomId` matches; `power` is the
/// server's view (any device on) and is recomputed locally from the devices.
struct Room: Identifiable, Equatable {
    let id: String
    var name: String
    var power: Bool
}

struct Residence: Identifiable, Equatable {
    let id: String
    var name: String
    /// In the order the API returns them, which is by id.
    var rooms: [Room]
    var devices: [Device]
    /// Room ids in the order the user dragged them into in the My Leviton app, from
    /// `LevitonClient.roomOrders`. Empty when they never have — then id order stands, which
    /// is what My Leviton itself falls back to.
    var roomOrder: [String] = []
    /// The residence's scenes, in the API's order. Empty when the account has none, or when
    /// the scene fetch failed — they are a nicety, never a reason to hide the devices.
    var activities: [Activity] = []

    func devices(in room: Room) -> [Device] { devices.filter { $0.roomId == room.id } }

    /// The menu's order: the user's own room order (`roomOrder`), minus the rooms with no
    /// device, and with rooms whose every device is unreachable moved to the end (stable).
    /// A room the order doesn't mention — added since the last drag — sorts after the ones it
    /// does, in id order, which is what the My Leviton app does with it.
    var displayRooms: [Room] {
        let live = rooms.filter { !devices(in: $0).isEmpty }
        var rank: [String: Int] = [:]
        for (i, id) in roomOrder.enumerated() where rank[id] == nil { rank[id] = i }
        let ordered = live.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
            return ra == rb ? a.offset < b.offset : ra < rb          // ties keep the API's id order
        }.map(\.element)
        return ordered.filter { devices(in: $0).contains(where: \.connected) } + ordered.filter { !devices(in: $0).contains(where: \.connected) }
    }

    /// The menu's order within a room: reachable devices first, unreachable ones last (each
    /// group alphabetical, which is how `devices` is already sorted).
    func displayDevices(in room: Room) -> [Device] {
        let all = devices(in: room)
        return all.filter(\.connected) + all.filter { !$0.connected }
    }
    /// Devices My Leviton has in no room (or a room it didn't list).
    var unassigned: [Device] {
        let ids = Set(rooms.map(\.id))
        return devices.filter { $0.roomId.map { !ids.contains($0) } ?? true }
    }
}

/// One entry of a scene: "set IotSwitch 431325 to ON at 40 %". My Leviton stores these as
/// `residentialActions` rows hanging off an activity (or a room scene).
struct SceneAction: Equatable {
    let deviceId: String            // targetModelId, when targetModelName is "IotSwitch"
    let fields: LevitonClient.DeviceFields
}

/// A My Leviton **Activity**: a named, whole-residence scene. Running one is fire-and-forget
/// — an activity has no state of its own, so there is nothing to show back but its name.
///
/// (My Leviton also has per-room `ResidentialScene`s, same `residentialActions` shape and a
/// matching `ResidentialScenes/execute`. This account has none, so they are not modelled.)
struct Activity: Identifiable, Equatable {
    let id: String
    var residenceId: String
    var name: String
    /// One of My Leviton's 41 icon names (`goodnight`, `party`, …); free-form in practice —
    /// owners pick an icon unrelated to the name, so it is not worth drawing.
    var icon: String
    /// What the activity does, in the order the server returned it.
    var actions: [SceneAction]
}
