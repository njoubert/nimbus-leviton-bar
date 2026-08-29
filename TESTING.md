# Testing Nimbus Leviton Bar

The suite exists so nothing here needs the owner's real lights, Keychain, or login rate limit
to prove itself. It was built in one campaign on 2026-08-29 (`docs/plan/` and `docs/report/`
hold the plan and the full report, including what the campaign found); this file is what you
need day to day.

## Running

```
swift test                                # ~245 tests, ~20 s, no credentials, no network
                                          # beyond 127.0.0.1
swift test --filter DeviceStoreTests      # one file; class names match the file names
swift test --enable-code-coverage         # then:
xcrun llvm-cov report \
  "$(swift build --show-bin-path)/NimbusLevitonBarPackageTests.xctest/Contents/MacOS/NimbusLevitonBarPackageTests" \
  -instr-profile "$(swift build --show-bin-path)/codecov/default.profdata" \
  -ignore-filename-regex='Tests|checkouts'
.build/debug/NimbusLevitonBar --probe     # the LIVE check: read-only, cached session,
                                          # exit 1 when my.leviton.com drifts from the
                                          # shapes this code assumes
```

`--print` and `--watch` remain the live correctness checks; `--probe` is the drift tripwire
for the undocumented API — run it when the server behaves oddly, or after a My Leviton app
update. It sends GETs only (its own tests assert that) and rides the CLI's cached session,
so it costs zero logins while the cache is fresh.

## The map

| File | Pins |
|---|---|
| DeviceModelTests | `Device.kind`, `comesOnAtPreset` (nil = *has* a preset), `displayRooms` ordering |
| SessionFreshnessTests | the ttl/2-capped-at-a-day margin; the login-per-command guard |
| ParsingTests | `idString`, `device(from:)` defaults, both `residentialAction` shapes |
| DiagnosticsTests | redaction (passwords, tokens, the login reply), ring buffer, frame summaries |
| DevCredentialsTests | `.leviton` parsing, env-over-file, the 0600 session cache |
| LevitonClientTests | bare `Authorization`, error mapping, retry-once, the residences union |
| DeviceStoreTests | the 401 dance, optimistic rollback, the three brightness write shapes, the sticky `stop()` |
| RealtimeTests | token→challenge→ready→subscribe, one-drop-one-reconnect, pong timeout, the auth backoff |
| ProbeTests | every `--probe` check offline, including its only-GETs invariant |
| CLISmokeTests | the spawned binary: PNG renderers, usage, exit codes |
| MenuLogicTests | 5 % detents, room knob-at-minimum + spread band, the ⌥ reveal |
| SupportSmokeTests | the MockHTTP harness itself |

## The harness (Tests/NimbusLevitonBarTests/Support/)

- **MockHTTP** — a fake my.leviton.com behind a `URLProtocol`.
  `let (client, http) = MockHTTP.makeClient()`, then `http.stub(method, path, reply)` with the
  path relative to `/api/` and the **query string not part of the route key**. Replies per
  route are a FIFO whose **last entry is sticky** — one stub serves a repeating poll; two
  serve "fail once, then succeed". You cannot *replace* a stub by appending: `http.reset()`
  and restub (which also clears the recorded requests). An unstubbed route answers 599 with
  the route named, so a test fails loudly instead of hanging. `.delayed(seconds, status,
  json)` keeps a request in flight — stub it *before* any immediate reply for the same route
  or the FIFO serves the fast one first. `http.requests(method, path)` returns what was sent,
  bodies parsed.
- **Fixtures** — wire-shaped JSON builders (integer ids, "ON"/"OFF" powers, room-order
  preferences as JSON *strings*, both action shapes) plus ready-made `Device`/`Session` values.
- **FakeCredentialStore** — the in-memory `CredentialStore`; `.calls` records mutations.
- **LocalWebSocketServer** — Network.framework, speaks the realtime protocol on
  127.0.0.1; `autoReplyPing: false` simulates a half-open connection; `closeNewest(code:reason:)`
  sends a real close frame (1008 works through URLSession).
- **waitUntil("what") { cond }** — the only way to wait. Never sleep for a *positive*;
  sleeping is only for "and then nothing else happened" assertions.

## The rules that keep it safe

- **Never construct a bare `DeviceStore()` in a test.** The defaults are the real Keychain
  and a real socket. Always `DeviceStore(client:credentials:)` with a `FakeCredentialStore`,
  and set `store.realtimeFactory` **before** any `start()`/`refresh()`.
- Tests touch no network beyond 127.0.0.1, no Keychain, no device. The probe is the one
  thing that touches the live service, read-only, and it is never part of `swift test`.
- `MockURLProtocol.current` is process-global, so the suite runs serially (XCTest's
  default). End every `DeviceStore` test with `store.stop()` — or `signOut()` after
  `toggleRoom`/`runActivity`, whose 1.5 s delayed refresh would otherwise write into the
  *next* test's mock.
- RealtimeTests asserts nothing on `Diagnostics.shared` (process-wide; other suites write to
  it) — per-instance channels (`onLive`, `onUpdate`, `logSink`) and the server's own counters
  only.
- CLISmokeTests runs the binary through a hard allow-list. A bare or unknown-arg-only
  invocation launches the live menu bar app; `--set`/`--print`/`--login` reach the Keychain
  or the account. Don't add an invocation without checking what it does signed-out and
  offline.
- New test files start with the two-line GPL header, and `prek run --all-files` must pass.

## The seams (how production code stays testable)

All default-parameter injection; the app's own wiring is untouched. `LevitonClient(configuration:)`
takes the URLProtocol stub. `DeviceStore(client:credentials:)` takes the fake Keychain
(`CredentialStore.swift`), plus `realtimeFactory` and two explicit seams
(`applyRealtimeForTesting`, `overrideLiveForTesting`) for paths only a live socket reaches.
`LevitonRealtime(session:deviceIds:url:)` takes the local server's URL, with instance
`pingInterval`/`pongTimeout`/`authBackoff`/`maxBackoff` knobs (set before `start()`; keep
`pongTimeout` strictly below `pingInterval` or the timeout never fires — each ping cancels
the previous deadline).

## Deliberately untested

The SecItem half of `Keychain.swift` (needs the owner's login keychain; the `CredentialStore`
seam is the compensation) · `StatusBarController`/`InternalsPanel`/`SignInDialog` beyond the
`--dump-*` smoke tests (`--dump-menu`/`--dump-internals` and the AX recipes in CLAUDE.md stay
the checks) · the updater (its own repo has the tests; `--check-update` needs GitHub) ·
drawing beyond "produces a real PNG" · the websocket against the real server (`--watch`).
