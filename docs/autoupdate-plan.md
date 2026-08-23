# Auto-update: implementation plan

A hand-rolled updater for Nimbus Leviton Bar and Nimbus Net Bar, shipped as one SwiftPM
package both apps depend on. Written 2026-08-22 against leviton-bar 1.1.2 and net-bar 1.3;
every fact below was checked on that day. Read the whole plan before starting — the steps
build on each other and the test plan at the end is the definition of done.

## Decisions (settled — do not reopen)

| Question | Decision |
|---|---|
| Mechanism | Hand-rolled, no Sparkle, no Homebrew. Trust anchor is the apps' existing Developer ID signature, verified with the Security framework against an explicit requirement. |
| Where the code lives | The repo `njoubert/nimbus-updater`, a SwiftPM library package (`NimbusUpdater`), **MIT** (permissive so both GPL apps can depend on it), pulled in via `Package.swift`. Not a submodule, not a copied file. **Built and tagged `v1.0.0` on 2026-08-22 — Part A below is done; start at Part B.** |
| Network policy | Automatic checks **on by default**, with a "Check for Updates Automatically" toggle in the menu. README and CLAUDE.md stop saying "one host" and name the two GitHub hosts. |
| Download policy | Download and verify **before** asking. The menu then offers a one-click "Install Update and Relaunch". |
| Scope | Both apps. The package is app-agnostic; each app contributes ~60 lines of menu glue. |
| Version source | The release **tag** (`v1.2.0`) vs `CFBundleShortVersionString`. `CFBundleVersion` (commit count) plays no part — the releases API does not carry it. |
| Where it installs | Only when the app runs from exactly `/Applications/<App Name>.app`. Anywhere else (debug builds in `dist/debug`, `~/Applications`, an App-Translocation path, the DMG) the menu offers only "Check for Updates…", which opens the release page in the browser. |
| UI on failure | Automatic checks fail silently (NSLog). A manual check reports its outcome in an NSAlert. |
| No "skip this version" | A staged update stays offered until installed or superseded. The off switch is the opt-out. |
| First shippable version | leviton-bar **1.2.0**, net-bar **1.4** — a feature, so a minor bump. Users on 1.1.2 / 1.3 drag-install once more; everything after is automatic. |

## Facts the design rests on

- `/Applications` is `drwxrwxr-x root:admin` (no sticky bit) and the owner is in `admin`, so the
  app can rename and replace its own bundle **without a privileged helper**. Same-volume
  renames are atomic.
- The installed apps' designated requirement (from `codesign -d -r-`):
  `identifier "com.njoubert.nimbuslevitonbar" and anchor apple generic and
  certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and
  certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and
  certificate leaf[subject.OU] = "93A96TD57U"`. Net-bar's is identical with its identifier
  (`com.njoubert.nimbusnetbar`). Team `93A96TD57U` is shared. The Keychain ACLs trust this
  requirement, so an update signed the same way causes **no new keychain prompt**.
- `GET https://api.github.com/repos/<owner>/<repo>/releases/latest` returns the newest
  non-draft, non-prerelease release: `tag_name`, `html_url`, `body` (notes), `assets[]` with
  `name`, `size`, `browser_download_url`. It 404s when there is no such release. Unauthenticated
  calls need a `User-Agent` and are limited to 60/hour/IP — a daily check is nowhere near it.
  Asset downloads 302 to `release-assets.githubusercontent.com`; URLSession follows.
- Releases currently publish **only the DMG**. The updater needs a `.zip` asset
  (`<NAME>-<version>.zip`, made with `ditto -c -k --keepParent` from the *stapled* release app).
  `build.sh` already builds a zip for notarization and deletes it — that one is pre-staple and
  must not be reused. `dist/Nimbus Leviton Bar.app` from the 1.1.2 build is still on disk,
  stapled, and can be zipped and uploaded to the existing v1.1.2 release as the first test asset.
- Neither app sets `LSFileQuarantineEnabled`, so URLSession downloads carry no quarantine xattr;
  the zip's contents don't either. Strip it anyway after verification (belt and braces) so a
  relaunch never trips Gatekeeper's "downloaded from the internet" dialog.
- Both apps are `LSUIElement` accessory apps. Relaunching a new instance of the same bundle id
  while the old one runs needs `createsNewApplicationInstance`.
