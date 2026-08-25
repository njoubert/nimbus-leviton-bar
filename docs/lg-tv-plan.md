# LG webOS TV brightness: findings and implementation plan

Adding brightness control for the LG OLED G5 that this Mac uses as its display, over the LAN,
to the same menu bar. Investigated 2026-08-25 against leviton-bar 1.6.0 (commit
`014d218`) and an `OLED65G5WUA` on webOS 25; every probe result below was taken on that day
against that TV. Read the whole plan before starting — Phase 0 is a go/no-go gate and the
rest is void if it fails.

Rendered versions of this document, with diagrams:

- Findings — <https://claude.ai/code/artifact/53559878-dc3e-481e-b553-4a45e0180b0f>
- Plan — <https://claude.ai/code/artifact/454298bd-7cab-4df3-bd93-ab8093510067>

## Decisions (settled — do not reopen)

| Question | Decision |
|---|---|
| Channel | **LAN, not HDMI.** LG televisions do not implement DDC/CI, and the M1 built-in HDMI port does not pass DDC cleanly either — two independent failures on the same wire. HDMI-CEC has no brightness opcode at all. |
| Protocol | **SSAP** over `wss://<tv>:3001`. Port 3000 is closed on this set; only the TLS port answers. |
| Endpoint | Prefer the **native** `settings/setSystemSettings`, which webOS v9 (2024) and newer expose directly. Fall back to the luna alert-bridge only if Phase 0 proves the native path does not work here. Never the `externalpq` calibration API — webOS 26 removes it. |
| The key to write | **`backlight`**, which on an LG OLED is "OLED Pixel Brightness". `brightness` is the black-level lift and is *not* what the user means. |
| Build vs. buy | Build only if Phase 0 says the native endpoint works. If it needs the luna bridge, use BetterDisplay (already installed, already does this) and abandon the rest of this plan. |
| App identity | **No rename.** Bundle id, Keychain service, Login Item registration, the updater feed and the DMG all key off `com.njoubert.nimbuslevitonbar`. Renaming mid-feature risks orphaning the Keychain items and every installed copy's update path. |
| Module layout | Folders inside the existing target (`Net/`, `Leviton/`, `LG/`), **not** a second SwiftPM package. Extract later if the SSAP client earns it the way `NimbusUpdater` did. |
| Store layout | **Two stores, never one.** Sign-in and pairing have different lifecycles, states and failure modes; a union type covering both would be larger and worse than two honest ones. |
| Default state | **Feature-dark.** No paired TV means no TV section, no discovery, no socket, no behaviour change for anyone who does not opt in. |

## Facts the design rests on

Probed live on 2026-08-25 from this Mac.

- The TV is `[LG] webOS TV OLED65G5WUA` at `10.10.3.230`, wired MAC `60:75:6c:9b:b9:d4`, Wi-Fi
  `f4:14:bf:43:01:e8` — **it answered from Wi-Fi**, so it is not on the wire it could be.
  SSDP reports `Linux/6.12.44-352` and `lglink/1.0`.
- macOS sees it as EDID `LG TV SSCR2`, `Television: Yes`, on a Mac Studio M1 Max (`Mac13,1`).
- **Port 3000 resets the connection; port 3001 completes a WebSocket upgrade.** Any tutorial
  using `ws://…:3000` is written for a 2014–2017 model.
- BetterDisplay 4.3.6 is installed on this Mac and already implements all of this. Its binary
  contains an `LGWebOSController`, `:3001`, `client-key`, `pairingType`, `com.webos.app.hdmi1..4`,
  and `"onClick": "luna://com.webos.settingsservice/setSystemSettings"` — i.e. it uses the
  **luna bridge**, not the native endpoint.
- There is **no official off-device API**. LG's Settings Service and Luna docs describe APIs for
  apps running *on* the TV; the ThinQ Open API does not expose picture settings. LG's own Connect
  SDK documents the WebSocket transport and PIN/prompt pairing but never names SSAP. Everything
  here is community reverse-engineering and can move under us.

