# Nimbus Leviton Bar — notes for agents

A macOS menu bar controller for Leviton Decora Smart Wi-Fi devices through the My Leviton
cloud, in Swift. Pure SwiftPM, no Xcode project, and exactly one dependency — `NimbusUpdater`
(https://github.com/njoubert/nimbus-updater, MIT, ours; its own CLAUDE.md carries the updater's
traps). A sibling of
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
- **Script output follows `../weshootfilm/provision.sh`.** `print_header` for a section,
  `print_success` (✓), `print_warning` (⚠), `print_error` (✗), `print_info` for indented
  detail, and a closing `print_done` / `print_failed` banner that every run ends on (the EXIT
  trap prints it, so no command can end on an ambiguous note — `result "…"` sets what the
  green one says). The headline carries the glyph and detail lines sit indented under it; warnings and
  errors go to stderr (provision.sh puts them on stdout) so a failure survives a pipe. An ERR
  trap names the failing stage — `stage "…"` before anything long, since `ditto`, `hdiutil`
  and `osascript` fail silently and `set -e` would exit with nothing printed.
- **Licence headers.** Every new Swift file starts with
  `// Copyright (C) 2026 Niels Joubert` / `// SPDX-License-Identifier: GPL-3.0-or-later`.
  GPL-3.0-or-later; don't vendor code under an incompatible licence.
- **It talks to two services, and one of them is optional.** `my.leviton.com` (REST and
  websocket) for the lights, and — unless the user turns off *Check for Updates
  Automatically* — `api.github.com` plus `release-assets.githubusercontent.com` for the
  auto-updater (`NimbusUpdater`, see below). Nothing else, ever, and README must keep saying
  exactly this. Secrets live in the Keychain only (`Keychain.swift`) — never in UserDefaults,
  never in logs (`LevitonRealtime` redacts the token frame even in `--watch`), and never in
  anything sent to GitHub (the update requests carry a User-Agent and nothing else). **The
  one exception is the CLI's `.leviton` file** (`DevCredentials.swift`), below — the app never
  reads it, and it is git-ignored.
- **These are the owner's real lights.** A test that flips a device is visible in the house.
  Prefer no-op writes (`--set Desk 100` on a lamp already on at 100 %); otherwise ask first,
  offer a choice of device, and prefer a room that is already off. Note the device's `power`
  *and* `brightness` before you start and put both back afterwards — `presetLevel` too if a
  test could touch it. And give a write time to settle before believing it: a GET within
  ~1.5 s of an On, and every HTTP echo, will happily report a level the device is about to
  discard (see the `presetLevel` notes below).
- **Sign-in attempts are rate-limited server-side** (`403 Too many failed attempts` locks the
  account for a while). Never loop a login; one bogus attempt to check the error path is fine.

## Layout

```
Sources/NimbusLevitonBar/
  main.swift              flag parsing, AppDelegate, the hidden Edit menu, Login Item, the Updater
  Updates.swift           this app's UpdaterConfig: repo, bundle id, team, names, versions
  CLI.swift               --login / --logout / --print / --set / --room / --watch / --get / --put /
                          --scenes / --scene
  LevitonClient.swift     REST: login, residences, devices, update, logout; error mapping
  LevitonRealtime.swift   the websocket: token → ready → subscribe → notifications; reconnect
  DeviceStore.swift       @MainActor state: sign-in, devices, optimistic writes, 60 s poll
  Devices.swift           Device / Residence / Activity value types
  Keychain.swift          login (email+password) and session (token) as generic-password items
  DevCredentials.swift    the CLI-only .leviton login file and its cached session token
  SignInDialog.swift      NSAlert with email/password fields; the 2FA code prompt
  StatusBarController.swift  the status item (lightbulb + count), the menu
  Diagnostics.swift       the flight recorder: REST, websocket frames, app milestones, redacted
  InternalsPanel.swift    the ⌥ Internals window over that buffer, and --dump-internals
  MenuRows.swift          the view-based rows (device / room / text), the shared LevelControl
                          slider, the hover highlight, the ⌥ model·firmware reveal on a device
                          row, and the --dump-menu preview
  LoginItem.swift         SMAppService wrapper (identical to net-bar's)
  AppIcon.swift           the icon (a backlit Decora paddle), drawn in code → .icns at bundle time
  DMGBackground.swift     the disk image's background, drawn in code
  SocialCard.swift        GitHub's link-preview card, drawn in code from the two docs/ pictures
build.sh                  build / run / stop / app / dmg / install / uninstall / status / icon /
                          social / clean
docs/icon.png             re-rendered by `build.sh icon`; screenshot.png is taken by hand (open the
                          menu, ⇧⌘4, space, click it), then cropped to the menu and the other
                          menu bar icons painted over with the bar's clean background strip;
                          social-preview.png is `build.sh social` — see the trap below
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
.build/debug/NimbusLevitonBar --room NAME on|off   My Leviton's room switch, before/after listing
.build/debug/NimbusLevitonBar --watch         realtime frames to stderr (token redacted)
.build/debug/NimbusLevitonBar --journal PATH  the --watch feed, timestamped to the ms,
                                              appended to PATH — under nohup it is the
                                              forensics tripwire (docs/spikes/2026-08-29/)
.build/debug/NimbusLevitonBar --get PATH      raw GET, pretty-printed (poking at new endpoints)
.build/debug/NimbusLevitonBar --put PATH JSON raw PUT (record fields the app never writes)
.build/debug/NimbusLevitonBar --scenes        the Activities and what each one sets
.build/debug/NimbusLevitonBar --scene NAME    run one Activity
.build/debug/NimbusLevitonBar --dump-menu P   the rows with sample data → PNG, light and dark
                                              (the device rows twice: normal, then ⌥ held)
.build/debug/NimbusLevitonBar --dump-internals P  the Internals panel with sample data → PNG
.build/debug/NimbusLevitonBar --check-update  the release feed as the updater reads it
```