- Existing trap, still binding: **never rebuild the menu while it is open**. Updater state
  changes go through the same "structural changes wait for the next open" path the store uses.
- `LoginItem.swift` carries the "identical to net-bar's" convention for shared-by-copy files.
  `build.sh` is within ~40 diff lines of net-bar's after name substitution; its changes are
  mirrored by hand, as today.

## Part A — the package: `njoubert/nimbus-updater` — **DONE (v1.0.0)**

Built on 2026-08-22 and tagged. What shipped differs from the sketch below in four ways, all
deliberate:

- **`State.available(Release)`** was added: a newer release that cannot be staged from here —
  no zip asset, or this copy is not the one in `/Applications`. The sketch folded that into
  `.upToDate`, which would have lied to the user.
- **`UpdaterConfig.currentVersion`** is explicit rather than read from `Bundle.main`, so the
  CLI (which has no Info.plist) can use the same code. `SemanticVersion.ofBundle()` is the
  helper the app passes.
- **Licence headers are MIT**, not GPL-3.0-or-later — this repo is the permissive one.
- **`updaterctl`** was added: a probe with `check` (a feed) and `verify` (a real bundle), which
  is what the Part D tests drive. `./build.sh check leviton|net` wires it to the two apps.

Its own CLAUDE.md carries the traps. The rest of this section is kept as the record of what was
asked for.

### As specified

### Layout

```
Package.swift                 swift-tools-version:5.10, platforms: [.macOS("15.0")]
                              products: .library(name: "NimbusUpdater", targets: ["NimbusUpdater"])
                              targets: NimbusUpdater (links Security, AppKit), NimbusUpdaterTests
Sources/NimbusUpdater/
  Updater.swift               the @MainActor state machine: schedule, check, stage, install, relaunch
  Release.swift               GitHub JSON → Release value; asset selection; SemanticVersion
  Verifier.swift              SecStaticCode check against the requirement; Info.plist checks
  Installer.swift             ditto-extract, copy into /Applications, the rename dance, cleanup
Tests/NimbusUpdaterTests/
  VersionTests.swift          "1.3" < "1.3.1" < "1.10" etc.; "v" prefix; garbage → nil
  ReleaseTests.swift          parse a captured releases/latest JSON; asset selection; no-zip → nil
  VerifierTests.swift         requirement string built exactly as above for a given id + team
LICENSE                       GPL-3.0-or-later; every Swift file has the two-line header
README.md                     what it does, the trust model, how an app integrates (the API below)
```

Keep AppKit out of everything except the relaunch call in `Installer`. No menu code in the
package — the apps own their menus.

### Public API

```swift
public struct UpdaterConfig: Sendable {
    public var repo: String            // "njoubert/nimbus-leviton-bar"
    public var bundleID: String        // "com.njoubert.nimbuslevitonbar"
    public var teamID: String          // "93A96TD57U"
    public var appName: String         // "Nimbus Leviton Bar" → installs to /Applications/<appName>.app
    public var assetPrefix: String     // "NimbusLevitonBar-" → asset is <prefix><version>.zip
    public var userAgent: String       // "NimbusLevitonBar/1.1.2"
    public var checkInterval: TimeInterval = 24 * 3600
    public var launchDelay: TimeInterval = 30      // let the app's own startup finish first
}

public struct Release: Sendable, Equatable {
    public let version: SemanticVersion
    public let tag: String
    public let notes: String           // GitHub release body, may be empty
    public let pageURL: URL            // html_url
    public let assetURL: URL
    public let assetSize: Int
}

public struct SemanticVersion: Comparable, Sendable { public init?(_ s: String) ... }
    // Numeric components, missing ones are 0: "1.3" == "1.3.0" < "1.3.1" < "1.10". A leading "v"
    // is stripped. Anything non-numeric → nil.

@MainActor public final class Updater {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate(checked: Date)
        case downloading(Release)
        case ready(Release)            // verified and staged; installAndRelaunch() will work
        case installing
        case failed(String, at: Date)  // last error, human-readable; automatic checks keep going
    }
    public private(set) var state: State
    public var onChange: (() -> Void)?          // main queue; called on every state change
    public var automaticChecks: Bool            // UserDefaults "automaticUpdateChecks", default true
    public let canInstall: Bool                 // Bundle.main.bundlePath == "/Applications/<appName>.app"
    public var latestKnown: Release?            // what the last successful check found (even if ≤ current)
    public init(config: UpdaterConfig)
    public func start()            // cleanupAfterRelaunch(); if automaticChecks: launch-delay check, then the interval timer
    public func checkNow() async -> State       // manual: always hits the network; returns the resulting state
    public func checkIfStale()     // for menuWillOpen: check only if automaticChecks && lastCheck older than checkInterval
    public func installAndRelaunch()            // precondition: state == .ready && canInstall
    public func openReleasePage()               // latestKnown?.pageURL or https://github.com/<repo>/releases
}
```