### The three write paths, and why the native one matters

| Path | Endpoint | Applies to | Durability |
|---|---|---|---|
| Native SSAP | `settings/setSystemSettings` | webOS v9 (2024)+ — the G5 qualifies | Best bet; no hack involved |
| Luna bridge | `createAlert` with `onClick: luna://…` then `closeAlert` | Pre-2024 sets; what BetterDisplay uses | A privilege hack; unconfirmed past webOS 26 |
| Calibration | `externalpq/setExternalPqData` | `bscpylgtv set_oled_light` | **Being removed in webOS 26** |

webOS 26 is rolling out to 2025 models with the G5 first in line, and has already removed the
ColourSpace and bscpylgtv calibration options. That is the single biggest reason to prefer the
native endpoint and to probe capabilities rather than assume them.

### Traps (don't re-learn these)

- **`backlight`, not `brightness`.** See the decisions table. Getting it backwards looks like a
  broken API.
- **Energy Saving / OLED Care silently overrides a written `backlight`.** The write is accepted
  and then quietly reasserted — the same shape as the Leviton `presetLevel` trap, where the echo
  is not proof. Read back to verify.
- **Picture mode can lock the controls.** Filmmaker Mode and Dolby Vision in particular.
  BetterDisplay's own UI warns about it.
- **SSDP will not reliably cross this LAN's subnets.** It is multicast and this network spans many
  `10.10.x` ranges. A manual address entry is a first-class path, not an escape hatch.
- **Pair once, persist the key.** Never a pair per command — it puts a prompt on the television
  every time. Same discipline as `.leviton-session.json`.

## The four options considered

| Option | Real panel brightness | Effort | Survives webOS 26 | Verdict |
|---|---|---|---|---|
| BetterDisplay's webOS integration | Yes | Minutes | Luna bridge at risk | **Recommended today** |
| Build it (this plan) | Yes | ~1 week | Native path likely | Only if Phase 0 passes |
| Software dimming (gamma LUT) | No — gamma only | None | Unaffected | Useful *complement*, not a substitute |
| DDC/CI + HDMI-CEC | Not possible | — | — | **Dead end** |

Software dimming is orthogonal and can be layered on either: hardware `backlight` for coarse steps
(the ones that actually save power and panel life), gamma for instant fine adjustment, so a slider
feels responsive despite the round trip.

## Architecture

### The one refactor

`LevitonRealtime` already solves the hard part of talking to a device over a websocket, and none of
it is Leviton-specific: the generation counter, the one-drop-one-reconnect guard, the pong deadline,
the auth backoff, `reconnectNow()`. Extract that into `Net/ReconnectingSocket.swift` and let both
vendors sit on it. `LevitonRealtime` shrinks to protocol handling only (~276 → ~130 lines).

This is the *only* refactor in the plan. Everything else is additive.

### The transport asymmetry

Leviton has **two transports**: REST does every read and write, the websocket only pushes, and the
60 s poll is a real safety net. **SSAP has one** — reads, writes and subscriptions share the socket.
Two consequences, both new work:

- **Requests need id-correlation.** Every SSAP request carries an `id` and its response arrives
  asynchronously bearing it, so `SSAPSession` needs a pending-request table mapping id to
  continuation, plus a per-request timeout. `LevitonRealtime` never needed this — it fires
  subscriptions and forgets them.
- **There is no safety net.** Socket down means no reads *and* no writes, not merely stale data.
  The TV section needs an honest disconnected state, not a stale slider that silently does nothing.

### File organisation

Flat today; three folders make the boundary visible in the file tree. SwiftPM globs the target
directory recursively, so no build change is needed.

