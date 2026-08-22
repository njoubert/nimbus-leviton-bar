# Nimbus Leviton Bar — notes for agents

A macOS menu bar controller for Leviton Decora Smart Wi-Fi devices through the My Leviton
cloud, in Swift. Pure SwiftPM, no dependencies, no Xcode project. A sibling of
`../nimbus-net-bar` — same build pipeline, same conventions; its CLAUDE.md covers the shared
traps (DMG layout, Login Items, notarization) in more depth than this one repeats.
`README.md` is the user-facing description — read it first and keep it true when behaviour
changes. This file is the rest: how to work here, what the API really does, and the traps
already found.

## Ground rules

- **Grill me relentlessly.** Before building a feature, ask every question whose answer would
  change the work — semantics, edge cases, scope — with the facts already checked (what the
  API returns for this account, what the code does now). Decisions, not options.
- **Be concise.** Short reports, no repetition, the salient facts only.
- **`prek` (pre-commit) must pass.** `prek install` once, then `prek run --all-files` before
  claiming done. Shellcheck runs at its default severity (`A && B || true` is flagged — write
  an `if`). Never disable a hook to get past it.
- **Licence headers.** Every new Swift file starts with
  `// Copyright (C) 2026 Niels Joubert` / `// SPDX-License-Identifier: GPL-3.0-or-later`.
  GPL-3.0-or-later; don't vendor code under an incompatible licence.
- **It talks to one host.** `my.leviton.com` (REST and websocket). Keep it that way and keep
  README saying so. Secrets live in the Keychain only (`Keychain.swift`) — never in
  UserDefaults, never in logs (`LevitonRealtime` redacts the token frame even in `--watch`).
- **These are the owner's real lights.** A test that flips a device is visible in the house.
  Prefer no-op writes (`--set Desk 100` on a lamp already on at 100 %) or ask first.
- **Sign-in attempts are rate-limited server-side** (`403 Too many failed attempts` locks the
  account for a while). Never loop a login; one bogus attempt to check the error path is fine.

## Layout

```
Sources/NimbusLevitonBar/
  main.swift              flag parsing, AppDelegate, the hidden Edit menu, Login Item registration
  CLI.swift               --login / --logout / --print / --set / --watch / --get (same client, no UI)
  LevitonClient.swift     REST: login, residences, devices, update, logout; error mapping
  LevitonRealtime.swift   the websocket: token → ready → subscribe → notifications; reconnect
  DeviceStore.swift       @MainActor state: sign-in, devices, optimistic writes, 60 s poll
  Devices.swift           Device / Residence value types
  Keychain.swift          login (email+password) and session (token) as generic-password items
  SignInDialog.swift      NSAlert with email/password fields; the 2FA code prompt
  StatusBarController.swift  the status item (lightbulb + count), the menu
  MenuRows.swift          the view-based rows (device / room / text), the shared LevelControl
                          slider, the hover highlight, and the --dump-menu preview
  LoginItem.swift         SMAppService wrapper (identical to net-bar's)
  AppIcon.swift           the icon (a backlit Decora paddle), drawn in code → .icns at bundle time
  DMGBackground.swift     the disk image's background, drawn in code
build.sh                  build / run / stop / app / dmg / install / uninstall / status / icon / clean
docs/icon.png             re-rendered by `build.sh icon`; screenshot.png is taken by hand
dist/                     build products (gitignored)
```

Swift 5 language mode (`swift-tools-version:5.10`) with the Swift 6 compiler. UI classes are
`@MainActor`; `LevitonRealtime` runs on its own serial queue and calls `onUpdate` on the main
queue, which `DeviceStore` enters with `MainActor.assumeIsolated`. `LevitonClient` is a
`Sendable` class with `async` methods; the CLI drives them with `CLI.block`.

## Build, run, test

```
./build.sh run [--fg]             debug build as dist/debug/Nimbus Leviton Bar.app (--fg: logs here)
./build.sh stop
./build.sh install                release → /Applications, launch, register Login Item
./build.sh dmg                    release → dist/NimbusLevitonBar-<version>.dmg
.build/debug/NimbusLevitonBar --login EMAIL   password from the prompt or $MYLEVITON_PASSWORD
.build/debug/NimbusLevitonBar --print         residences + devices (the data path, no UI)
.build/debug/NimbusLevitonBar --set NAME on|off|N
.build/debug/NimbusLevitonBar --watch         realtime frames to stderr (token redacted)
.build/debug/NimbusLevitonBar --get PATH      raw GET, pretty-printed (poking at new endpoints)
.build/debug/NimbusLevitonBar --dump-menu P   the rows with sample data → PNG, light and dark
```

