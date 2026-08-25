# LG webOS TV brightness: findings and implementation plan

Making the LG OLED G5 follow the room lights — dim the Leviton dimmers and the TV dims with them,
over the LAN, from the same menu bar. Investigated 2026-08-25 against leviton-bar 1.6.0 (commit
`014d218`) and an `OLED65G5WUA` on webOS 25; every probe result below was taken on that day
against that TV. Read the whole plan before starting — Phase 0 is a go/no-go gate and the
rest is void if it fails.

Rendered versions of this document, with diagrams:

- Findings — <https://claude.ai/code/artifact/53559878-dc3e-481e-b553-4a45e0180b0f>
- Plan — <https://claude.ai/code/artifact/454298bd-7cab-4df3-bd93-ab8093510067>

## What this is for

Not a second vendor bolted onto a lights app. The product is a **follower**: dim the lights in the
room and the TV dims with them, so nobody reaches for the TV remote after every scene change. The
lights are the input, the TV is the output, and the feature is the link between them — not a second
slider.

That framing settles several things that would otherwise be open:

- **The primary UI is a link, not a TV control.** "Match TV to <room>" is the feature. A manual TV
  slider is a secondary convenience, worth having but not the point.
- **Round-trip latency stops mattering.** Nobody drags a TV slider waiting for it to catch up; the
  write happens in the background after a light change. "Control may be slow" is a real caveat
  against driving a TV by hand and barely applies to this shape.
- **The missing macOS keyboard integration stops mattering.** F1/F2 driving TV brightness was never
  the point — this is not a display-brightness feature, and the TV being this Mac's display is
  incidental to it.
- **The app stays the lights app.** It does not become a two-vendor platform, which reinforces the
  no-rename decision for a better reason than migration risk.

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
| Addressing | **Discover dynamically, key on the UDN**, cache the last address as a hint only. No DHCP reservation required — depending on router configuration for the app to work would be a design fault. Manual entry stays as a last-resort escape hatch. |
| Product shape | **A follower, not a second integration.** The TV tracks a Leviton room's level; a manual TV slider is secondary. |
| Coupling | One mediator, `Link/BrightnessLink.swift`, is the **only** file allowed to name both vendors. Neither store learns the other exists. |
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
- **Discovery is dynamic — no DHCP reservation needed.** The LAN is a single flat `10.0.0.0/8`, so
  multicast works: a targeted `M-SEARCH` with `ST: urn:lge:device:tv:1` returns exactly this TV
  (verified 2026-08-25, twice). **Persist the UDN, not the IP** —
  `uuid:74ee9ab1-f680-46b7-98b6-6f3f8f0c8b45` is the stable identity across DHCP changes; the
  address is only a cache hint. Note the DIAL service on the same TV advertises a *different* UUID,
  so match on the `urn:lge:device:tv:1` responder specifically.
- **SSDP only answers while the TV is awake**, which is also the only time it is controllable — so
  that is coherent rather than a gap. Waking a TV that is off is Wake-on-LAN with the stored MAC
  (an L2 broadcast, needing no IP at all), and it must first be enabled under
  Settings → Support → IP control settings.
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
(the ones that actually save power and panel life), gamma for instant fine adjustment.

**For the follower, though, software dimming is largely useless** — it dims only *this Mac's
output*, so a TV showing its own apps or another input would not follow the room lights at all.
Hardware `backlight` is the only option that works regardless of what the TV is showing. That is a
point in favour of building this rather than settling for gamma.

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
    SSAPDiscovery.swift       NEW ~90   M-SEARCH, UDN match, cached-address fast path
    TVStore.swift             NEW ~200  state, optimistic writes, capability probe
    TV.swift                  NEW ~60   the value type + picture settings
    TVPairingDialog.swift     NEW ~80   onboarding UI
  Link/
    BrightnessLink.swift      NEW ~120  the follower: room level → TV backlight, debounced
```

Roughly +950 lines: 3,514 → ~4,470. One file refactored, none rewritten, no new dependencies.

### The boundary

**No cross-imports between vendors.** Nothing in `Leviton/` may name a type from `LG/` or the
reverse. If they need shared plumbing it goes in `Net/`, or it does not get shared.

The follower needs *something* that knows both, so confine that rather than forbid it.
`Link/BrightnessLink.swift` is the single file in the app permitted to import both: it observes
`DeviceStore` and writes through `TVStore`, and neither store learns the other exists.

```
Leviton room level ──▶ BrightnessLink ──▶ TVStore.setBacklight
                       (mapping + debounce)