```
Sources/NimbusLevitonBar/
  main.swift                  + ~15   build TVStore, hand to StatusBarController
  CLI.swift                   + ~90   the --tv-* verbs
  StatusBarController.swift   + ~70   one section, one composition call
  MenuRows.swift              unchanged — LevelControl already does the slider
  Keychain.swift              + ~25   tvKeyAccount accessors
  Net/
    ReconnectingSocket.swift  NEW ~180  extracted from LevitonRealtime
  Leviton/                    moved, otherwise untouched
    LevitonClient.swift  LevitonRealtime.swift  DeviceStore.swift
    Devices.swift  DevCredentials.swift
  LG/
    SSAPSession.swift         NEW ~220  pair, request/response, subscribe
    SSAPDiscovery.swift       NEW ~90   SSDP M-SEARCH + manual IP
    TVStore.swift             NEW ~200  state, optimistic writes, capability probe
    TV.swift                  NEW ~60   the value type + picture settings
    TVPairingDialog.swift     NEW ~80   onboarding UI
```

Roughly +830 lines: 3,514 → ~4,350. One file refactored, none rewritten, no new dependencies.

### The boundary

**No cross-imports.** Nothing in `Leviton/` may name a type from `LG/` or the reverse. If they ever
need to share something it goes in `Net/`, or it does not get shared. The two meet only in
`StatusBarController.rebuild()` — already the single place the menu is assembled — and in
`Keychain`, and both meet them as strangers.

## Onboarding

Pairing is not signing in and the UI should not pretend otherwise. There is no password: the TV
shows a prompt and someone picks up the remote.

1. **Discover** — SSDP `M-SEARCH` for `urn:lge:device:tv:1`, with manual address entry alongside it.
2. **Connect** — `wss://<tv>:3001`, pinning the self-signed certificate on first pair (TOFU).
3. **Register** — send `{"type":"register", manifest: …}` with the permissions wanted.
4. **The TV prompts**; the user accepts with the remote.
5. **Store** — `{"type":"registered","client-key":…}` goes to the Keychain, never UserDefaults,
   never a log. Later launches send the stored key and get `registered` straight back, no prompt.
6. **Probe capabilities once** — read the picture settings back to learn which keys this firmware
   honours, and cache the answer. This is what lets the app degrade honestly later.

Surface the TV-side prerequisites in the pairing dialog: LG Connect Apps on, Energy Saving off. A
slider that moves and does nothing is the worst outcome available.

## Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| webOS 26 moves the ground | High | Prefer the native endpoint; capability-probe once per pairing and store what worked; on probe failure hide the TV section entirely rather than showing a dead control, and put the reason in the status row. |
| The native endpoint is unverified | High | Phase 0 exists solely to answer this from the CLI before any UI work. A genuine go/no-go gate. |
| Self-signed TLS means disabling verification | Medium | Scope the exception to the paired host and pin the cert on first pair. Use a **separate `URLSession`** for the TV so the delegate that accepts it can never see my.leviton.com or GitHub. Say so in README. |
| The TV is off most of the time | Medium | Model "off" as a distinct expected state with quiet presentation, **not** `.error`. Reconnect on wake via the existing `NSWorkspace` observer. Back off hard when simply absent. |
| The extraction regresses working code | Medium | Extract with no behaviour change and prove it the way the bugs were originally found: `pongTimeout` to 0.0001, `pingInterval` to 5, run `--watch`, confirm one drop still schedules exactly one reconnect. Do it before any LG code exists so a regression has one possible cause. |
| Product identity drifts | Medium | Do not rename (see decisions). Update README's service list from two to three, honestly. Treat renaming as its own migration, later or never. |

## Managing the complexity

Five rules keep a second vendor from infecting the first:

1. **No cross-imports**, enforced by review.
2. **One composition point** — `rebuild()`, above the first separator. Nothing else in the UI
   learns a second vendor exists.
3. **Feature-dark by default** — no paired TV, no new code paths at runtime.
4. **The CLI is the test harness, so extend it in step.** There are no unit tests here; `--print`
   and `--watch` are the correctness checks and they work because they exercise the real data path.
   `--tv-discover`, `--tv-pair`, `--tv-print`, `--tv-set` and `--tv-watch` land *with* the code
   they check, not after it.
