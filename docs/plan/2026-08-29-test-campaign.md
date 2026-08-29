# Test campaign — plan (2026-08-29)

The repo has no tests ("`--print` and `--watch` are the correctness checks"). This campaign
adds an automated suite across several modalities, plus a live-API compatibility probe for
the undocumented My Leviton API, without changing behaviour and without ever touching the
owner's real lights, Keychain, or login rate limit.

## Facts already checked

- `swift test` **can** `@testable import` the executable target on this machine (Swift 6.2.4
  compiler, Swift 5 language mode) — spiked before this plan was written, so no
  library/executable split is needed. `Package.swift` gains only a `testTarget`.
- `prek` hooks are check-yaml / large-files / merge-conflict / shellcheck — none run Swift,
  so the suite is enforced by `swift test`, not by a hook.
- The main worktree holds a `.leviton` and a fresh-enough `.leviton-session.json`; the CLI's
  `MYLEVITON_ENV_FILE` mechanism reaches both from this worktree, so the probe can run with
  **zero** new logins (the existing `CLI.session` path logs in at most once only if the cache
  has gone stale — the sanctioned flow).
- The realtime protocol is fully described in `LevitonRealtime.swift` and CLAUDE.md, so a
  local stand-in server can speak it verbatim (`Network.framework` has a WebSocket protocol —
  no new dependency).

## Hard rules (from CLAUDE.md, restated as test-suite invariants)

1. **No test may write to a device, log in to my.leviton.com, or touch the real Keychain.**
   Unit/integration tests talk only to in-process fakes (URLProtocol, a localhost websocket).
   The probe is read-only GETs on the cached session and is opt-in, never part of `swift test`'s
   default run on CI or a laptop without credentials.
2. No new package dependencies. Test doubles are hand-rolled; the websocket server uses
   `Network.framework`.
3. Every new Swift file carries the GPL header. `prek run --all-files` must pass at the end.
4. Seams added to production code must be behaviour-neutral: new init parameters with
   defaults that preserve today's wiring, `private` loosened to `internal` only where a test
   must reach, nothing restructured.

## Modalities

### A. Pure unit tests (no I/O)
- `Devices.swift`: `Device.kind` model-suffix table, `comesOnAtPreset` (nil counts as
  preset), `levelClamped`, `Residence.displayRooms` (user order, unmentioned-ids-last,
  stable ties, empty-room drop, offline-rooms-last), `displayDevices`, `unassigned`.
- `Keychain.Session.isFresh`: no ttl → fresh; 60-day ttl → stale one day before expiry;
  short ttl → margin is ttl/2 (the guard that stops a login per command); expired → stale.
- `LevitonClient` parsing statics: `idString` (Int/Double/String/empty/nil), `device(from:)`
  (defaults, `deleted`, id normalisation), `sceneAction` **both live shapes** (the
  JSON-string `properties` blob and the bare property, brightness-as-string), `DeviceFields`
  (json init incl. Double brightness, `body` encoding, equality).
- `Diagnostics`: `redactedBody` hides password+code; `responseBody` rebuilds the login reply
  and **withholds** an unparseable one; `fingerprint` stability; `cap`/`pretty`/`frameSummary`;
  ring-buffer eviction (`capacity`) and body-dropping (`detailWindow`); `amend` on an evicted id.
- `DevCredentials.parse` (comments, `export`, quotes), env-over-file precedence, permissions
  warning, session cache round-trip and 0600 mode — all in a temp dir via `MYLEVITON_ENV_FILE`.

### B. HTTP contract tests — real `LevitonClient`, fake server
Seam: `LevitonClient.init(configuration:)` so a `URLProtocol` mock intercepts everything.
Cover: bare `Authorization` header (no "Bearer"); login body shape and 2FA `code`; error
mapping (401→unauthorized→badCredentials on login, 403 "Too many"→lockedOut, plain
403→unauthorized, 406 code→twoFactorRequired, 408→badTwoFactorCode, LoopBack error
envelope→server(code,msg)); one-shot retry on 502/503/504 and on `.networkConnectionLost`
(and **no** second retry); `residences` union of account+shared, the quiet
`primaryResidenceId` extra, dedup; `roomOrders` key parse + DECORA_SMART precedence;
`activities` include-filter query and `isButtonActivity` drop; `executeActivity`/`setRoomPower`
as POST-with-query-id; `update` echo parse; `rawGet` query splitting.

### C. Store behaviour tests — real `DeviceStore` + fake HTTP, fake feed
Seams: `DeviceStore.init(client:credentials:)` where `credentials` is a new
`CredentialStore` protocol (the Keychain enum wrapped as the default; tests use an
in-memory fake — this is what guarantees rule 1), plus an injectable `realtimeFactory`
(default builds the real `LevitonRealtime`; tests return nil or a localhost-pointed one).
Cover: refresh populates residences and recomputes room power; sorted device order;
per-residence 401 skipped and named vs all-401 → unauthorized; 401 → replay password once →
second 401 inside cooldown does **not** log in again; optimistic write rollback on failure
(row snaps back, error names the device); the three `setBrightness` write shapes (already-on
→ one brightness PUT; off+preset → ON then brightness, two PUTs; off+"last level" → one
combined PUT); level 0 → power-off only; clamping to min/max; `inFlight` counting (realtime
pushes dropped while a write flies, second write doesn't drop the first's guard);
`checkFeedDelivered` (a poll that contradicts held power/brightness drops `isLive`;
`connected` deliberately ignored); `toggleRoom` optimistic paint of connected devices +
rollback; `runActivity` painting from actions with clamping; `apply` merge; tally/summary
strings; signOut clears state.