No unit tests; `--print` and `--watch` are the correctness checks. The CLI and the app share
the Keychain items, so once either has signed in the other works.

**Inspecting the menu** goes through the accessibility API (needs Accessibility permission for
the terminal; screen capture is a separate permission and may not be granted):

```
osascript -e 'tell application "System Events" to tell process "NimbusLevitonBar"
  click menu bar item 1 of menu bar 2     -- menu bar 1 is the (hidden) main menu, see below
  delay 1.5
  set m to menu 1 of menu bar item 1 of menu bar 2
  get name of menu item 3 of m            -- slider rows are view-based: name is missing value
  key code 53
end tell'
```

The sign-in alert is `window 1` (`text field 1` email, `text field 2` password, buttons
`Sign In` / `Cancel`). View-based rows (devices, rooms, All Lights, the status line) have no
accessible name and no readable children — `--dump-menu` is the way to see them; `click at
{x, y}` on a row's position drives them (and a click on the status row is a harmless test of
"the menu stays open").

## The My Leviton API (what the code relies on)

Researched from the community clients (python-decora_wifi, Home Assistant `decora_wifi`,
homebridge-leviton, homebridge-myleviton, schmittx's HA integration, the hubitat driver) and
the official web bundle, then verified live against this account in Aug 2026 (`apiversion`
1.64.0). It is a LoopBack 3 app, so LoopBack conventions (`filter`, `/count`, PUT = partial
update) apply.

- **Login:** `POST /api/Person/login?include=user` with `{email, password}` (+ `code` for 2FA)
  → `{id: <token>, ttl: 86400-ish, created, userId}`. The token goes in
  `Authorization: <token>` — bare, no `Bearer`. Errors: 401 `LoginFailureError` (bad
  password), 403 "Too many failed attempts", 406 "requires code" (2FA), 408 bad code.
- **Residences:** `Person/{userId}/residentialPermissions` → each has `residentialAccountId`
  (owner) *or* `residenceId` (shared). For an account, **use
  `ResidentialAccounts/{id}/residences`** — its `primaryResidenceId` can be a different id
  that 401s (homebridge-leviton issue #6). The client unions both, quietly.
- **Devices:** `Residences/{id}/iotSwitches` → full IotSwitch records. Fields used: `id`,
  `name`, `power` ("ON"/"OFF"), `brightness` (0–100), `canSetLevel`, `minLevel`/`maxLevel`,
  `model`, `serial`, `connected`, `residenceId`, `deleted`. `canSetLevel`, not the model,
  decides whether a slider is shown. Ids are JSON integers; the code carries them as strings.
- **Writes:** `PUT /api/IotSwitches/{id}` with `{"power":"ON","brightness":n}`; the reply is
  the whole record. A toggle sends `power` *only*, so the dimmer's own on-behaviour applies
  (`presetLevel` 0 = last level, else that preset — set in the My Leviton app); the slider
  sends brightness together with `power: ON`, because a level change on an off dimmer is
  invisible and clients disagree on what the server does with it. Fans (`*SF`) take
  brightness in steps of 25.
- **Rooms:** `Residences/{id}/residentialRooms` → `{id, name, power, allConnected}`, in the
  app's order (`position` is null on every room). Devices carry `residentialRoomId` and
  `includeInRoomOnOff`. Room switching is `POST /api/ResidentialRooms/turnOn?id=N` (or
  `turnOff`), what the web app calls — the server flips only the opted-in devices. On this
  account 12 of 16 devices are *not* opted in (all of Alcove, all of Dining Room), so a room
  click there does nothing — by the owner's choice the app mirrors My Leviton rather than
  overriding. The room's `power` is "any device on" regardless of the flag (Alcove: ON with no
  opted-in device); the store recomputes it locally from the devices.
- **Realtime:** `wss://my.leviton.com/socket/websocket` with `Origin: https://my.leviton.com`.
  Send `{"token": {id, userId, ttl, created, rememberMe}}` on open *and again on the
  `challenge` frame* (the nonce is ignored by every client); wait for
  `{"type":"status","status":"ready"}`; then
  `{"type":"subscribe","subscription":{"modelName":"IotSwitch","modelId":<int>}}` per device.
  Changes arrive as `{"type":"notification","notification":{"event":"saved","modelId",
  "data":{partial IotSwitch}}}` — partial, merge it. Ping every 30 s; drops are routine and
  reconnect with backoff; an auth close (1008) backs off an hour. `status: ready` can arrive
  twice — the code subscribes once.
- A 60 s REST poll stays on as the safety net; the menu also refreshes on open if the list is
  over 3 s old.

## What happens when My Leviton misbehaves (DeviceStore)

- **Down / 5xx / offline / timeout:** `LevitonClient.request` retries 502–504 and a dropped
  keep-alive once; then the refresh fails. The old device list stays on screen, the reason
  goes in the Refresh row's detail and the All Devices dot turns red; the 60 s poll and the
  menu-open refresh keep trying; the websocket reconnects with backoff. A command that fails
  snaps its row back and names the device in the error.
- **401 (token expired or rejected):** drop the session, replay the saved password once, and
  carry on. A second 401 inside `reloginCooldown` (10 min) is *not* answered with another
  login — `handleUnauthorized` shows "keeps rejecting the session" and retries after the
  cooldown. Repeated logins are what locks a My Leviton account.
- **401 on one residence only** (the primaryResidenceId quirk, a revoked share): that
  residence is skipped and named in the error; only when every residence 401s is the token
  itself blamed.
- **Bad password:** state `.error("email or password not accepted")`, no session, no polling.
  Retry re-runs the sign-in with the saved password (`retry()`, not `refresh()`, which needs
  a session); "Sign in again…" opens the dialog.
- **403 "Too many failed attempts":** shown as a lockout, nothing automatic retries it.
- **2FA (406) / bad code (408):** the store parks the login in `awaitingCode`; the controller
  asks for the code and signs in again with it.

## Traps already found (don't re-learn these)

- **Keychain prompts come from unstable code signatures.** Keychain item ACLs trust a code
  *designated requirement*; an ad-hoc signature's is a per-build hash, so every rebuild (and
  the bare `.build/debug` binary, signed differently from the bundle) prompted for the login
  keychain password. `build.sh` therefore signs debug bundles *and* the bare binary with
  `SIGN_IDENTITY` (`.signing`) whenever it is set — the requirement becomes "this identifier +
  this Developer ID", stable forever, so one "Always Allow" is the last prompt. Never run the
  CLI from an unsigned binary against the owner's keychain; `./build.sh build` signs it.
