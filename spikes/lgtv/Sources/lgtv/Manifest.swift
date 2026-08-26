// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The registration manifest every community SSAP client sends, byte for byte.
///
/// It is not ours and it is not really a manifest: it is a fixed blob that originated in LG's
/// own 2014 test application and has been copied from client to client ever since. The
/// `signature` is a fixed RSA blob that no longer verifies anything — BetterDisplay 4.3.6 ships
/// the same signature under a *different* `serial`, and pairs with this television, which is
/// proof the set does not check it. Recovered from that binary on 2026-08-25 rather than typed
/// from memory, precisely because a wrong byte here would look like a protocol failure.
///
/// `WRITE_SETTINGS` is the permission the whole feature rests on; `WRITE_NOTIFICATION_ALERT` is
/// what the luna bridge fallback needs.
enum SSAPManifest {

    /// Which manifest to offer. This set exists because webOS 25 on this G5 answers the
    /// canonical one with `403 Pairing rejected: blacklisted certificate detected` — LG has
    /// revoked the leaked `test-signing-cert` that every community client signs with, and the
    /// refusal arrives *before* the on-screen prompt, so trying alternatives costs nothing and
    /// bothers nobody.
    enum Variant: String, CaseIterable {
        /// The canonical lgtv2 blob, signature and all. Blacklisted on this set.
        case full
        /// The same claims, with the `signatures` array dropped — an unsigned app rather than
        /// one signed by a revoked certificate.
        case unsigned
        /// Unsigned *and* stripped of the `signed` block: permissions and nothing else.
        case minimal
        /// Unsigned, and with the `signed` block's permissions hoisted into the top-level
        /// list. Dropping the signature appears to make the whole `signed` block advisory, and
        /// `WRITE_SETTINGS` lives only in there — which would explain a set that answers reads
        /// and silently ignores writes.
        case hoisted
        /// Unsigned, with our own identity in place of `com.lge.test`.
        case own

        var description: String {
            switch self {
            case .full: return "canonical lgtv2 manifest, signed with test-signing-cert"
            case .unsigned: return "canonical claims, signatures dropped"
            case .minimal: return "permissions only, no signed block"
            case .hoisted: return "unsigned, signed-block permissions hoisted to the top level"
            case .own: return "our own appId, unsigned"
            }
        }
    }

    static func manifest(_ variant: Variant) -> [String: Any] {
        var manifest = full
        switch variant {
        case .full:
            return manifest
        case .unsigned:
            manifest["signatures"] = nil
        case .minimal:
            manifest["signatures"] = nil
            manifest["signed"] = nil
        case .hoisted:
            manifest["signatures"] = nil
            let signed = manifest["signed"] as? [String: Any] ?? [:]
            let inner = signed["permissions"] as? [String] ?? []
            var outer = manifest["permissions"] as? [String] ?? []
            for permission in inner where !outer.contains(permission) { outer.append(permission) }
            manifest["permissions"] = outer
        case .own:
            manifest["signatures"] = nil
            var signed = manifest["signed"] as? [String: Any] ?? [:]
            signed["appId"] = "com.njoubert.nimbuslevitonbar"
            signed["vendorId"] = "com.njoubert"
            signed["localizedAppNames"] = ["": "Nimbus Leviton Bar"]
            signed["localizedVendorNames"] = ["": "Niels Joubert"]
            manifest["signed"] = signed
        }
        return manifest
    }

    static let full: [String: Any] = [
        "manifestVersion": 1,
        "appVersion": "1.1",
        "signed": [
            "created": "20140509",
            "appId": "com.lge.test",
            "vendorId": "com.lge",
            "localizedAppNames": [
                "": "LG Remote App",
                "ko-KR": "리모컨 앱",
                "zxx-XX": "ЛГ Rэmotэ AПП",
            ],
            "localizedVendorNames": ["": "LG Electronics"],
            "permissions": [
                "TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD",
                "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_NOTIFICATIONS", "SEARCH",
                "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT", "CONTROL_POWER",
                "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS", "READ_UPDATE_INFO",
                "UPDATE_FROM_REMOTE_APP", "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME",
            ],
            "serial": "2f930e2d2cfe083771f68124f2d2b2ab",
        ],
        "permissions": [
            "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED",
            "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
            "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK",
            "CONTROL_INPUT_TV", "CONTROL_POWER", "READ_APP_STATUS", "READ_CURRENT_CHANNEL",
            "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE", "READ_RUNNING_APPS",
            "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE",
            "READ_COUNTRY_INFO", "READ_SETTINGS", "CONTROL_TV_SCREEN", "CONTROL_TV_STANBY",
            "CONTROL_FAVORITE_GROUP", "CONTROL_USER_INFO", "CONTROL_BLUETOOTH",
            "CONTROL_TIMER_INFO", "CONTROL_RECORDING", "READ_RECORDING_STATE",
            "WRITE_RECORDING_LIST", "READ_RECORDING_LIST", "READ_RECORDING_SCHEDULE",
            "WRITE_RECORDING_SCHEDULE", "READ_STORAGE_DEVICE_LIST", "READ_TV_PROGRAM_INFO",
            "CONTROL_BOX_CHANNEL", "READ_TV_ACR_AUTH_TOKEN", "READ_TV_CONTENT_STATE",
            "READ_TV_CURRENT_TIME", "ADD_LAUNCHER_CHANNEL", "SET_CHANNEL_SKIP",
            "CONTROL_CHANNEL_BLOCK", "DELETE_SELECT_CHANNEL", "CONTROL_CHANNEL_GROUP",
            "SCAN_TV_CHANNELS", "CONTROL_TV_POWER", "CONTROL_WOL",
        ],
        "signatures": [[
            "signatureVersion": 1,
            "signature": """
                eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ2\
                5hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2Cz\
                PCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7\
                swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1\
                n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9Nmmyqz\
                J3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw==
                """.replacingOccurrences(of: "\n", with: ""),
        ]],
    ]
}
