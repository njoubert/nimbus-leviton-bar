# LG webOS TV brightness: findings and implementation plan

Putting the LG OLED G5's brightness on the same menu as the Leviton dimmers, over the LAN, so the
lighting in a room is controlled from one surface. Investigated 2026-08-25 against leviton-bar 1.6.0 (commit
`014d218`) and an `OLED65G5WUA` on webOS 25; every probe result below was taken on that day
against that TV. Read the whole plan before starting — Phase 0 is a go/no-go gate and the
rest is void if it fails.

Rendered versions of this document, with diagrams:

- Findings — <https://claude.ai/code/artifact/53559878-dc3e-481e-b553-4a45e0180b0f>
- Plan — <https://claude.ai/code/artifact/454298bd-7cab-4df3-bd93-ab8093510067>

## Phase 0 result (2026-08-25): the native endpoint is closed, the bridge works

Run with [`spikes/lgtv`](../spikes/lgtv), which is committed and kept. Its README carries the
detail and the traps; this is the verdict.

| Path | Result |
|---|---|
| `ssap://settings/setSystemSettings` | **`401 insufficient permissions`**, as a string and as a number |
| `createAlert` → `onClose` → `luna://com.webos.settingsservice/setSystemSettings` | **works, and visibly** — `backlight` 100 → 20 plainly dimmed the panel and moved the TV's own Pixel Brightness slider |
| `getSystemSettings`, and subscribing to it | both work; the TV pushes partial updates unprompted |

**LG has closed the native write to third-party apps and left the bridge open**, and each link
was measured rather than inferred:

1. The canonical community manifest is refused outright — **`403 Pairing rejected: blacklisted
   certificate detected`**. LG has revoked the leaked `test-signing-cert` every client signs
   with. It cannot pair at all.
2. Dropping the `signatures` array pairs fine, but an unsigned app gets a fixed permission set
   that excludes `WRITE_SETTINGS`.
3. Hoisting `signed.permissions` to the top level changes nothing — `READ_UPDATE_INFO`, hoisted
   alongside as a control, still gives `401` on `getCurrentSWInformation`. The manifest's
   permission list is not the lever.
4. `WRITE_NOTIFICATION_ALERT` *is* granted, which is precisely why the bridge works.

So BetterDisplay does not use the bridge because it is old. It uses the bridge because it is
the only path there is, and the "prefer the native endpoint" decision below has no native
endpoint to prefer.

**This is the gate, and on its own terms it says stop.** Two things complicate that, and both
cut in favour of the bridge being better than the plan assumed:

- It wrote straight through **Filmmaker Mode**, which this document expected to lock the
  control. That trap is not real on this set.
- `externalpq` is still in the service list, and the set is on firmware **`43.21.71`**, which it
  reports as the latest available — so webOS 26 has not reached this television and is not being
  offered. Auto Update was turned off on 2026-08-25, so the timing of that door is ours.

The remaining question is therefore not technical but a build-vs-buy call on a single
unofficial mechanism — and **webOS 26 is no longer a differentiator in that call.** The options
table below scores durability as though building would get the native path; it would not. A
built version and BetterDisplay run on the *same* bridge and carry the *same* exposure. What is
left to weigh is whether one menu surface is worth the week, not whether it lasts longer.

## What this is for

**One surface for the lighting in a room.** The Leviton dimmers set the room's light; the TV's OLED
panel is the other large light source in it. Today, changing one means the menu bar and changing the
other means hunting for a remote. Putting both on the same menu *is* the feature.

That also fixes the scope: **brightness only.** No volume, no input switching, no power, no
transport controls — those are television features and this is not a television app. If a control
does not change the light in the room, it does not belong here.

Two systems, deliberately independent:

- **No following logic, and none in this plan.** The TV does not track the lights. The two stores
  do not know each other exists.
- **The strict boundary is what keeps that option open.** Making the TV follow the room is a
  plausible *later* enhancement and explicitly not committed. The cheapest way to keep it cheap is
  to not anticipate it: two clean stores with no knowledge of each other can be joined later by one
  small mediator, whereas a coupling baked in early cannot be taken out.
