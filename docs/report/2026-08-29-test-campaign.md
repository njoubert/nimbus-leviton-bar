# Test campaign — report (2026-08-29)

The plan is `docs/plan/2026-08-29-test-campaign.md`; this is what actually happened. Executed
on the `worktree-test-campaign` branch by one orchestrating agent and seven parallel
implementation agents, each owning disjoint files.

## The suite

**243 tests, 0 failures, ~20 s** (`swift test`), verified stable across repeated runs
(the realtime file alone was run six times consecutively, the store file five). No test
touches the network beyond 127.0.0.1, the real Keychain, or a real device — by construction:
`LevitonClient` runs against a `URLProtocol` stub, `LevitonRealtime` against an in-process
`Network.framework` websocket server, and `DeviceStore` takes an injected client and an
in-memory `CredentialStore`. No new package dependencies.

| File | Tests | What it pins |
|---|---|---|
| DeviceModelTests | 19 | `Device.kind`, `comesOnAtPreset` (nil = has a preset), `displayRooms` ordering semantics, `displayDevices`, `unassigned` |
| SessionFreshnessTests | 6 | `Session.isFresh` — the ttl/2-capped-at-a-day margin, incl. the short-ttl guard against login-per-command |
| ParsingTests | 23 | `idString`, `device(from:)` defaults + `deleted`, `DeviceFields`, both `residentialAction` shapes |
| DiagnosticsTests | 30 | redaction (password/2FA/code, login-reply rebuild, unparseable withheld, fingerprints), ring buffer, amend, frame summaries, REST counters |
| DevCredentialsTests | 25 | `.leviton` parsing, env-over-file, permissions warnings, 0600 session cache round trip |
| LevitonClientTests | 36 | bare `Authorization`, login body/parse, full error mapping, retry-once policy, `residences()` union + primaryResidenceId quirk, roomOrders precedence, activities filter, POST-with-query-id, rawGet splitting |
| DeviceStoreTests | 30 | refresh/recompute, the 401-replay-once-then-cooldown dance, per-residence 401 skip, optimistic rollback, the three `setBrightness` write shapes, inFlight guard, checkFeedDelivered, toggleRoom, runActivity, signOut |
| RealtimeTests | 14 | token→challenge→ready→subscribe, notification dispatch, one-drop-one-reconnect, reconnectNow generation guard, pong timeout, stop() |
| ProbeTests | 17 | the `--probe` checks offline, incl. the only-GETs invariant |
| CLISmokeTests | 8 | spawned binary: renderers produce real PNGs, usage/exit codes — behind a hard allow-list so no spawn can launch the app or reach the account |
| MenuLogicTests | 32 | LevelControl 5 % detents/floor/0-is-off, RoomRow knob-at-minimum + spread band, DeviceRow ⌥ reveal, hover/text-colour logic |
| SupportSmokeTests | 3 | the MockHTTP harness itself |