```

Otherwise the two vendors meet only in `StatusBarController.rebuild()` — already the single place
the menu is assembled — and in `Keychain`, and both meet them as strangers.

## Onboarding

Pairing is not signing in and the UI should not pretend otherwise. There is no password: the TV
shows a prompt and someone picks up the remote.

1. **Discover** — targeted SSDP `M-SEARCH` with `ST: urn:lge:device:tv:1`, matching the responder's
   UDN against the stored one. On reconnect, try the cached address first with a short timeout and
   only fall back to multicast when it fails; that keeps the common case off the network entirely.
   `MX: 2` means responders randomise their reply within two seconds, so return on first match
   rather than waiting the full window.
2. **Connect** — `wss://<tv>:3001`, pinning the self-signed certificate on first pair (TOFU).
3. **Register** — send `{"type":"register", manifest: …}` with the permissions wanted.
4. **The TV prompts**; the user accepts with the remote.
5. **Store** — `{"type":"registered","client-key":…}` goes to the Keychain, never UserDefaults,
   never a log. Later launches send the stored key and get `registered` straight back, no prompt.
   Alongside it record the **UDN** (identity), the **MAC** from the device description
   (`wiredMac`/`wifiMac`, for Wake-on-LAN) and the **last-known address** (a hint). Only the
   client-key is a secret; the rest can live in UserDefaults.
6. **Probe capabilities once** — read the picture settings back to learn which keys this firmware
   honours, and cache the answer. This is what lets the app degrade honestly later.

Surface the TV-side prerequisites in the pairing dialog: LG Connect Apps on, Energy Saving off. A
slider that moves and does nothing is the worst outcome available.

## The mapping is a product decision

A room at 40% does not mean a TV at 40%. Dimmer percentage and OLED pixel brightness are different
perceptual scales, and a TV at 0 is not what anyone wants when the lights go out. Starting policy,
to be tuned by eye:

- **Clamp to a usable band** — map onto roughly TV 15–100 rather than 0–100, so the TV never goes
  unwatchably dark and never jumps to full blast.
- **Linear within the band** to begin with. Add a curve only if it looks wrong in the room.
- **Lights fully off is the interesting case.** A dark room wants the TV *dimmer*, not off — the
  bottom of the band, not zero.
- **Which room?** The one the TV is in. Leviton already models rooms and their display order, so
  this is a pick-list rather than new modelling.

**Needs a decision before Phase 4.** Nothing before that depends on the answer.

## Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| webOS 26 moves the ground | High | Prefer the native endpoint; capability-probe once per pairing and store what worked; on probe failure hide the TV section entirely rather than showing a dead control, and put the reason in the status row. |
| The native endpoint is unverified | High | Phase 0 exists solely to answer this from the CLI before any UI work. A genuine go/no-go gate. |
| Self-signed TLS means disabling verification | Medium | Scope the exception to the paired host and pin the cert on first pair. Use a **separate `URLSession`** for the TV so the delegate that accepts it can never see my.leviton.com or GitHub. Say so in README. |
| The TV is off most of the time | Medium | Model "off" as a distinct expected state with quiet presentation, **not** `.error`. Reconnect on wake via the existing `NSWorkspace` observer. Back off hard when simply absent. A TV in standby does not answer SSDP either, so treat "not discovered" and "not reachable" as one quiet state. |
| The extraction regresses working code | Medium | Extract with no behaviour change and prove it the way the bugs were originally found: `pongTimeout` to 0.0001, `pingInterval` to 5, run `--watch`, confirm one drop still schedules exactly one reconnect. Do it before any LG code exists so a regression has one possible cause. |
| The link fights the user | Medium | If someone dims the TV with the remote, the next light change must not stomp it. A manual TV change **suspends the link** until the TV is next powered on, or until the user re-links explicitly. An argument the app always wins is worse than no feature at all. |
| Write amplification | Medium | A dimmer sweep from a wall switch or the phone app arrives as a stream of realtime pushes, and naively each one would be a TV write. Debounce and coalesce in `BrightnessLink` — settle for ~300 ms, then write once. Leviton's own slider already commits on release only, but no other source does. |
| Writing to a TV that is off | Low | Pointless at best and wakes the set at worst. Only write when the TV is on; drop the update rather than queueing it. |
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
| 4 | **The link and the menu.** `BrightnessLink` with its mapping and debounce, the "Match TV to <room>" control, and a manual TV row reusing `LevelControl`. Structural changes wait for the next open; values update in place. | ~2 days | Dimming the room dims the TV once, at a sensible level, and adjusting the TV by remote stops it fighting back. Verified with `--dump-menu` in both themes. |
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
