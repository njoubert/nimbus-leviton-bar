// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NimbusUpdater

/// This app's side of `NimbusUpdater`: the facts that identify it, in one place, so the menu
/// and the CLI ask about the same thing. Everything else about updating lives in the package.
enum Updates {
    static let repo = "njoubert/nimbus-leviton-bar"
    static let bundleID = "com.njoubert.nimbuslevitonbar"
    /// The Developer ID team the release is signed with; a download signed by anyone else is
    /// refused. Shared with nimbus-net-bar (one Apple ID, one team).
    static let teamID = "93A96TD57U"
    static let appName = "Nimbus Leviton Bar"
    static let executableName = "NimbusLevitonBar"

    static func config(currentVersion: SemanticVersion) -> UpdaterConfig {
        UpdaterConfig(repo: repo, bundleID: bundleID, teamID: teamID, appName: appName,
                      executableName: executableName, currentVersion: currentVersion)
    }

    /// The running bundle's version — nil for the bare binary (no Info.plist), which is why
    /// the CLI falls back to the installed copy's.
    static var runningVersion: SemanticVersion? { SemanticVersion.ofBundle() }

    /// What `/Applications/<appName>.app` says it is, for the CLI running outside a bundle.
    static var installedVersion: SemanticVersion? {
        let plist = URL(fileURLWithPath: "/Applications/\(appName).app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let short = info["CFBundleShortVersionString"] as? String else { return nil }
        return SemanticVersion(short)
    }
}
