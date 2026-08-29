// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import NimbusLevitonBar

/// Wire-shaped sample data, matching what the live API was measured to return (CLAUDE.md,
/// Aug 2026): integer ids, "ON"/"OFF" powers, room-order preferences as JSON *strings*, both
/// `residentialAction` shapes.
enum Fixtures {

    static func session(token: String = "tok-test-000", userId: String = "7",
                        created: Date = Date(), ttl: TimeInterval? = 5_184_000) -> Keychain.Session {
        Keychain.Session(token: token, userId: userId, created: created, ttl: ttl)
    }

    static func login(_ email: String = "test@example.com", _ password: String = "pw") -> Keychain.Login {
        Keychain.Login(email: email, password: password)
    }

    /// A full IotSwitch record — the fields the parser reads, wire-typed. `extra` overlays
    /// anything else (or overrides, e.g. `"power": 1` to test a type drift).
    static func iotSwitch(id: Int, name: String, power: String = "OFF", brightness: Int = 0,
                          canSetLevel: Bool = false, minLevel: Int = 0, maxLevel: Int = 100,
                          model: String = "DW15S", version: String = "1.0.15", serial: String = "SER",
                          connected: Bool = true, roomId: Int? = nil, residenceId: Int = 100,
                          presetLevel: Int? = nil, includeInRoomOnOff: Bool = true,
                          extra: [String: Any] = [:]) -> [String: Any] {
        var j: [String: Any] = ["id": id, "name": name, "power": power, "brightness": brightness,
                                "canSetLevel": canSetLevel, "minLevel": minLevel, "maxLevel": maxLevel,
                                "model": model, "version": version, "serial": serial,
                                "connected": connected, "residenceId": residenceId,
                                "includeInRoomOnOff": includeInRoomOnOff]
        if let roomId { j["residentialRoomId"] = roomId }
        if let presetLevel { j["presetLevel"] = presetLevel }
        for (k, v) in extra { j[k] = v }
        return j
    }

    static func room(id: Int, name: String, power: String = "OFF") -> [String: Any] {
        ["id": id, "name": name, "power": power, "position": NSNull(), "allConnected": true]
    }

    /// A `residentialPermissions` row for an owned account…
    static func permissionAccount(_ accountId: Int) -> [String: Any] { ["residentialAccountId": accountId] }
    /// …or a shared residence.
    static func permissionResidence(_ residenceId: Int) -> [String: Any] { ["residenceId": residenceId] }

    static func residence(id: Int, name: String = "Home") -> [String: Any] { ["id": id, "name": name] }

    /// The person's room-order preference row: `value` is a JSON **string**, as on the wire.
    static func roomOrderPreference(residenceId: Int, roomIds: [Int],
                                    appId: String = "DECORA_SMART") -> [String: Any] {
        let value = "[" + roomIds.map(String.init).joined(separator: ",") + "]"
        return ["appId": appId, "key": "sorting$residence:\(residenceId)$rooms", "value": value]
    }

    static func activity(id: Int, residenceId: Int = 100, name: String, icon: String = "goodnight",
                         isButtonActivity: Bool = false, actions: [[String: Any]] = []) -> [String: Any] {
        ["id": id, "residenceId": residenceId, "name": name, "customIcon": icon,
         "isButtonActivity": isButtonActivity, "residentialActions": actions]
    }

    /// The common `residentialAction` shape: `targetProperty: "properties"`, `targetValue` a
    /// JSON *string* needing a second parse.
    static func actionProperties(deviceId: Int, power: String? = nil, brightness: Int? = nil) -> [String: Any] {
        var inner: [String: Any] = [:]
        if let power { inner["power"] = power }
        if let brightness { inner["brightness"] = brightness }
        let blob = String(data: try! JSONSerialization.data(withJSONObject: inner), encoding: .utf8)!
        return ["targetModelName": "IotSwitch", "targetModelId": deviceId,
                "targetProperty": "properties", "targetValue": blob]
    }

    /// The bare shape ("Good Morning" on the live account): one property, value unwrapped.
    static func actionBare(deviceId: Int, property: String, value: Any) -> [String: Any] {
        ["targetModelName": "IotSwitch", "targetModelId": deviceId,
         "targetProperty": property, "targetValue": value]
    }

    /// The LoopBack error envelope, as the server sends it.
    static func loopbackError(status: Int, message: String, code: String = "") -> [String: Any] {
        var e: [String: Any] = ["statusCode": status, "message": message]
        if !code.isEmpty { e["code"] = code }
        return ["error": e]
    }

    /// The `Person/login` reply.
    static func loginReply(token: String = "tok-test-000", userId: Int = 7,
                           ttl: Int = 5_184_000, created: String = "2026-08-24T10:00:00.000Z") -> [String: Any] {
        ["id": token, "ttl": ttl, "created": created, "userId": userId]
    }

    /// A ready-made `Device` value for pure-model tests (no JSON involved).
    static func device(id: String, name: String = "Lamp", roomId: String? = nil,
                       residenceId: String = "100", model: String = "D26HD",
                       power: Bool = false, brightness: Int = 0, minLevel: Int = 5, maxLevel: Int = 100,
                       canSetLevel: Bool = true, connected: Bool = true,
                       presetLevel: Int? = nil) -> Device {
        Device(id: id, residenceId: residenceId, roomId: roomId, name: name, model: model,
               version: "1.0.15", serial: "SER", power: power, brightness: brightness,
               minLevel: minLevel, maxLevel: maxLevel, canSetLevel: canSetLevel,
               connected: connected, includeInRoomOnOff: true, presetLevel: presetLevel)
    }
}