**Line coverage** (`swift test --enable-code-coverage`, in-process only — the CLI smoke tests
exercise `main.swift`/`CLI.swift` in a spawned process llvm-cov cannot see):
Devices 98 % · DevCredentials 97 % · Diagnostics 96 % · LevitonClient 95 % ·
LevitonRealtime 95 % · Probe 91 % · DeviceStore 82 % · MenuRows 68 % (the logic; the rest is
drawing) · Keychain 9 % (the `Session` struct; the SecItem plumbing is deliberately untested —
exercising it means touching the owner's login keychain).
Deliberately at zero in-process: AppIcon, DMGBackground, SocialCard, InternalsPanel,
SignInDialog, StatusBarController, LoginItem, Updates, main.swift, CLI.swift — drawing, AppKit
panels, and glue; the renderers and flag parsing are smoke-tested through the spawned binary
instead, and `--dump-menu`/`--dump-internals` remain the eyeball checks.

Reproduce: `swift test`; coverage with `--enable-code-coverage` then
`xcrun llvm-cov report "$(swift build --show-bin-path)/NimbusLevitonBarPackageTests.xctest/Contents/MacOS/NimbusLevitonBarPackageTests" -instr-profile "$(swift build --show-bin-path)/codecov/default.profdata" -ignore-filename-regex='Tests|checkouts'`.

## Production changes (all behaviour-neutral seams)

- `Package.swift`: the test target.
- `LevitonClient.init(configuration:)` — default `.ephemeral`, unchanged wiring.
- `DeviceStore.init(client:credentials:)` + `realtimeFactory` + two explicit test seams
  (`applyRealtimeForTesting`, `overrideLiveForTesting`); every former direct `Keychain.*` call
  goes through the new `CredentialStore` protocol (`CredentialStore.swift`, whose
  `KeychainCredentialStore` forwards to the same enum).
- `LevitonRealtime(session:deviceIds:url:)` + instance `pingInterval`/`pongTimeout`/
  `authBackoff`/`maxBackoff` knobs (defaults = the old statics).
- `MenuRows.swift`: four one-line `private`→`internal` loosenings, nothing else.
- New feature: **`--probe`** (`Probe.swift` + a switch case in CLI/main) — the read-only
  compatibility probe for the undocumented API, below.

## Real bugs found — both since fixed (same day, follow-up commit)

Found by the campaign, fixed once the owner asked. The descriptions below are the findings as
made; each now carries its fix.

1. **`DeviceStore.stop()` is not sticky.** `toggleRoom` and `runActivity` end their success
   path with `sleep 1.5 s; refresh()` in a Task that strongly holds the store. `stop()`'s
   documented job is to quiesce the app before the updater swaps it out — but a stop landing
   in that window doesn't cancel the delayed refresh, whose tail calls `startRealtime()`. Net:
   tap a room/scene, an update relaunches within 1.5 s, and the *outgoing* copy opens a fresh
   websocket. The poll stays dead (nothing restarts it), so it is socket-only.
   **Fixed:** `stop()` now latches a `stopped` flag consulted by `refresh()`,
   `startRealtime()` (closing the in-flight-refresh window too) and `handleUnauthorized()`
   (a 401 mid-shutdown must not delete the session the incoming copy is about to load, nor
   spend the login replay); `start()` and an explicit `signIn` un-latch. Three regression
   tests in DeviceStoreTests: the delayed-room-refresh window, the in-flight-refresh window,
   and the sign-in revival.

2. **The hour-long auth backoff is unreachable.** URLSession fails the pending `receive`
   *before* delivering `didCloseWith`; the receive failure reaches `handleDrop` first,
   `teardown()` nils the task, and the close — carrying the 1008 and the "unauthorized"
   reason the code matches on — then fails the `webSocketTask === self.task` guard and is
   discarded. Reproduced 6/6 with a local server, and confirmed with a bare-delegate probe
   test that pins URLSession's ordering. So an auth-rejected feed retries on the ordinary
   1→2→…→60 s backoff, not the documented hour. It never *logs in* (the REST side owns that,
   with its own cooldown), so the lockout risk CLAUDE.md worries about is not in play — but a
   dead token means a token frame to my.leviton.com every ≤60 s until the next successful
   re-login replaces it.
   **Fixed:** `handleDrop` now reads `closeCode`/`closeReason` off the task itself — verified
   populated by the time the aborted `receive` lands there, which is earlier than the delegate
   callback ever arrives — and routes 1008 or an unauth-flavoured reason to `authBackoff`.
   The pinning test flipped to assert the hour-class path (both the close-code and the
   reason-regex routes), and the bare-delegate ordering test stays as the documentation of
   *why* the delegate callback could never carry this. CLAUDE.md's "backs off an hour" claim
   is true again.

## Latent traps pinned by tests (no action needed, but know they exist)

- `LevitonClient.iso` parses **only** fractional-second timestamps; a `created` without
  `.000` silently becomes `Date()` — `isFresh` would then trust a wrong clock rather than
  fail. Latent while Leviton always sends millis.
- `pongTimeout` must stay strictly below `pingInterval`: each ping cancels the previous
  deadline, so equal values mean the timeout never fires. 10 s vs 30 s in production is safe.
- `LevelControl` tells a drag from a release solely via `NSApp.currentEvent`; any non-mouse
  path (AX, keyboard) would move the knob and never PUT. Unreachable today — view-based rows
  are already invisible to AX/keyboard.
- A drag to 1–2 % snaps to 0 (off) before the `minLevel` floor applies — deliberate
  ("bottom = off"), pinned so nobody "fixes" the ordering.
- 2FA detection (406) is message-wording-dependent; a server copy change would break the
  code prompt.
- `sortItemsByKeyOrder` ties in `displayRooms` follow the rooms *array* order, which is id
  order only because the API returns id order — the doc comment says "id order".

## The live probe

`--probe` asserts, read-only, the shapes the code assumes of the undocumented API: permission
rows, residence records, every iotSwitch field type, room id-ordering and the dead `position`,
the room-order preference being a JSON *string*, the activities `include` being honoured, and
every `residentialAction` decoding through `sceneAction`. GETs only — its own tests assert the
no-writes invariant — and it rides the CLI's cached session (`MYLEVITON_ENV_FILE` works), so
running it costs zero logins. Exit 1 on drift; run it whenever the server behaves oddly, or
after a My Leviton app update.

Run against the live account 2026-08-29 (cached session, no login, exit 0):

```
✓ residentialPermissions: 1 row, each with residentialAccountId or residenceId
✓ ResidentialAccounts/257067/residences: 1 residence, each {id, name}
✓ preferences: 24 rows, 1 room-order row, each a JSON *string* holding an array of ids
⚠ sorting$ rows: 1
    sorting$residence:243187$rooms
✓ iotSwitches [Niels Home]: 20 devices, every field the shape the parser assumes
⚠ includeInRoomOnOff=false on 7 of 20 devices — the account reads all-true since 2026-08-22
    Cactus / Entrance Track Lights / Living Room Ceiling / Hallway Track Lights /
    PH Mini / Kitchen Ceiling / (+1)
⚠ models [Niels Home]: 20 devices, 7 models — D215P, D23LP, D26HD, D2SCS, D36HD, DW15P, DW3HL
✓ residentialRooms [Niels Home]: 8 rooms, each {id, name, power}
✓ residentialRooms [Niels Home]: listed in ascending id order
✓ residentialRooms [Niels Home]: position still null on every room
✓ residentialActivities [Niels Home]: 4 activities, every row carries residentialActions
✓ residentialActivities [Niels Home]: isButtonActivity is a Bool wherever it appears
✓ residentialActions [Niels Home]: every IotSwitch action decodes
⚠ action shapes [Niels Home]: 44 properties-blob, 12 bare
probed 1 residence, 20 devices, 8 rooms, 4 activities
14 checks, 4 warnings, 0 failures
```

**Live findings from that run:** every wire assumption the code makes still holds, and
`chgReason` is present as an Int on every record (the forensics runbook can keep trusting it).
Two drifts in the account itself: **`includeInRoomOnOff` is back to `false` on 7 of 20
devices** despite the 2026-08-22 all-`true` normalization — something (the My Leviton app's
room editor is the suspect) flips it back, and since the server ignores the flag this is
cosmetic, but CLAUDE.md's claim was stale and has been corrected; and the residence now has
**4 activities** (3 documented) and **20 devices across 7 models** including a D2SCS the docs
never mention.

## Deliberately untested, and why

- The SecItem half of `Keychain.swift`: no way to exercise it without the owner's login
  keychain and code-signing prompts. The `CredentialStore` seam is the compensation — every
  consumer is tested against the protocol.
- `StatusBarController`/`InternalsPanel`/`SignInDialog` beyond smoke: NSStatusBar and modal
  panels in a headless-ish test runner cost more flake than they catch; `--dump-menu` /
  `--dump-internals` (both smoke-tested) stay the eyeball checks, and the AX recipes in
  CLAUDE.md remain the live-app checks.
- The updater (`Updates.swift`, `--check-update`): NimbusUpdater has its own repo and tests;
  `--check-update` needs GitHub.
- Drawing (AppIcon/DMGBackground/SocialCard): smoke-tested for "produces a real PNG" via the
  spawned binary; pixel content is by eye, per the repo's practice.
- The websocket against the *real* server: `--watch` remains the live check; the protocol
  logic is fully covered against a local server speaking the same frames.

## Suite hygiene notes for future work

- `MockHTTP` stubs are FIFO-with-sticky-last per route; to *replace* a route, `reset()` and
  restub. `MockURLProtocol.current` is process-global — end store tests with `stop()`/
  `signOut()` so a straggler Task can't write into the next test's mock (the two 1.5 s
  delayed-refresh paths are why `signOut()` is used there).
- Never construct `DeviceStore()` bare in a test, and always set `realtimeFactory` before
  `start()`/`refresh()` — the defaults are the real Keychain and a real socket.
- RealtimeTests asserts nothing on `Diagnostics.shared` (process-wide) — per-instance
  channels only; keep it that way.