- **Latency is a non-issue at this shape.** A manual slider that commits on release and takes a
  round trip is exactly what the Leviton rows already do, and that has been fine in practice.
- **The macOS keyboard gap is a non-issue too.** F1/F2 driving TV brightness was never the point —
  that the TV happens to be this Mac's display is incidental to controlling a room's light.

### Deliberately out of scope

Recording these so they do not get re-litigated, and so nobody mistakes an omission for an oversight.

| Not doing | Why |
|---|---|
| TV brightness following the lights | A possible future enhancement, not committed. The independent-stores design is what keeps it cheap to add. |
| Volume, input, power, playback | Television features. This app is about the light in a room. |
| More than one TV | One set is the use case. The design does not preclude more, but nothing is built for it. |
| Calibration, picture modes, white balance | That is what bscpylgtv and ColourSpace are for, and webOS 26 is removing the endpoints anyway. |

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
| Product shape | **Two independent controls on one surface.** Brightness only; no following logic, no other TV controls. |
| Coupling | **None.** No file may name both vendors. A follower, if it ever happens, arrives later as a single mediator — not now. |
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
- **Discovery is cheap enough to do unconditionally, so do not cache the address.** Measured on this
  LAN 2026-08-25: `MX: 1` returns the first (and only) match in **112–311 ms**; `MX: 2` takes
  311–1302 ms, because responders randomise their reply across the window. The request is one 105-byte
  datagram out and one back. Connecting to a already-known address instead costs 2–17 ms for TCP and
  39–174 ms for the TLS handshake — so caching saves roughly 200 ms and buys two problems: a
  stale-cache path to test, and the case where DHCP has handed that address to something else and the
  app offers its client-key to a stranger. Discovering first means the UDN is verified *before* any
  credential is sent. One code path, always correct, ~200 ms.
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

**But it is not a substitute here** — it dims only *this Mac's output*, so a TV showing its own apps
or another input would still be flooding the room with light. If the goal is the light in the room,
hardware `backlight` is the only thing that works regardless of what is on screen.

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
```

Roughly +830 lines: 3,514 → ~4,350. One file refactored, none rewritten, no new dependencies.

### The boundary

**No cross-imports. None.** Nothing in `Leviton/` may name a type from `LG/` or the reverse, and no
third file may name both. If they need shared plumbing it goes in `Net/`, or it does not get shared.

This is the rule that would have to be relaxed to make the TV follow the lights, and relaxing it
later is a deliberate, reviewable act: one new file that imports both, and nothing else changes.
Anticipating it now would mean threading a coupling through code that does not need one.

The two vendors meet only in `StatusBarController.rebuild()` — already the single place the menu is
assembled — and in `Keychain`, and both meet them as strangers.

## Onboarding

Pairing is not signing in and the UI should not pretend otherwise. There is no password: the TV
shows a prompt and someone picks up the remote.

### How the discovery actually works (no scanning involved)

Nothing sweeps the address space — a `10.0.0.0/8` holds 16.7 million addresses and probing them
would take hours and look exactly like a port scan. SSDP sends **one** UDP datagram, 105 bytes, to
the multicast group `239.255.255.250:1900`:

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 1
ST: urn:lge:device:tv:1
```

`239.255.255.250` is not a host, it is a group address that SSDP-speaking devices have joined (via
IGMP) and are listening on. The network delivers the datagram to the group's members — flooded
across the broadcast domain, or on a switch doing IGMP snooping, only to ports that actually joined.
Everything whose device type matches the `ST:` header answers with a single **unicast** datagram
straight back to our source port; everything else stays silent. It is HTTP syntax over UDP, with no
connection and no handshake.

So the whole transaction is one datagram out and one back, which is what the measurement showed.

`MX: 1` is the response-spreading window: it tells responders to randomise their reply somewhere in
the next second, so a network with a hundred UPnP devices does not answer in one thundering
simultaneous burst. Because we filter to `urn:lge:device:tv:1` there is exactly one responder here,
so that spread buys us nothing and only adds latency — which is precisely why `MX: 1` measured
faster than `MX: 2`. It is also why the group address matters for scope: `239.0.0.0/8` is
administratively scoped and routers do not forward it off the local network without explicit
multicast routing, so this reaches the LAN and stops there.