No unit tests; `--print` and `--watch` are the correctness checks. The CLI and the app share
the Keychain items, so once either has signed in the other works.

**A non-interactive shell cannot read the Keychain, and the CLI has a way round it.** An agent,
an ssh session or a cron job gets `errSecInteractionNotAllowed` ("User interaction is not
allowed") from `SecItemCopyMatching` instead of the access panel, so every command reported
`not signed in` with both items sitting right there — and `codesign` fails the same way
(`errSecInternalComponent`), leaving `./build.sh build` binaries on their previous signature.
So the CLI, and only the CLI, takes the login from a git-ignored `.leviton` file in the working
directory when one exists (`DevCredentials.swift`):

```
MYLEVITON_EMAIL=you@example.com
MYLEVITON_PASSWORD=…                # chmod 600 — it warns if the file is readable by others
```

`MYLEVITON_EMAIL`/`MYLEVITON_PASSWORD` in the environment win over the file and suffice on
their own; `MYLEVITON_ENV_FILE` names a file elsewhere. The session token is cached in
`.leviton-session.json` (0600, git-ignored) beside it — **this must never become a login per
command**, which is what locks an account. `--login` and `--logout` write and clear that cache
instead of the Keychain items, and leave `.leviton` itself alone. `Keychain.readFailureHint`
now puts the real `OSStatus` in the "not signed in" message, so the diagnosis is in the error.

`Session.isFresh` keeps a margin of **half the ttl, capped at a day** (it was a flat day) —
same behaviour at the real ttl, and a guard if the server ever hands back a short one, where a
flat day would make a session stale the instant it was issued and log in once per command.

**Inspecting the menu** goes through the accessibility API (needs Accessibility permission for
the terminal — it *is* granted as of 2026-08-25, so check before believing an old note that
says otherwise; screen capture is a separate permission and may not be granted):

```
osascript -e 'tell application "System Events" to tell process "NimbusLevitonBar"
  click menu bar item 1 of menu bar 2     -- menu bar 1 is the (hidden) main menu, see below
  delay 1.5
  set m to menu 1 of menu bar item 1 of menu bar 2
  get name of menu item 3 of m            -- slider rows are view-based: name is missing value
  key code 53
end tell'
```

**The Internals panel, unlike the menu rows, reads back through AX in full** — which is how it
was checked against the real account without a screen grab. `click (first menu item of m whose name is "Internals…")`
(AX lists the alternate whether ⌥ is held or not) opens it; then
`value of static text 1 of window 1` is the state header, `rows of table 1 of scroll area 1 of
splitter group 1 of window 1` is the log, `select row N of t` picks one and
`value of text area 1 of scroll area 2 of splitter group 1 of window 1` is its detail pane.
`click button "Copy" of window 1` puts the whole visible log on the clipboard — the quickest
way to read it (save and restore `pbpaste` around it). Beware `line` is a reserved word in
AppleScript.

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
  → `{id: <token>, ttl, created, userId}`; the ttl is 5184000 (60 days), measured 2026-08-24. The token goes in
  `Authorization: <token>` — bare, no `Bearer`. Errors: 401 `LoginFailureError` (bad
  password), 403 "Too many failed attempts", 406 "requires code" (2FA), 408 bad code.
- **Residences:** `Person/{userId}/residentialPermissions` → each has `residentialAccountId`
  (owner) *or* `residenceId` (shared). For an account, **use
  `ResidentialAccounts/{id}/residences`** — its `primaryResidenceId` can be a different id
  that 401s (homebridge-leviton issue #6). The client unions both, quietly.
- **Devices:** `Residences/{id}/iotSwitches` → full IotSwitch records. Fields used: `id`,
  `name`, `power` ("ON"/"OFF"), `brightness` (0–100), `canSetLevel`, `minLevel`/`maxLevel`,
  `model`, `version`, `serial`, `connected`, `residenceId`, `deleted`. `canSetLevel`, not the
  model, decides whether a slider is shown. Ids are JSON integers; the code carries them as
  strings. `version` is the firmware — "1.0.15" on the D36HDs, "1.7.1; CP 1.13" on the DW3HLs
  (two numbers, the radio co-processor's after the semicolon; Bookcase reads `CP 99.99`), so
  it is a free-form string, not a version to parse. It rides along on the device list, is
  shown by `--print` (`fw=`) and by the ⌥ reveal in the menu, and is *not* in
  `DeviceFields` — the realtime feed never sends it, and the 60 s poll re-reads the whole
  record anyway.
- **Writes:** `PUT /api/IotSwitches/{id}` with `{"power":…}` and/or `{"brightness":n}`; the
  reply is the whole record. A toggle sends `power` *only*, so the dimmer's own on-behaviour
  applies (`presetLevel` 0 = last level, else that preset — set in the My Leviton app). Fans
  (`*SF`) take brightness in steps of 25.
- **`presetLevel` decides how a level write has to be sent, and it is per device.** It is the
  level a dimmer comes up at, set in the My Leviton app; **0 means "last level"**. It rides
  along on `Residences/{id}/iotSwitches`, so `Device.presetLevel` is always populated;
  `comesOnAtPreset` is the thing to branch on, and an *unknown* preset counts as having one
  (guessing wrong that way costs a slow write, the other way costs a wrong level).
  `--print` shows `preset=N` for the devices that have one.
  - **Off with a preset → two writes, On first, `onSettle` (2 s) apart.** `{"power":"ON",
    "brightness":n}` in one PUT does not work for these, and neither does brightness-then-On:
    the cloud accepts n and echoes it back, but the **device** comes up at its `presetLevel`
    and reports that ~1–1.5 s later, overwriting n. The level therefore has to be written after
    that report. The light is visibly at its preset for that moment; only rewriting the user's
    `presetLevel` would avoid it, and that is their setting, so we don't.
  - **Off at "last level" (0) → the single combined write, and it lands at once.** There is no
    preset for the device to prefer, so `{"power":"ON","brightness":n}` sticks.
  - **Already on → a single `brightness` PUT.** Sticks immediately.

  Measured 2026-08-22 with `--put`, `--get` and `--watch`. Entrance Track Lights (D36HD,
  preset 30): `{"power":"ON","brightness":70}` → GETs read 70, 70, 70, then **30** a second and
  a half later, with the realtime feed showing the client-id-less `{"brightness":30}` from the
  device landing right after our write; On-then-wait-then-70 held at 70. Office Ceiling (D26HD,
  preset 0): the same combined write held at 75 for 30 s. **An echo is not proof** — the reply
  to a combined write reports the n the device is about to throw away. Only a GET a couple of
  seconds later, or the device's own (client-id-less) realtime message, tells you the truth.
- **Rooms:** `Residences/{id}/residentialRooms` → `{id, name, power, allConnected}`, **in id
  order** — not the app's order, and `position` is null on every room (dead, like
  `includeInRoomOnOff`). Devices carry `residentialRoomId` and
  `includeInRoomOnOff`. Room switching is `POST /api/ResidentialRooms/turnOn?id=N` (or
  `turnOff`), what the web app calls — **the server moves every device in the room and ignores
  `includeInRoomOnOff`.** Measured 2026-08-22 with `--room Alcove on`: all three Alcove
  devices are opted *out* and all three came on (and `--room Alcove off` put them back). The
  web bundle agrees — `includeInRoomOnOff` is only a model getter/setter there, nothing reads
  it, and Leviton's own demo-mode stand-in for `turnOn` does `updateAllSwitchesInRoom(id,
  "ON")`, unfiltered. So the flag is dead server-side; the app shows no sign of it (it is
  still parsed and `--print` dumps `includeInRoomOnOff=false` as a tripwire). On 2026-08-22,
  after that test, the owner had all 12 opted-out devices set back to `true`
  (`--put IotSwitches/{id} '{"includeInRoomOnOff":true}'`, which touches nothing else), so the
  account now reads all-`true` and re-testing the server's behaviour means setting one `false`
  first. The room's `power` is "any device on"; the store recomputes it locally from the
  devices.
  Timestamps are no help in forensics here: every device's `lastUpdated` bumps on a periodic
  cloud sync (all of them at once), and a redundant PUT bumps it too.
- **The room order the user dragged into place lives on the *person*, not the room.**
  `Person/{userId}/preferences` (a LoopBack `Preference`: `{appId, key, value}`) carries one
  row per residence — `appId` `DECORA_SMART`, `key` `sorting$residence:{residenceId}$rooms`,
  `value` a JSON *string* holding an array of room ids. Per person, so two people sharing a
  residence each keep their own order. `LevitonClient.roomOrders` reads the lot in one request
  and `Residence.displayRooms` applies it; `--print` shows the result and says so when no row
  exists. Verified 2026-08-24 against this account: the row read
  `[1613723,471125,1612878,186780,1489458,186779,211988,355666]` and the owner confirmed the
  menu now matches the app row for row.
  - The web bundle is where the scheme is spelled out (`SortOrderPreferencesService`, config
    `baseKeyPrefix: "sorting$"`, `roomKey: "$rooms"`): `saveRoomSortOrder` writes the id array,
    `sortItemsByKeyOrder` reads it as `{id: index}` and lodash-`sortBy`s on it — so **ids the
    row doesn't mention sort last**, stably, and an absent row falls back to `sortBy(id)`,
    which is the order the API already returns. `displayRooms` does the same, which is why the
    menu was accidentally right for an account that had never reordered.
  - The same prefix covers lists we do not read: `$room:{id}$iotSwitches$` (devices within a
    room), `$unassignedRoomIotSwitches`, `$activitySortOrder`, `$scenes$`. This account has
    exactly one `sorting$` row, so there is nothing to test the device case against — our own
    device order stays alphabetical.
  - Only the *whole* preference list can be fetched from `--get`'s original form; it now
    splits a `?a=b` tail into query items, so LoopBack `filter={…}` calls work from the CLI.
    The list is 24 rows.
- **Scenes are called Activities.** `Residences/{id}/residentialActivities` — whole-residence,
  and `ResidentialRooms/{roomId}/residentialScenes` — per room (this account has 3 activities
  and 0 room scenes). Both hang their contents off the same `residentialActions` join, and
  both have an `execute`. One call gets the lot:
  `Residences/{id}/residentialActivities?filter={"include":["residentialActions"]}`.
  Run one with **`POST /api/ResidentialActivities/execute?id=N`** — no body, the id in the
  query, exactly like `ResidentialRooms/turnOn`. Full CRUD exists too (`POST`/`PATCH`
  `/ResidentialActivities[/{id}]`, `replaceOrCreate`, `upsertWithWhere`, `convertRoomAction`,
  plus `sonosActions` / `schlageActions` / `onHome` / `onAway` per activity) — deliberately
  not used; the My Leviton app owns editing. An activity has **no state**: running it is
  fire-and-forget, so there is nothing to show back but its name.
- **Realtime, and how much "live" is worth:** `wss://my.leviton.com/socket/websocket` with `Origin: https://my.leviton.com`.
  Send `{"token": {id, userId, ttl, created, rememberMe}}` on open *and again on the
  `challenge` frame* (the nonce is ignored by every client); wait for
  `{"type":"status","status":"ready"}`; then
  `{"type":"subscribe","subscription":{"modelName":"IotSwitch","modelId":<int>}}` per device.
  Changes arrive as `{"type":"notification","notification":{"event":"saved","modelId",
  "data":{partial IotSwitch}}}` — partial, merge it. Ping every 30 s; drops are routine and
  reconnect with backoff; an auth close (1008) backs off an hour. `status: ready` can arrive
  twice — the code subscribes once.
  - **An open websocket is not a working one, and three things now guard that.** (1) A ping
    must be answered inside `pongTimeout` (10 s): `sendPing`'s completion *is* the pong handler
    and has no timeout of its own, so a half-open connection — sleep, a changed network, a dead
    NAT mapping — used to look healthy until the kernel gave up retransmitting, minutes later.
    (2) `DeviceStore.checkFeedDelivered` compares each poll against what we hold: a `power` or
    `brightness` the feed never announced means the subscriptions are not being honoured (the
    server never acks a `subscribe`, so nothing else can detect this) — drop `isLive` and
    reconnect. `connected` is deliberately not compared: a device that falls off Wi-Fi may
    never announce it. (3) `reconnectNow()` skips the backoff, from `NSWorkspace`'s wake
    notification and from the Refresh row — the hour-long auth backoff was otherwise
    unreachable, because `refresh()` only calls `setDeviceIds` while `realtime != nil`.
  - **One drop must schedule exactly one reconnect.** `teardown()` fails every request
    outstanding on the task, and each failure comes back to `handleDrop` — an aborted
    `sendPing`, the pending `receive`. Before the `guard task != nil`, a single stall scheduled
    three reconnects and trebled the backoff (1 s → 8 s). A scheduled reconnect also checks the
    `generation` it was queued at, so a `reconnectNow()` in the meantime doesn't get killed by
    the timer it pre-empted. Measured by forcing the failure: `pongTimeout` to 0.0001 and
    `pingInterval` to 5, then `--watch`.
- A 60 s REST poll stays on as the safety net; the menu also refreshes on open if the list is
  over 3 s old.
- **The Refresh row reports the channel, not a clock.** `LevitonRealtime.onLive` (fired from
  `ready`'s `didSet`, on the main queue) drives `DeviceStore.isLive`, and the row reads `live`
  while the socket is up — the fetch time says nothing about freshness then, and the 60 s poll
  keeps it looking recent even when the socket has been in its hour-long auth backoff all
  along. Only when the feed is down does the row show the fetch age (`updated 47 seconds ago`,
  `RelativeDateTimeFormatter`; under a second it says "in 0 seconds", so that case is special-
  cased to "just now"). The age is re-rendered by a 1 s timer that runs only while the menu is
  open (`.common` mode, or it would not fire during tracking). `--watch` prints `— live —` /
  `— not live —` — the way to see the signal without the UI. Clicking Refresh goes through
  `refreshNow()`, which also reconnects a feed that isn't live.
- **Forensics: who changed a device.** Two markers, calibrated live 2026-08-29. (1) A
  realtime `saved` frame from a *public-API* write (the phone app, this app, a scene
  execute) carries the writer's `client_id` in `data`. **An Alexa command carries none by
  either path** — the skill writes through an internal Leviton channel (verified with a
  voice-commanded ON of a non-Matter DW15P), and Matter is local — and neither does the
  device's own report. (2) `IotSwitch.chgReason`, trusted only when freshly re-reported
  (`lastUpdated` matches the change): 3 = remote command (a cloud PUT sets it — and the
  PUT's *echo* still shows the old value, the same echo-lies trap as `presetLevel`),
  1 = local paddle (inferred, not yet provoked), 6 = OTA/reboot. All seven D36HDs
  (enrolled 2026-08-22..24) sit on an Amazon **Matter** fabric (`matterFabric` vendor
  4631; firmware 1.0.0 misreported it as vendor 0 until the 1.0.15 update), so an Echo can
  command them without my.leviton.com seeing a write. The decoder table, the tripwire
  runbook and the open investigation live in `docs/spikes/2026-08-29/lights-forensics.md`.

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

## The Internals panel (Diagnostics.swift, InternalsPanel.swift)

⌥ over the version line turns it into **Internals…**, which opens a floating window on the
app's network life: the feed's state, every REST request with its body and its reply, every
websocket frame, and the app's own milestones. It exists because the alternative was reading
`--watch` in a terminal, which cannot see the REST side at all, and only from launch.

- **`Diagnostics.shared` records from launch, panel or no panel** — a ring buffer (2000
  events; only the newest 200 keep their bodies, each capped at `detailLimit`). The failures
  worth seeing happen before anyone opens the window. It is a plain `@unchecked Sendable` class
  with one `NSLock`, called from the URLSession callbacks, the realtime queue and the main
  actor; no callback is made while the lock is held and it touches no AppKit, so the CLI links
  it harmlessly too.
- **Nothing secret goes in, and there is no reveal switch.** Three places do the redacting:
  `LevitonRealtime.send` logs a *rebuilt* token frame (`id` → fingerprint) rather than the
  frame it sends; `Diagnostics.redactedBody` drops `password` and the 2FA `code` from a request
  body; `Diagnostics.responseBody` rebuilds the `Person/login` reply, since that reply *is* the
  token — and withholds it entirely if it cannot be parsed, because a body we cannot understand
  is one we cannot redact. `Authorization` is never recorded at all. A token appears only as
  `Diagnostics.fingerprint` — six hex of its SHA-256, enough to see that a re-login changed it.
- **Copy takes the header and the one-line log, never the bodies.** A device record carries
  `lat`/`long`, `mac`, `localIP` and the serial; the panel showing that to the owner is fine,
  a clipboard bound for a GitHub issue is not.
- **The panel never reaches into the realtime queue.** `LevitonRealtime` pushes what it knows
  (state, since, frames, subscriptions, backoff, next reconnect, last ping/pong) into
  `Diagnostics.feed`, and the panel reads that. Its header dot follows *the feed's own* record;
  `DeviceStore.isLive` — what the menu says — is printed beside it only when the two disagree,
  which would itself be a bug.
- **It polls, it is not called back.** A 4 Hz `.common` timer (so it keeps running while a menu
  is tracked, which is exactly when someone is watching) reloads only when
  `Diagnostics.version` has moved. Auto-scroll follows the tail unless a row is selected or the
  list has been scrolled up. Pause freezes the view, not the recording.
- **The three buttons are the paths the app already uses** — `reconnectFeed()`, `refresh()` and
  `forceRelogin()` on the store; nothing here writes to a device. `forceRelogin` asks first:
  repeated sign-ins are what lock a My Leviton account.
- **`--dump-internals PATH`** renders it with a seeded session's worth of events, both
  appearances, the same trick as `--dump-menu` — and `InternalsPreview.seed()` is where to add
  a case worth eyeballing.

## Traps already found (don't re-learn these)

- **⌥ swapping a menu item is an *alternate item*, and it has three conditions.** The item must
  come directly after the one it replaces, carry the same key equivalent (both `""` here), and
  have `isAlternate = true` with `keyEquivalentModifierMask = .option`; the item above it gets
  `keyEquivalentModifierMask = []` so its own default (`.command`) doesn't muddy the match.
  AppKit then swaps them live while the menu is open, which deciding at build time (reading
  `NSEvent.modifierFlags` in `menuNeedsUpdate`) would not.
- **⌥ over a *view-based* row is polled, not an alternate item.** `NSMenuItem.isAlternate`
  swaps plain items only, and a local `flagsChanged` monitor
  (`NSEvent.addLocalMonitorForEvents`) is not called while a menu is tracking — the menu's own
  loop does not route events through `NSApplication.sendEvent`. So `StatusBarController` reads
  `NSEvent.modifierFlags` (current hardware state, no event needed) from a 0.1 s timer added
  in **`.common`** mode, the same reason as the Refresh row's age timer, and only while the
  menu is open. Three things this has to get right: the menu can be *opened* with ⌥ already
  down, so `menuWillOpen` reads the flags once itself — and it runs *after* `menuNeedsUpdate`
  built the rows, so it applies the state to them; `menuDidClose` clears it, or the next open
  starts in the revealed state with `optionDown` still true and nothing to change it; and
  `addDevice` seeds each new row from `optionDown` in case AppKit rebuilds under a held key.
  `DeviceRow.showsDetail` then swaps **one** constraint (what the name gives way to) and two
  `isHidden` flags — the model label is pinned over the slider's own place, so neither view
  ever has an ambiguous frame and nothing about the menu's structure changes while it is open.
- **A wrapping `NSTextField` in an autolayout column will eat the window's spare height.** The
  Internals header, pinned above a stack of controls above a split view, took ~250 pt of slack
  and left the split view a sliver — nothing looked broken, the list was simply not there.
  `setContentHuggingPriority(.required, for: .vertical)` on the header and the control stack
  hands the slack to the split view instead. `--dump-internals` is what showed it.
- **An `NSSplitView`'s divider starts where the panes' frames say it does.** Arranged subviews
  added with zero frames come out zero-high; set each pane's frame before the first layout
  (320/160 here) and the ratio is what you asked for.
- **A panel that holds its store weakly needs the preview to hold it.** `InternalsPreview`
  builds a throwaway `DeviceStore`; as a temporary it was deallocated before the header was
  drawn, and the compiler said so ("weak reference will always be nil"). Keep it in a local and
  `withExtendedLifetime` it.
- **`isReleasedWhenClosed = false` on any panel the menu reopens** — the default releases it on
  close, and the second visit is a crash.
- **A truncated JSON body is no longer JSON.** The detail pane pretty-prints on selection, so
  `detailLimit` is 96 KB: this account's `Residences/{id}/iotSwitches` reply is 51 KB and would
  otherwise arrive as an unreadable single line.

- **A README hero image is not the link preview.** What chat apps, Slack and Twitter show for
  a GitHub URL is `og:image`, and that is either a picture uploaded under the repo's
  Settings › General › Social preview or, failing that, a grey card of the repo name and the
  contributor count. GitHub never reads the README for it. **There is no API for the upload** —
  not REST, not GraphQL, not `gh` — so `./build.sh social` only draws the file; putting it on
  the repo is a manual drag onto that settings page, once per repo, and again whenever the
  icon or the screenshot changes. Apple's LinkPresentation sometimes scrapes a README image
  when the `og:image` fetch fails, which makes a repo *look* like it has a preview it hasn't
  got — check `curl -sL <repo> | grep og:image` instead: an `opengraph.githubassets.com` URL
  means the generated card, `repository-images.githubusercontent.com` means a real one.
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
- **Sliders snap to 5 % (`LevelControl.step`) and commit on release only.** The drag rounds to
  the nearest step and writes it back to `slider.doubleValue`, so the knob sits in the detent
  rather than under the mouse — verified not to disturb `NSSliderCell` tracking, which derives
  the value from the mouse on every move. There are no `numberOfTickMarks`: visible ticks on a
  100 pt track would be 5 pt apart and change the knob's shape. A level *reported* by a device
  is shown as it is, unsnapped. `NSSlider.isContinuous` fires per mouse move; the row
  updates its label live and sends one PUT when `NSApp.currentEvent` is `.leftMouseUp`. The
  slider runs 0…maxLevel, not minLevel…maxLevel: 0 is "off" (shown for any off dimmer, and
  dragging there sends `power: OFF` only, keeping the remembered level), anything above 0 is
  floored at `minLevel`.
- **The room slider's knob is the minimum, and the band is the spread.** A room's (and All
  Devices') slider sits at the lowest level among *exactly the dimmers it would move* — the
  same `canSetLevel && connected` set as `setBrightness(ofAll:)`, with an off dimmer counting
  as 0, so a room with one dimmer off reads 0. Not the average: the row's one gesture sets
  every dimmer at once, so the knob has to be the level the room is at *least* at, or a small
  nudge blasts the dim half of a room. `RangeSliderCell` then fills the track on from the knob
  to the highest level, in 40 % accent, so the spread stays visible. Two things it is easy to get
  wrong: the override is `drawBar(inside:flipped:)` — `drawBarInside(_:flipped:)` is the
  obsoleted Swift 2 name and compiles to a *different*, never-called selector — and a value
  maps to the knob's **centre**, whose travel is a knob-width shorter than the bar
  (`rect.minX + knob/2 + f * (rect.width - knob)`); interpolating across the bar itself leaves
  the band visibly off the knob at both ends. Check with `--dump-menu`.
- **Shadow offset and blur are in base space.** `CGContext.setShadow` ignores the CTM, so a
  blur sized for the 1024-pt reference canvas is that many *device pixels* at every render
  size — at the 128-pt icon the body shadow ran off the bottom edge and was clipped to a hard
  line (the DMG window showed it). Every `setShadow` in `AppIcon` multiplies by `scale`
  (= size / 1024). After touching the icon, check the edge alpha is 0 at 256 px as well as
  1024 px — the scratch `edge.swift` trick: read back the bitmap's outermost rows/columns.
- **Plain items' text starts 24 pt in, not 14** — the menu has a state column because
  "Launch at Login" has a checkmark. `MenuRow.textInset` matches it; measure against a real
  plain item after touching the layout (screenshot at 2× → halve the pixel offset).
- **`.byTruncatingTail` shrinks a label's intrinsic width by about a character** — "2 of 4 on"
  rendered as "2 of 4…" with room to spare. Numeric labels use `.byClipping`; the name label
  is the one that gives way (low compression resistance).
- **Menu-bar-only apps need a hidden Edit menu** for ⌘V/⌘C/⌘A to work in the sign-in fields;
  `installEditMenu()` provides one, which is why the status item is `menu bar 2` under AX.
- **Optimistic writes snap back.** A failed PUT restores the row from the `before` snapshot and
  puts the reason in the status line; a 401 triggers a re-login with the saved password.
- **A `residentialAction` has two shapes, both live on this account.** Usually
  `targetProperty: "properties"` with `targetValue` a *JSON string* —
  `"{\"power\":\"ON\",\"brightness\":40}"`, a string, so it needs a second parse. But
  "Good Morning" carries `targetProperty: "power"`, `targetValue: "ON"` — a bare property with
  the value unwrapped. `LevitonClient.sceneAction` handles both; a reader that only knows the
  blob silently drops actions.
- **Hide activities with `isButtonActivity`** — they belong to a 4-button controller, and the
  web app's own list is `getNonButtonActivitiesForResidence()` (`!isButtonActivity`).
  `position` is null on every activity, as on rooms: the API's listing order is the order.
- **`customIcon` is one of 41 fixed names** (`all-on`, `goodnight`, `party`, `movie`…) but
  owners pick them freely — in Aug 2026 this account had a "Good Morning" set to `dinner` and
  an "I'm Home" set to `away` (the activities have since been rebuilt and now happen to
  match). Drawing a glyph from it would be worse than drawing none.
- **`execute` does push realtime frames** (verified 2026-08-22): each action arrived as an
  IotSwitch `saved` notification within 1–3 s, in two waves — the cloud write, then the
  device's confirmation. Offline devices get a cloud-side frame too (the offline `760 Fridge`
  reported `power: OFF`), so a scene "succeeds" whether or not the hardware heard it.
- **`--dump-bar` is useless for a template image** (white glyph on transparent); read the
  bar through accessibility instead.
- **`getpass` needs a tty**; `script -q /dev/null` did not help — use `MYLEVITON_PASSWORD`
  for non-interactive sign-in.

## Auto-update (NimbusUpdater)

The app checks its own GitHub releases and can replace itself. The mechanism, its trust model
and its traps are documented in **`../nimbus-updater/CLAUDE.md` — read it before touching
anything about updates.** What matters *here*:

- **How it is wired in: an ordinary SwiftPM package dependency, by URL.** `Package.swift` has
  `.package(url: "https://github.com/njoubert/nimbus-updater.git", from: "1.0.0")` and the
  target takes `.product(name: "NimbusUpdater", package: "nimbus-updater")`. **Not a git
  submodule, and not a path dependency** — the checkout beside this repo is only where the
  source is edited, never what gets built. SwiftPM clones it into `.build/checkouts/` and
  `Package.resolved` (committed) pins the exact version and revision, so a build here is
  reproducible and a new upstream tag arrives only when someone runs `swift package update`
  and commits the result.
- **Changing the updater means two repos.** Edit `../nimbus-updater`, `swift test` there, tag
  it, push, then `swift package update nimbus-updater` here and commit `Package.resolved`. To
  try a change before tagging, temporarily point `Package.swift` at
  `.package(path: "../nimbus-updater")` — and never commit that: it would break every clone
  that has no sibling checkout, and CI.

- `Updates.swift` holds the config; `main.swift` builds the `Updater` (never in `--dump-bar`
  runs), sets `onWillRelaunch` to `store.stop()`, and hands it to `StatusBarController`, which
  owns the three menu items and the alert from a manual check.
- **The updater's state must not restructure an open menu** — the same trap as the device rows.
  `updaterChanged()` only retitles the version line while the menu is open; new items appear on
  the next open.
- **A release is invisible to the updater unless it carries `NimbusLevitonBar-<version>.zip`,**
  built by `build.sh dmg` from the *stapled* app. `./build.sh release [RELEASE_NOTES_FILE]`
  does the whole dance (tag, build, push, publish both artifacts) and is the way to ship from
  now on.
- Testing an update without publishing one: `defaults write com.njoubert.nimbuslevitonbar
  updateFeedURL file:///tmp/latest.json`, a JSON in the API's shape whose asset URL is a local
  `file://` zip. `defaults delete` it afterwards. The full manual plan is in
  `docs/autoupdate-plan.md`, which also records what was built and what is left.
- The updater only ever installs into `/Applications/Nimbus Leviton Bar.app` and only when
  the running copy *is* that path, so `./build.sh run` builds can never swap themselves.

## Release and distribution

Repo: https://github.com/njoubert/nimbus-leviton-bar — releases carry the notarized DMG
(1.0.0, 1.1.0 and 1.1.1 shipped 2026-08-21; 1.1.2, 1.2.0, 1.3.0 and 1.4.0 on 2026-08-22). From 1.2.0 the
app updates itself, so **every release must carry both the DMG and the zip** — use
`./build.sh release [RELEASE_NOTES_FILE]`, which does the whole dance and cannot forget
the zip. Same as net-bar: `VERSION=` in `build.sh`, `CFBundleVersion` = commit count, `./build.sh dmg`,
check the mounted image by eye, tag `v<VERSION>`, `gh release create`. Signing/notarization
read `SIGN_IDENTITY` / `NOTARY_PROFILE` from a git-ignored `.signing` (the notary profile is
per Apple ID, shared across projects). The signing key lives in this machine's login keychain
and as a `.p12` export kept off it — the only two copies, and Apple will not re-issue it. Unsigned builds need "Open Anyway" when quarantined. The release binary is arm64 only (plain
`swift build`); the installed copy in /Applications is `ditto`ed out of the DMG, not
`build.sh install`, so it is the exact stapled artifact. When mounting a DMG to copy from it,
use the path `hdiutil attach` prints rather than assuming `/Volumes/<name>` — a stale mount
from an earlier verify step puts the new one on `/Volumes/<name> 1` and `ditto` then fails
after the old /Applications copy is already gone. `hdiutil detach … -force` the strays first.