5. **Two stores, never one.** Resist generalising `DeviceStore`.

## Sequence

| Phase | Work | Cost | Gate |
|---|---|---|---|
| 0 | **Spike.** Pair from a scratch script, read the picture settings, try the native endpoint, then the luna bridge. No app code, nothing committed. | ~1 day | **If neither writes `backlight` reliably, stop and use BetterDisplay.** The rest of this plan is void — a good outcome, cheaply reached. |
| 1 | **Extract `ReconnectingSocket`.** Pure refactor, no new features, no LG code. Commit separately so it can be reverted alone. | ~1 day | Forced-failure test passes and the app behaves identically. Ship before any LG code. |
| 2 | **`SSAPSession` + discovery + pairing, CLI only.** Socket, request correlation, cert pinning, register handshake, Keychain item, SSDP with manual fallback. | ~2–3 days | `--tv-set backlight 40` changes the panel and `--tv-watch` shows the TV's own change arriving. |
| 3 | **`TVStore`.** Main-actor state, optimistic writes with snap-back, capability probe, off/unreachable states, wake handling. | ~1–2 days | Mirrors `DeviceStore`'s patterns without sharing its code. |
| 4 | **The menu section.** One row group reusing `LevelControl`. Structural changes wait for the next open; values update in place. | ~1 day | Verified with `--dump-menu` in both themes. |
| 5 | **Docs, prek, release.** README two services → three. CLAUDE.md gains an LG section with the traps above. | ~half a day | `prek run --all-files`, then `./build.sh release`. |

Phases 0 and 1 are independently valuable: 0 answers a question worth answering regardless, and 1
improves the existing code whether or not any LG work follows.

## Open questions

- **Does this G5 accept the native `settings/setSystemSettings`, or does it still need the luna
  bridge?** This decides the whole plan. A read-only `getSystemSettings` answers it. Not tested —
  pairing puts a prompt on the owner's live display and was deliberately not triggered.
- Whether the luna bridge survives webOS 26. Reporting so far names only the calibration options
  as removed.
- The set's current firmware version. It reports a 6.12 kernel, which is recent, but that does not
  pin webOS 25 versus 26.
- The exact `betterdisplaycli` feature names on 4.3.6 — read from documentation and binary strings,
  not a live `--help`.

## Sources

The SSAP protocol:

- go-webos — message types, `ssap://` URIs, wss :3001, prompt vs client-key pairing:
  <https://pkg.go.dev/github.com/kaperys/go-webos>
- LG Connect SDK (WebOSTVService) — WebSocket transport and PIN/prompt pairing, no mention of SSAP:
  <https://connectsdk.com/en/latest/apis-ios/ios-webostvservice.html>
- webos-ssap-web — a browser SSAP client: <https://github.com/Informatic/webos-ssap-web>
- lgtv2 — the reference node implementation: <https://github.com/hobbyquaker/lgtv2>
- openlgtv hacking notes — SSAP vs luna, and the alert-bridge:
  <https://gist.github.com/Informatic/1983f2e501444cf1cbd182e50820d6c1>

Devices, tooling and firmware:

- BetterDisplay #4823 (LG picture controls): <https://github.com/waydabber/BetterDisplay/issues/4823>
- MonitorControl #1074 (LG C2 has no DDC): <https://github.com/MonitorControl/MonitorControl/issues/1074>
- bscpylgtv: <https://github.com/chros73/bscpylgtv>
- aiowebostv: <https://github.com/home-assistant-libs/aiowebostv>
- LG Settings Service docs: <https://webostv.developer.lge.com/develop/references/settings-service>
- webOS 26 rollout and calibration removal:
  <https://www.hdtvtest.co.uk/news/lg-starts-bringing-web-os-26-to-older-t-vs-starting-with-the-lg-g5-oled>