`UserDefaults` keys, all in the app's own domain: `automaticUpdateChecks` (Bool, absent = true),
`lastUpdateCheck` (Date), `updateFeedURL` (String, **debug override** — when set, the check GETs
this URL instead of the GitHub API; `file://` URLs work, and the asset URL inside the JSON may be
`file://` too. Document it in CLAUDE.md under testing; never ship a build that sets it).

### Behaviour, in order

**Check** (`checkNow` / timer / stale):
1. `GET <api or override>` with `Accept: application/vnd.github+json`, `User-Agent`, 15 s timeout,
   `URLSessionConfiguration.ephemeral` (no cookies, no cache).
2. 404 → `.upToDate` (no release yet). Other non-2xx → `.failed("GitHub: HTTP 403")`.
3. Parse `tag_name` → `SemanticVersion`; pick the asset whose `name == assetPrefix + version + ".zip"`;
   none → treat as no update (`.upToDate`, NSLog "release has no zip asset") — an old-style
   DMG-only release must not be an error.
4. `remote <= current` → `.upToDate`. Downgrade guard is this `<=`: a release built off a branch
   with a lower version is never offered.
5. If already `.ready(r)` with `r.version == remote` → stay. If staged version < remote → discard
   the stage and continue.
6. Write `lastUpdateCheck` regardless of outcome (so a flaky network doesn't retry every minute).

**Stage** (only when `canInstall`; otherwise stop at `latestKnown` and `.upToDate`/`.idle` so the
menu can say "1.2.0 is available" and open the page):
1. Sanity: `assetSize` ≤ 50 MB. `URLSession.downloadTask` to
   `~/Library/Caches/<bundleID>/Updates/<version>/<asset name>`; check the byte count matches.
2. Extract with `/usr/bin/ditto -x -k <zip> <dir>` (`Process`, argument array, never a shell).
   Expect exactly one `<appName>.app` at the top level; anything else → fail and delete the dir.
3. Verify (below). Fail → delete the directory, `.failed("downloaded app failed signature check")`.
   This is the security-relevant failure: it must never leave the download on disk.
4. Strip quarantine: `/usr/bin/xattr -dr com.apple.quarantine <app>`.
5. `.ready(release)`.

**Verify** (`Verifier.verify(appAt:bundleID:teamID:expectedVersion:)`), and it runs **twice** —
on the staged copy, and again on the copy inside `/Applications` right before the swap (the
cache directory is user-writable; `/Applications` is not, for non-admin processes):
1. `SecStaticCodeCreateWithPath`, `SecRequirementCreateWithString` with the requirement string
   built from `bundleID` and `teamID` exactly as in the facts above, then
   `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures | kSecCSStrictValidate |
   kSecCSCheckNestedCode`. `errSecSuccess` or fail.
2. Read the staged `Info.plist`: `CFBundleIdentifier == bundleID`,
   `CFBundleShortVersionString` parses to `expectedVersion`. A zip that doesn't match its tag is
   refused — it's either a packaging mistake or something worse, and either way not installable.
3. Never call `spctl`: Gatekeeper isn't the gate here, the requirement is. (Notarization still
   matters for the DMG path and for Apple's malware scan; it is not what the updater trusts.)

**Install and relaunch** (`installAndRelaunch`), everything in-process, no detached shell:
1. Preconditions: `canInstall`, `state == .ready`, staged app still exists. `.installing`.
2. `ditto <staged app> /Applications/.<NAME>-update.app` — same volume as the target, so the
   renames below are atomic. (`NAME` = executable name, e.g. `NimbusLevitonBar`; the leading dot
   keeps Finder and Spotlight quiet.)
3. **Re-verify** `/Applications/.<NAME>-update.app`. Fail → delete it, `.failed`, old app untouched.
4. Tell the app to stop its work: the app's `onWillRelaunch` hook (see Part B) stops the poll
   timer and websocket / monitors, so two instances don't briefly both hold them.
5. `rename("/Applications/<appName>.app", "/Applications/.<NAME>-old.app")`, then
   `rename(".<NAME>-update.app", "<appName>.app")`. If the second rename fails, rename the old
   one back and `.failed`. Use `FileManager.moveItem` (rename on the same volume).
6. `NSWorkspace.shared.openApplication(at: newURL, configuration:)` with
   `createsNewApplicationInstance = true`, `activates = false`. In the completion (success or
   not — if the launch fails the user still has a working new app at the right path, and
   `launchctl`/Login Items will start it next time) call `NSApp.terminate(nil)`.
7. The running (old) process must not touch `Bundle.main` resources after step 5 — the path now
   points at the new bundle. Terminate promptly.

**Cleanup** (`start()` → `cleanupAfterRelaunch()`, every launch): delete
`/Applications/.<NAME>-old.app` if present (retry once after 5 s if it's busy — the previous
instance may still be exiting; give up quietly and try next launch), delete
`.<NAME>-update.app` if a swap was interrupted, and delete every
`~/Library/Caches/<bundleID>/Updates/<v>` with `v <= current version`.

**Timer**: `Timer` on the main run loop, `checkInterval`, `tolerance = interval / 4`. Plus
`checkIfStale()` from `menuWillOpen` — cheap, and it covers laptops that sleep through the timer.

### Security notes for the package README

- The only trust is the Developer ID requirement. GitHub account compromise, CDN tampering, or a
  MITM past TLS all end at step "Verify": an unsigned or differently-signed app is deleted, never
  launched. The attacker's best outcome is denial of update.
- No privilege escalation, no helper tool, no XPC. If `/Applications` is not writable by the
  user, `canInstall` is computed false (check `FileManager.isWritableFile(atPath: "/Applications")`
  too, not just the path) and the app only points at the release page.
- `Process` is always given an argument array; no string ever reaches a shell.
- Downloads are bounded (size check before and after), staged under the app's own cache, and the
  final copy verified where it will run.

### Tests (`swift test` in the package repo)

- `SemanticVersion`: ordering table including `"1.3" == "1.3.0"`, `"1.9" < "1.10"`, `"v1.2.0"`,
  `""`/`"latest"`/`"1.2.x"` → nil.
- `Release.parse(data:config:)`: a checked-in `Fixtures/latest.json` captured from the real API
  (the 1.1.2 response, with the zip asset added once step B0 has run); picks the right asset;
  returns nil asset for a DMG-only release; tolerates extra fields.
- `Verifier.requirement(bundleID:teamID:)` equals the literal string in the facts.
- `Verifier.verify` against `/System/Applications/Calculator.app` with the Apple requirement →
  fails (wrong team), proving the check is not a no-op. (Signing-positive tests need a Developer
  ID and are part of the manual test plan instead.)

## Part B — integrating into nimbus-leviton-bar

**B0. Publish the first zip asset** so there's something real to test against. The zip/verify
round trip was checked on 2026-08-22 (a `ditto -c -k --keepParent` of the stapled 1.1.2 app,
unpacked with `ditto -x -k`, still passes `updaterctl verify` and `stapler validate`); only the
upload is left:
```
ditto -c -k --keepParent "dist/Nimbus Leviton Bar.app" dist/NimbusLevitonBar-1.1.2.zip
gh release upload v1.1.2 dist/NimbusLevitonBar-1.1.2.zip
```
(`dist/Nimbus Leviton Bar.app` is the stapled 1.1.2; `xcrun stapler validate` it first. If it's
gone, rebuild with `./build.sh app` at `VERSION=1.1.2` on the v1.1.2 tag.)

**B1. `Package.swift`**: add `.package(url: "https://github.com/njoubert/nimbus-updater.git",
from: "1.0.0")` and `.product(name: "NimbusUpdater", package: "nimbus-updater")` to the target.
Commit `Package.resolved`. Pin with `from:` and bump deliberately; never `branch:`.

**B2. `main.swift`**: in `applicationDidFinishLaunching`, after `statusBar` is created and only
when not in `--dump-bar` mode, construct the `Updater` with the leviton config (userAgent from
`StatusBarController.versionString()`), hand it to the controller, set `onWillRelaunch` to
`store.stop()` (add that: invalidate the poll timer, close the websocket), and `start()` it.
The CLI paths (`--print` etc.) never construct it.

**B3. `StatusBarController` menu**, in the block after "Launch at Login":
- `Check for Updates Automatically` — checkmark item bound to `updater.automaticChecks`. Hidden
  when `!canInstall` (there is nothing automatic to do).
- When `state == .ready(r)` and `canInstall`: `Install Update \(r.version) and Relaunch` — a
  plain `NSMenuItem` (it closes the menu, correctly: the app is about to go away). Tooltip: the
  first three lines of `r.notes`, or "Downloaded and verified; installs in a few seconds".
- When `latestKnown > current` and `!canInstall`: `Update \(v) Available…` → `openReleasePage()`.
- Always: `Check for Updates…` → `Task { await updater.checkNow() }` then an `NSAlert` with the
  outcome: "You're up to date (v1.1.2)", "Update 1.2.0 is ready — install it from the menu",
  or the `.failed` message. Disabled while `.checking`/`.downloading`.
- The version line gets a suffix while an update is staged: `v1.1.2 (10) · 1.2.0 ready`.
- `updater.onChange` → the same path as store changes: update in place if the menu is closed,
  otherwise defer to `menuDidClose`. `menuWillOpen` additionally calls `checkIfStale()`.
- The status item tooltip is unchanged (it's about the devices).

**B4. `CLI.swift`**: `--check-update` — constructs the config, runs `checkNow()` with the
install path forced to "can't install" (it's running from `.build/debug`), prints
`current 1.1.2, latest 1.1.2 (up to date)` / `latest 1.2.0: <assetURL> (<size> bytes)` /
the error. Exit 0/1. This is the correctness check for the API path, like `--print` is for
devices. (Staging/verification are exercised by the manual plan, not the CLI — they need the
real installed bundle.)

**B5. `build.sh`**:
- `make_zip <app> <out.zip>`: `rm -f`, `ditto -c -k --keepParent`, `note "packed …"`. Called in
  `dmg` *after* `notarize_app` (stapled) and before `make_dmg`. Output `dist/$NAME-$VERSION.zip`.
- New `release` command: refuse unless the tree is clean and `HEAD` is tagged `v$VERSION`
  (create the tag if `--tag` is passed); run the `dmg` steps; then
  `gh release create "v$VERSION" "$DMG" "$ZIP" --title "$VERSION" --notes-file "${1:?notes file}"`.
  `gh` missing → say so and print the command instead. Shellcheck-clean (`if`, not `&& ||`).
- `status`: also print whether `$INSTALLED` is writable by the user and whether
  `/Applications/.$NAME-old.app` is lying around.
- `uninstall`: also remove `~/Library/Caches/$BUNDLE_ID` and the `.$NAME-old.app` stray.

**B6. README**: replace the one-host sentences. Proposed: "It talks to `my.leviton.com` for
everything about your lights. Once a day — unless you turn off *Check for Updates
Automatically* in the menu — it also asks GitHub (`api.github.com`) for the newest release and,
if there is one, fetches it (`release-assets.githubusercontent.com`), checks that it is signed
by the same Developer ID as the copy you're running, and offers *Install Update and Relaunch*
in the menu. Nothing is installed without that click." Add the menu items to the menu section
and the alt text of the screenshot. Privacy section: the GitHub requests carry no account
information, only the app's name and version in the User-Agent.

**B7. CLAUDE.md**: the "It talks to one host" ground rule becomes "two services, one of them
optional" with the hosts; "no dependencies" → "no third-party dependencies (NimbusUpdater is
ours, pinned in Package.resolved)"; the release section gains the zip asset, `./build.sh
release`, and the rule that **a release without the zip asset is invisible to the updater**;
the testing section documents `updateFeedURL`; the traps section gets anything learned in
Part D.

**B8. Version 1.2.0** (`VERSION=` in build.sh), release with both assets via the new command.

## Part C — porting to nimbus-net-bar

Same steps with: repo `njoubert/nimbus-net-bar`, bundle id `com.njoubert.nimbusnetbar`, app name
`Nimbus Net Bar`, asset prefix `NimbusNetBar-`, NAME `NimbusNetBar`. Its `StatusBarController`
has the same "Launch at Login / separator / version / Quit" tail (around lines 245–273) — the
menu glue lands in the same place. Its `onWillRelaunch` stops `NetworkMonitor`/`PublicIP`
polling. Its version string is two-component (`1.3`) — `SemanticVersion` handles it; the next
release is `1.4`. Publish a `NimbusNetBar-1.3.zip` on its existing release first (the
equivalent of B0) if a stapled 1.3 app is still in its `dist/`; otherwise the first zip asset
is simply 1.4's. Mirror the `build.sh` changes by hand and diff the two scripts afterwards, as
is the convention for those files.

## Part D — manual test plan (the definition of done for B)

Run on the owner's machine; the Keychain and Login Item checks only mean something there.
Before starting: `./build.sh status` shows 1.1.2 installed from /Applications, login item
enabled, and note whether the Keychain has ever prompted.

1. **API path**: `.build/debug/NimbusLevitonBar --check-update` → "up to date" against the real
   release (after B0 it sees the zip; before B0 it must print the no-zip case, not an error).
2. **Fake feed, happy path**: set `VERSION=9.9.9` temporarily, `./build.sh app` (signed; notarization
   not needed for the updater's check, and `.signing` must be present — it is gitignored and was
   once missing; restore from `../nimbus-net-bar/.signing`), zip it, write a `latest.json` that
   mirrors the API shape with `tag_name: "v9.9.9"` and a `file://` asset URL, then
   `defaults write com.njoubert.nimbuslevitonbar updateFeedURL file:///…/latest.json` and
   relaunch the *installed* 1.1.2. Expect within ~30 s: the menu shows "Install Update 9.9.9 and
   Relaunch" and the version line says "9.9.9 ready". Click it. Expect: the menu bar icon blinks
   once, the app is back, `./build.sh status` says 9.9.9, **no Keychain prompt**, the device list
   loads, **login item still enabled**, no `/Applications/.NimbusLevitonBar-old.app` after ~5 s,
   `~/Library/Caches/…/Updates` empty. Then `defaults delete … updateFeedURL`, revert `VERSION`,
   and reinstall 1.1.2 from the real DMG (`ditto` from the mounted path, as CLAUDE.md says).
3. **Refusal**: same as 2 but the 9.9.9 app built with `.signing` moved aside (ad-hoc signed).
   Expect: no install item ever appears, NSLog shows the signature failure, the Updates cache is
   empty afterwards, a manual check's alert says the download failed verification.
4. **Tag/plist mismatch**: feed says `v9.9.9`, zip contains 9.9.8. Refused, same observable result.
5. **Not from /Applications**: `./build.sh run` (dist/debug). Menu shows only "Check for
   Updates…"; with the fake feed it says "Update 9.9.9 Available…" and opens the browser; never
   installs. Automatic-checks toggle is hidden.
6. **Off switch**: turn off automatic checks, relaunch, watch the log for 2 minutes with the fake
   feed: no check. Manual check still works.
7. **Menu open during a state change**: open the menu, let a check complete (short
   `checkInterval` via a debug default is acceptable for this, or just time it). The menu must
   not rebuild under the cursor; the new item appears on the next open.
8. **Interrupted swap**: create `/Applications/.NimbusLevitonBar-update.app` by hand, launch the
   app; it is removed. Same for `.…-old.app`.
9. **Real release, end to end**: after 1.2.0 ships, install 1.1.2 from its DMG, then publish a
   1.2.1 (or wait for the next real fix) and watch it update itself for real. That's the only
   test of the CDN redirect and the notarized-zip path, so do it before telling anyone the
   feature exists.

## Part E — order of work and what each step leaves behind

1. Package repo: A in full, tests green. Tag `v1.0.0`. (Half a day.)
2. B0, then B1–B4; `--check-update` and the fake-feed happy path (D1, D2) pass.
3. B5; `./build.sh dmg` produces both assets; `./build.sh release` works against a throwaway
   tag on a fork or is dry-run with `gh` absent.
4. B6–B7; `prek run --all-files` passes.
5. D3–D8.
6. B8: ship 1.2.0 with both assets. Then D9 when the next release happens.
7. C; ship net-bar 1.4.

Things that are explicitly **out of scope**: delta updates, rollback after a bad update
(reinstall from the DMG), universal binaries, staged rollouts, any form of telemetry, and
signing in CI (the Developer ID stays on the owner's machine; `./build.sh release` runs there).