- **The menu stays open because the rows are views.** An `NSMenuItem` with a `view` that
  handles its own `mouseUp` does not close the menu (only `cancelTracking()` does). The cost:
  the view must draw its own hover highlight (`MenuRow`: an emphasized `.selection`
  `NSVisualEffectView`, text switching to `selectedMenuItemTextColor`), `mouseExited` never
  arrives when the menu closes (`menuDidClose` clears hover), keyboard navigation skips them,
  and accessibility can't read them. Plain items (Launch at Login, Sign Out, Quit…) stay
  `NSMenuItem`s and close the menu as usual.
- **Don't rebuild the menu while it is open.** Rows update in place (`DeviceRow.device`,
  `RoomRow.update`, `TextRow.set`); structural changes wait for the next open.
- **Slider commits on release only.** `NSSlider.isContinuous` fires per mouse move; the row
  updates its label live and sends one PUT when `NSApp.currentEvent` is `.leftMouseUp`. The
  slider runs 0…maxLevel, not minLevel…maxLevel: 0 is "off" (shown for any off dimmer, and
  dragging there sends `power: OFF` only, keeping the remembered level), anything above 0 is
  floored at `minLevel`.
- **`.byTruncatingTail` shrinks a label's intrinsic width by about a character** — "2 of 4 on"
  rendered as "2 of 4…" with room to spare. Numeric labels use `.byClipping`; the name label
  is the one that gives way (low compression resistance).
- **Menu-bar-only apps need a hidden Edit menu** for ⌘V/⌘C/⌘A to work in the sign-in fields;
  `installEditMenu()` provides one, which is why the status item is `menu bar 2` under AX.
- **Optimistic writes snap back.** A failed PUT restores the row from the `before` snapshot and
  puts the reason in the status line; a 401 triggers a re-login with the saved password.
- **`--dump-bar` is useless for a template image** (white glyph on transparent); read the
  bar through accessibility instead.
- **`getpass` needs a tty**; `script -q /dev/null` did not help — use `MYLEVITON_PASSWORD`
  for non-interactive sign-in.

## Release and distribution

Same as net-bar: `VERSION=` in `build.sh`, `CFBundleVersion` = commit count, `./build.sh dmg`,
check the mounted image by eye, tag `v<VERSION>`, `gh release create`. Signing/notarization
read `SIGN_IDENTITY` / `NOTARY_PROFILE` from a git-ignored `.signing` (the notary profile is
per Apple ID, shared across projects). Unsigned builds need "Open Anyway" when quarantined.