This is the same mechanism behind Bonjour/mDNS (`224.0.0.251:5353`), and behind how AirPlay,
Chromecast and Sonos find each other.

1. **Discover, every time** — targeted SSDP `M-SEARCH` with `ST: urn:lge:device:tv:1`, matching the
   responder's UDN against the stored one, then connect to whatever address it answered from.
   **Use `MX: 1` and return on the first match**; do not wait out the window. No cached-address fast
   path — see the cost note below.
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

## Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| webOS 26 moves the ground | High | Prefer the native endpoint; capability-probe once per pairing and store what worked; on probe failure hide the TV section entirely rather than showing a dead control, and put the reason in the status row. |
| The native endpoint is unverified | High | Phase 0 exists solely to answer this from the CLI before any UI work. A genuine go/no-go gate. |
| Self-signed TLS means disabling verification | Medium | Scope the exception to the paired host and pin the cert on first pair. Use a **separate `URLSession`** for the TV so the delegate that accepts it can never see my.leviton.com or GitHub. Say so in README. |
| The TV is off most of the time | Medium | Model "off" as a distinct expected state with quiet presentation, **not** `.error`. Reconnect on wake via the existing `NSWorkspace` observer. Back off hard when simply absent. A TV in standby does not answer SSDP either, so treat "not discovered" and "not reachable" as one quiet state. |
| The extraction regresses working code | Medium | Extract with no behaviour change and prove it the way the bugs were originally found: `pongTimeout` to 0.0001, `pingInterval` to 5, run `--watch`, confirm one drop still schedules exactly one reconnect. Do it before any LG code exists so a regression has one possible cause. |
| Writing to a TV that is off | Low | Pointless at best and wakes the set at worst. Disable the row when the TV is not reachable rather than queueing writes for later. |
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
| 0 | ~~**Spike.**~~ **Done 2026-08-25** — `spikes/lgtv`, committed and kept. | ~1 day | **Native path refused, bridge works.** See "Phase 0 result" above; the build-vs-buy call is open. |
| 1 | **Extract `ReconnectingSocket`.** Pure refactor, no new features, no LG code. Commit separately so it can be reverted alone. | ~1 day | Forced-failure test passes and the app behaves identically. Ship before any LG code. |
| 2 | **`SSAPSession` + discovery + pairing, CLI only.** Socket, request correlation, cert pinning, register handshake, Keychain item, SSDP with manual fallback. | ~2–3 days | `--tv-set backlight 40` changes the panel and `--tv-watch` shows the TV's own change arriving. |
| 3 | **`TVStore`.** Main-actor state, optimistic writes with snap-back, capability probe, off/unreachable states, wake handling. | ~1–2 days | Mirrors `DeviceStore`'s patterns without sharing its code. |
| 4 | **The menu section.** One TV brightness row reusing `LevelControl`, and nothing else. Structural changes wait for the next open; values update in place. | ~1 day | The row moves the panel, and is disabled rather than misleading when the TV is unreachable. Verified with `--dump-menu` in both themes. |
| 5 | **Docs, prek, release.** README two services → three. CLAUDE.md gains an LG section with the traps above. | ~half a day | `prek run --all-files`, then `./build.sh release`. |

Phases 0 and 1 are independently valuable: 0 answers a question worth answering regardless, and 1
improves the existing code whether or not any LG work follows.

## Open questions

- ~~**Does this G5 accept the native `settings/setSystemSettings`?**~~ **Answered 2026-08-25: no** —
  `401 insufficient permissions`, because `WRITE_SETTINGS` is not granted to an app that cannot
  present a non-blacklisted signature. The luna bridge works. See the Phase 0 result above.
- Whether the luna bridge survives webOS 26. Reporting so far names only the calibration options
  as removed, and this set still exposes `externalpq`, so it has not arrived here yet. **Now the
  only open risk that matters.**
- ~~The set's current firmware version.~~ **`43.21.71`**, read off the television's own
  Support → Software Update screen, which also reports it as the latest available. Not readable
  over SSAP: `getCurrentSWInformation` needs `READ_UPDATE_INFO`, one of the permissions an
  unsigned manifest does not get.
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