### D. Realtime protocol tests — real `LevitonRealtime`, localhost websocket server
Seams: injectable `url`, instance `pingInterval`/`pongTimeout` (defaults = today's statics).
A `Network.framework` `NWListener` test server speaks the wire protocol. Cover: connect →
token frame sent (and the *logged* copy is redacted); `challenge` → token re-sent; `ready` →
onLive(true) + one subscribe per device id; duplicate `ready` → no double subscribe;
notification frame → `onUpdate` with parsed fields, non-IotSwitch/no-op frames dropped;
`setDeviceIds` subscribes only additions; server close → onLive(false), exactly **one**
reconnect scheduled (the handleDrop guard), backoff doubling; auth close (1008) → hour-class
backoff selected (observed via `Diagnostics.feed`); `reconnectNow` pre-empts a scheduled
reconnect (generation guard); pong timeout with server ping-replies disabled → drop.
Timing knobs keep the whole file under ~30 s.

### E. Executable smoke + UI-logic tests
- Spawn the built binary (tests know `productsDirectory`): `--dump-menu`/`--dump-internals`
  produce non-empty PNGs; `--render-icon --size 64` writes a PNG; an unknown flag is ignored
  (doesn't launch UI when a CLI flag follows); `--set` with no session fails with the
  "not signed in" message and exit 1; `--put` with junk JSON exits 2. Nothing that opens the
  status bar app run loop.
- AppKit-hosted logic, offscreen: `LevelControl` snap-to-5 (min-floor, 0-means-off),
  `RoomRow`/`RangeSliderCell` knob-at-minimum + spread band inputs, `MenuRow` text inset
  constants. No pixel asserts — the existing `--dump-menu` stays the eyeball check.

### F. Live-API compatibility probe (the undocumented-API answer)
A new read-only CLI command, `--probe`: one pass over every endpoint the app relies on,
asserting the *shape* the code assumes, printing ✓/✗ per expectation and exiting non-zero on
drift. Checks (GETs only, cached session): `residentialPermissions` rows carry
`residentialAccountId` or `residenceId`; `iotSwitches` rows carry id/name/power("ON"/"OFF")/
brightness/canSetLevel/minLevel/maxLevel/connected/model/version/serial/presetLevel with the
types the parser expects (and flags e.g. `includeInRoomOnOff` flipping back to false);
`residentialRooms` in id order with null `position`; the `sorting$residence:{id}$rooms`
preference row still a JSON-string array; `residentialActivities?filter=…` still honours the
include and both `residentialAction` shapes still decode; apiversion is reported for the
record. **No PUTs, no logins beyond the sanctioned stale-cache path, no websocket.**
Run once during this campaign (via `MYLEVITON_ENV_FILE` pointing at the main worktree's
`.leviton`) and record the output in the report. This becomes the periodic drift tripwire.

## Coverage measurement

`swift test --enable-code-coverage`, reported with `xcrun llvm-cov report` filtered to
`Sources/NimbusLevitonBar`. Realistic targets: the logic files (Devices, LevitonClient,
DeviceStore, LevitonRealtime, Diagnostics, DevCredentials, Keychain.Session) well covered
(≳80 % lines each); pure-drawing and panel files (AppIcon, DMGBackground, SocialCard,
InternalsPanel, SignInDialog, StatusBarController, MenuRows beyond the logic above, main.swift
wiring) exercised only by the smoke dumps and exempt from the line target — a headless test
of NSStatusBar is a worse idea than none. The report states per-file numbers and what is
deliberately uncovered.

## Execution order and ownership (parallel agents, disjoint files)

1. **Orchestrator (me):** this plan; the seams (`LevitonClient.init(configuration:)`,
   `DeviceStore` client/credentials/realtimeFactory, `LevitonRealtime` url+timing);
   `Tests/.../Support/` shared helpers (MockURLProtocol, fixture JSON builders, an in-memory
   CredentialStore); keep `swift test` green at every step.
2. Agent A: modality A files `DeviceModelTests`, `SessionFreshnessTests`, `ParsingTests`.
3. Agent B: `DiagnosticsTests`, `DevCredentialsTests`.
4. Agent C: `LevitonClientTests` (modality B).
5. Agent D: `DeviceStoreTests` (modality C).
6. Agent E: `RealtimeTests` + its `LocalWebSocketServer` support file (modality D).
7. Agent F: `Probe.swift` + CLI/main hooks (modality F) — sole owner of CLI.swift/main.swift.
8. Agent G: modality E (`CLISmokeTests`, `MenuLogicTests`).
9. Integrate: full `swift test`, fix conflicts, coverage run, live probe run, `prek`,
   update CLAUDE.md ("No unit tests" is no longer true) and README if it claims otherwise,
   then the report in `docs/report/`.

## Acceptance

- `swift test` passes clean from a fresh checkout with no credentials and no network beyond
  localhost (verified by the suite's own design; the probe is skipped/absent there).
- `prek run --all-files` passes.
- Coverage report generated and summarised per file, with the exemptions named.
- Probe run against the live account recorded verbatim in the report, drift called out.
- A report in `docs/report/2026-08-29-test-campaign.md`: what was built, what it found
  (any real bugs discovered get their own section), coverage numbers, how to run everything,
  and what is deliberately untested and why.
