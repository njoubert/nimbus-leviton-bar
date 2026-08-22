// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ServiceManagement

/// "Open at Login" via SMAppService — the app registers itself as a Login Item, which then
/// shows up (and can be toggled) in System Settings › General › Login Items.
///
/// The registration is tied to the bundle that makes the call, so `build.sh install` runs
/// the installed copy with `--enable-login-item`, and `uninstall` runs it with
/// `--disable-login-item` before deleting it (otherwise a dangling entry is left behind).
enum LoginItem {
    /// Set once the app has registered itself (first launch from /Applications, or
    /// `--enable-login-item`) or the user has toggled it — after that, never auto-register again.
    static let registeredDefaultsKey = "loginItemRegistered"

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static var statusDescription: String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval in System Settings › Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
