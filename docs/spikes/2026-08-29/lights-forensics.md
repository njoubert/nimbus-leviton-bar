# Lights that fight back — forensic notes

Started 2026-08-29. Suspects at the outset: Alexa (skill and/or Matter), the new Scenes,
this app on 4 machines, Leviton itself, the new dimmers' own hardware/wiring. By mid-day
the observations split into **two distinct issues**:

1. **Laggy, inconsistent scene fan-out** — CONFIRMED, many captures. A scene's commands
   reach devices over seconds, unordered against later input: stragglers 6–17 s late
   (Office Ceiling caught three times receiving the *previous* scene's value after a newer
   scene had set it; the owner has seen the same lag on other devices), and two scenes
   fired seconds apart leave the house in a mix until something re-asserts. Leviton's
   scene implementation is simply weak. This explains "scenes feel flaky" — and *could*
   explain a fight only when a scene ran seconds earlier, which is not what the owner saw.
2. **The direct fight** — NOT yet reproduced under instrumentation. The owner's precise
   description: press the paddle off (Kitchen Ceiling / PH Mini, walking out), the light
   fades **all the way off, then immediately bounces back to its previous ON state** — as
   if something were *monitoring* the switch and reacting to the off event. Last seen the
   night of 2026-08-28 (~23:30, per PH Mini's record); the last scene run was many minutes
   earlier, so issue 1's stragglers do not obviously explain it. Only the phone app made
   the lights stay off.

## Ruled out (2026-08-29)

- **This app.** Every write call site in `DeviceStore` / `StatusBarController` / `CLI`
  traces to a human gesture (menu click, slider drag, CLI command). Nothing writes on a
  timer, in reaction to incoming state, or as a delayed retry. The 60 s poll is read-only.
- **Leviton cloud automations.** All four `residentialSchedules` are disabled; no activity
  has `onHomeId`/`onAwayId` (geofence); `random`/`isRandomEnabled` (vacation mode) and
  `autoOffTime` are off on every device; no room scenes exist.

## The decoder ring: who changed a device

Two markers, calibrated live (see also CLAUDE.md's forensics bullet):

1. **`client_id` in the realtime frame.** A `saved` notification caused by a *public-API*
   write (the phone app, this app, a scene execute) carries the writer's `client_id` in
   `data`. The device's own report carries none — and neither does an Alexa command, by
   either path: the skill writes through an internal Leviton channel. Verified 2026-08-29
   with a no-op `PUT {"power":"OFF"}` (id present) and a voice-commanded ON of the
   non-Matter Bookcase (id absent).
2. **`IotSwitch.chgReason`.** A cloud PUT sets it to 3; devices last touched at the wall
   read 1 (inferred from house patterns, not yet provoked deliberately). **Caveat:** the
   cloud's copy can be *stale* — it only updates when the device re-reports the field, and
   PH Mini (firmware 1.0.0, the odd one out) has been seen changing power without
   re-reporting `chgReason`. Trust a chgReason only when a frame carrying it arrived with
   the change. The PUT *echo* also reports the pre-change value — same echo-lies trap as
   `presetLevel`.

A third marker (2026-08-29 08:36 session): **`rssi` in the frame separates the two kinds
of `saved` notification.** A *cloud record write* (the server updating its own copy before
or without the device confirming) has no `rssi`; the *device's own report* always carries
one. Call them `cld` and `dev`. So for any suspicious ON in the log:

| frame | meaning |
|---|---|
| `cld` write with `client_id` | a direct public-API PUT: the My Leviton phone app, or this app. Compare the id against a deliberate write of ours to tell the two apart. |
| burst of `cld` writes across the residence, **no** `client_id` | the server fanning out a **scene/activity execution** — whatever triggered it (a D2SCS scene button, this menu, the phone app). The trigger shows separately: a button is a `btnPress` dev report from the controller a few ms earlier. |
| `dev` report, fresh `chgReason` **1** | **the paddle** — verified 2026-08-29 08:36:59–08:37:40: four deliberate wall-offs each reported `chgReason` 1 inline. |
| `dev` report with **no** preceding `cld` write | a command that never touched the Leviton cloud's write path: **Alexa** (skill — verified 08:15:29 with a voice-commanded ON of the non-Matter Bookcase, which produced exactly one `dev` frame — or Matter-local) — **or a paddle press whose chgReason didn't change**. Dev reports are deltas: absent chgReason = unchanged, so only a chgReason *transition* discriminates. A `chgReason` 3 arriving in the frame = remote, confirmed; a 1 = paddle, confirmed; nothing = check what chgReason last was. |
| `chgReason` **6** | OTA / reboot (observed on PH Mini's 2026-08-29 firmware update). |
| `chgReason` **2** | **a companion press** — the DD00R-DLZ on Hallway Track's 3-way commanding its D36HD (owner-confirmed, 09:49:59). Its frame had no `rssi`, proving dev reports don't always carry one: `rssi` present ⇒ dev, but absent ⇏ cld. (The `companions` array stays empty for wired DD00Rs — it lists wireless companions only.) A paddle press on a device whose state *and* chgReason are both unchanged produces **no frame at all** — silence there is not a gap in the tape. Matter's own code remains uncalibrated. |

"Fresh" means the device's `lastUpdated` matches the change to the second — the cloud's
`chgReason` only moves when the device re-reports it, so an unmatching timestamp means the
value is stale and says nothing about this change.

**The important negative result:** the Alexa *skill* writes through an internal Leviton
channel, not the public API — its commands carry **no** `client_id`. So the earlier
2026-08-29 08:08 PH Mini event (voice command, no `client_id`) proves an Alexa command but
**not** which path it took; and removing the Matter pairing would not make Alexa visible in
the log by `client_id`. The paddle-vs-remote split rests on `chgReason` 1 vs 3.

## The Matter map (read 2026-08-29)

Only the seven D36HDs are Matter devices; nothing else on the account carries a Matter
identity (`matterQRCode` null). Six are joined to an **Amazon fabric** (vendor 4631) —
an Echo can command them locally, invisibly to my.leviton.com:

| device | firmware | Matter fabric |
|---|---|---|
| Dining Room Ceiling, PH5, Entrance Track Lights, Living Room Ceiling, Hallway Track Lights, Kitchen Ceiling | 1.0.15 | Amazon (4631) |
| PH Mini | **1.0.0** (behind) | vendor 0 — but **live**: Alexa commands it over Matter, so this is the Amazon pairing misreported by the old firmware |
| everything else (DW3HL, DW15P, D215P, D23LP, D26HD, D2SCS) | — | not Matter-capable |

They most likely joined the Amazon fabric via Alexa's Frustration-Free/Simple Setup during
the Aug 22–24 installs — no step in My Leviton shows it. Check the Alexa app for each
dimmer appearing **twice** (once "Leviton" skill, once Matter).

**To leave the Matter fabric:** in the Alexa app, open the Matter copy of the device
(Devices → the dimmer → gear; "Connected Via" distinguishes the copies) and delete it —
Alexa, as fabric admin, removes its entry from the dimmer. Verify with
`--get IotSwitches/{id}` → `matterFabric` should come back empty. A factory reset of the
dimmer also clears all fabrics, but costs a re-enrollment. Alexa keeps controlling every
device through the My Leviton skill either way — note the skill's writes are *also*
invisible in the log (no `client_id`; see the decoder), so unpairing doesn't improve
observability. It is still the cleanest experiment: if the fighting stops with the Matter
pairing removed, the Matter path was the culprit; if it continues, the skill or the
hardware is.

## The tripwire

A timestamped capture of the realtime feed, so the next occurrence is attributable. Since
2026-08-29 ~08:26 PT it is the CLI's own **`--journal`** mode, added for this spike (it
replaced a nohup'ed shell pipeline around `--watch`; the log's earlier lines carry that
pipeline's `[realtime]` prefix and second-granularity stamps — same content):

```sh
cd ~/Code/nimbus-leviton-bar
nohup .build/debug/NimbusLevitonBar --journal dist/leviton-watch.log >/dev/null 2>&1 & disown
```

- Log: `dist/leviton-watch.log` (gitignored with the rest of dist/). Local time, ms.
- Alive? `pgrep -f 'NimbusLevitonBar --journal'`. Growing? `tail dist/leviton-watch.log`.
- Stop: `pkill -f 'NimbusLevitonBar --journal'`. It does **not** survive a reboot — and
  `./build.sh stop` / `install` kill it too (they match on the process name) — restart it
  with the command above (or promote it to a LaunchAgent if this drags on).
- It reads the CLI's cached session; it never writes to a device.

**When a light fights back:** note the light and the clock time, then

```sh
grep '<HH:MM>' dist/leviton-watch.log | grep notification
```

and read the ON against the decoder table above.

## Timeline of observations

- 2026-08-29 07:15:26 — Hallway Track Lights ON at preset 30. **Confirmed: the owner,
  at the wall.**
- 2026-08-29 07:53 & 07:55 — calibration no-op OFF writes to PH Mini (ours, expected).
- 2026-08-29 08:08:00 — PH Mini ON at 40%, frame without `client_id`. **Confirmed: the
  owner, by voice command to the living-room Echo Dot.** An Alexa command with no
  `client_id`; whether it travelled via the skill or Matter is undetermined (both are
  invisible the same way — see the decoder's negative result).
- 2026-08-29 08:12:55–08:13:15 — PH Mini OTA (owner-initiated): `apply_ota` 2, then the
  device back at **version 1.0.15**, `chgReason` 6, and `matterFabric` now correctly
  reporting **Amazon (4631)** — the old 1.0.0 firmware had misreported it as vendor 0.
- 2026-08-29 08:15:29 — Bookcase (DW15P, no Matter) ON, frame without `client_id`, fresh
  `chgReason` 3. **Confirmed: the owner, voice command via Echo Dot — the Alexa-skill
  calibration.** Skill writes carry no `client_id`.
- 2026-08-29 08:36:48–08:37:41 — the owner's wall-controls session. What it established:
  - **The D2SCS (Countertop) scene buttons fire activities server-side**: a `btnPress`
    dev report (`[{button:N, trigger:1}]`), then the cloud fans the mapped activity out
    ~30 ms later. Button 1 = Morning, button 2 = Early Evening on this account.
  - **Paddle calibration done**: four wall-offs (Kitchen Ceiling ×2, PH Mini ×2) each
    reported `chgReason` 1 inline, dev frame. The decoder's last row is verified.
  - **Rapid scene-on-scene is a race the devices lose**: Morning then Early Evening fired
    1.1 s apart (08:36:48/49) left the house in a *mix* — several devices' own reports
    (Lounge, Hallway, Dining, PH5, Living Room, Office Ceiling) settled on the *first*
    scene's state seconds after the second scene's `cld` writes, and one straggler `cld`
    write (Office Ceiling OFF, 08:37:32.771) landed 6 s after its scene. Fan-out delivery
    lags seconds and is not ordered against a second execution.
  - The re-ONs at 08:37:20.4/21.4 (PH Mini, Kitchen Ceiling, both to 100) were **the
    owner double-tapping the paddles** — no fight occurred; the whole session was "last
    input wins". Their frames carried no `chgReason` because it was *still* 1 from the
    wall-offs seconds earlier: **dev reports are deltas — an absent field means
    "unchanged since the last report", not "unknown"**. So a paddle press that repeats
    the previous chgReason is indistinguishable from an Alexa command by chgReason alone;
    only a chgReason *transition* (3→1 or 1→3) shows up in the frame.
  - **No fight was provoked** — scene buttons, rapid scene successions, immediate
    wall-offs, double-taps: every final input won.
- 2026-08-29 08:48:08–08:49:49 — menu-fired scene rounds (all owner actions, confirmed).
  Learned: a scene fired from this app's menu produces the **identical `cld` burst
  signature** as a wall-button scene — no `client_id` on fan-out either way; only the
  preceding `btnPress` dev report marks a wall button. Stragglers #2 and #3 caught on
  Office Ceiling (08:49:00, 08:49:34 — the second reversing a 2 s-old Morning value with
  Deep Evening's OFF). Every wall-off and re-ON in the window was the owner's paddling.
- 2026-08-29 08:56:06–17 — the whole house came ON at ~100 % as **dev reports only** — no
  `cld` writes, no `btnPress`, old skill-only DW3HLs included: the signature of an
  Alexa-side all-on (presumed owner-initiated; unconfirmed). Notably Kitchen Ceiling was
  *not* in the wave.
- 2026-08-29 09:29:08–16 — a turn-everything-off pass (owner activity, details
  unconfirmed): Living Room Ceiling + Entrance Track off 164 ms apart with `chgReason` 1
  (a two-paddle swipe on one box, or Matter — never calibrated apart); PH Mini +
  Kitchen Ceiling off 96 ms apart with **no chgReason transition off a prior 3** — a
  *network* off that skipped the Leviton cloud (an Alexa "kitchen off"?); PH5 +
  Dining Ceiling with `chgReason` 1, 18 ms apart (a 2-gang swipe). Then the standout:
  **09:29:16.347, PH5 reported `chgReason` 1→3 — a network command touched it 0.8 s
  after its paddle event** — no `cld` write, no power change, nothing else touched. That
  is the first captured instance of something *reacting* to a paddle within a second,
  exactly the "something is monitoring this switch" shape, just with a harmless no-op
  this time. Prime interpretation: **Alexa's duplicate-copy state sync** — the Matter
  copy reports instantly, Alexa compares against its (Leviton-skill-fed, laggy — issue 1)
  copy of the same light, and pushes its own belief back down. When the skill copy is
  stale-ON (a scene ran via the cloud; Leviton reported it slowly or not at all) and the
  paddle goes off, the "correction" would be the fight: an immediate ON. The two issues
  would then be one root cause — Leviton's laggy state propagation — amplified by the
  dual Alexa pairing.
- Bamboo Lamps (649819) flaps connected/disconnected all morning — and Blue Lamp (649817)
  joined it by midday. Diagnosed 2026-08-29 with the owner's UniFi console: an
  **asymmetric link** — the AP hears the dimmers at −59/−62 dBm (looks healthy in UniFi)
  while the dimmers themselves report hearing −69…−82, with "AP/Client Signal Balance:
  Poor" and a 1 Mbps client TX rate. What flaps is the **cloud TLS session** (missed
  keepalives during loss bursts), not the Wi-Fi association, which is why UniFi sees
  nothing. Both associate to the bedroom AP; steering them closer / checking Min-RSSI are
  the knobs. Relevance: lossy links on scene members feed issue 1's stragglers.
  Root cause found on the AP's air stats: **2.4 GHz channel 1 at 90 % Busy utilization**,
  19.6 % TX retries (28 % in samples) — airtime starvation; the spectrum waterfall showed
  channels 1–6 saturated, 7–13 clean. **2026-08-29 11:49 PT the owner moved 2.4 GHz to
  channel 11 and raised TX power to High** (High is correct here: the journal proved the
  *downlink* is the weak leg — dimmers hear −70…−82 while the AP hears them at −59/−62).
  Every device bounced at 11:49 (expected). Pre-change flap baseline 07:54–11:49: Blue
  Lamp ×2, Table Lamp ×1, plus PH Mini's OTA reboot. ⚠ Two treatments changed today
  (Alexa room fixes + RF) — attribute by shape: the instant wall-fight was never
  RF-shaped, so its disappearance credits the Alexa cleanup; fewer stragglers credits
  the channel move. RF resolution, ~12:15 PT: both lamps steered to the bedroom AP
  (High power had lured them to the farther living-room AP) — Blue Lamp −70 → **−48**,
  both showing full bars in the My Leviton app; owner plans to replace the two DW3HLs
  with current-gen plug-ins anyway (enroll Leviton-only, no Matter pairing, until the
  fight investigation closes).

- 2026-08-29 09:36:00–02 — Deep Evening fired from the menu (protocol step 1), and
  **PH5 was reversed 1.7 s after the scene commanded it ON 15**: exactly two frames — the
  scene's `cld` ON, then a dev report OFF with chgReason *staying* 3 (network-class; a
  paddle would have reported the 3→1 transition), no `cld` write behind it, no
  `btnPress`. **Owner confirms: fired the scene from this app's menu and touched nothing
  else, and PH5 visibly ended NOT at its scene level — a captured non-human reversal.**
  The tape rules out: a paddle, a scene button, and the Leviton cloud (every
  Leviton-cloud command observed writes the record first). What remains is a network
  actor outside the Leviton write path — and both of Alexa's paths look exactly like
  this (the skill, per the 08:15 Bookcase calibration, writes no record either; Matter
  is local) — so: **Alexa turned PH5 off, path unknown**. The duplicate-copy sync theory
  fits every beat: since 09:29 both Alexa copies of PH5 believed OFF; the scene's ON
  reached the Matter copy instantly while the skill copy lagged; Alexa reconciled to its
  stale state; after its OFF both copies agreed, hence the single clean reversal and no
  further fighting. Attribution to a named actor (dup-sync vs Hunch vs routine) needs
  Alexa's own Activity log at 09:36, or the Matter-unpair A/B.

- 2026-08-29 09:41:18–:21 + 75 s — the faithful walk-out test (Deep Evening at 09:36,
  5 min wait, both kitchen paddles off from dim levels): **clean null.** Two `chgReason` 1
  offs and then silence — no re-ON, no poke, no `cld` write. Eight instrumented wall-offs
  today, all unfought. The wall fight seems to need Alexa holding a stale *opposite*
  belief at press time (as it did for PH5 at 09:36), not merely a paddle event. Fight
  nights cluster ~23:30 — also prime time for Alexa's autonomous night behaviours.
  Revised plan: stop chasing the wall fight; the 09:36 setup is repeatable on demand —
  device off ≥ 5 min → scene-ON → hands off = one trial against the fighter. Get a
  reversal rate over several trials, then **unpair Matter for PH5 only** (others stay
  paired as controls) and re-run the trials.

- 2026-08-29 ~10:00, Alexa-side findings (owner, in the app): no Hunches or Routines
  visible. The new D36HDs sit in a **"finish this setup please…"** stage — Amazon's
  Frustration-Free Setup evidently wrote its fabric onto the dimmers (hence
  `matterFabric` 4631) but the commissioning was never completed. PH5 showed **one**
  device entry ("Connected Via: Leviton Manufacturing Co Inc" — the skill; Alexa merges
  or hides the Matter copy), typed as a **"switch" not a "light"**, and auto-assigned to
  **"Niels' Room"** — the *wrong* room (FFS assigns a new device to the discovering
  Echo's own group, not Leviton's room). Owner corrected PH5 to Light / Dining Room and
  completed its setup — note this changes PH5's baseline for all later trials.
  - **Why wrong rooms are dangerous**: an Echo's room group is the target of "turn
    off/on the lights" in that room *and* of the Echo's ultrasound presence features
    ("lights on when presence detected", auto-off when empty — per-Echo Motion settings,
    not listed under Routines/Hunches). A dimmer mis-grouped into an Echo's room gets
    commanded whenever that Echo acts on "its" lights. **Presence-based light-on fits the
    wall fight exactly**: press off while still standing in the room → the Echo, seconds
    later, sees presence + lights out → lights back on. "Something is monitoring the
    switch" — an ultrasound presence sensor genuinely is.
  - Checks this implies: each kitchen D36HD's Alexa room assignment; each Echo's
    Settings → Motion/ultrasound detection and any connected-lights automation; the
    smart-home action history (not in the app's main nav — Alexa Privacy → "Review Smart
    Home Devices History", or amazon.com/alexaprivacysettings) for 09:36 and for the
    ~23:30 fight window of 2026-08-28.
- 2026-08-29 ~10:20–11:10 — the owner audited every light in the Alexa app: **almost all
  lights were assigned to "Niels' Room"**, several never set up, types wrong. Fixed one
  at a time, toggling each as they went — which retroactively explains every "mystery"
  event of the late morning (the 10:22 and 10:55 blips, PH5's 10:50–54 network pair, the
  11:00–11:03 "sweep"): all audit toggles. **Leading fight theory as of noon**: with the
  kitchen dimmers secretly in "Niels' Room", any bedtime room-scoped lights action near
  the bedroom Echo commanded the kitchen too — the walk-out paddle-off at ~23:30 collides
  with a bedroom "lights" action seconds later, and the kitchen comes back on. Onset,
  nighttime clustering, D36HD-only scope and the app-off-sticks asymmetry all fit. The
  re-rooming is therefore the candidate **cure**; tonight's bedtime is the natural test,
  with journal + monitor armed. The 09:36 PH5 reversal remains the day's only confirmed
  autonomous Alexa action.

- 2026-08-29 ~11:30, the Amazon smart-home ledger (owner printed
  `2026-08-29-morning-amazon.com_alexa-privacy_apd_dsh.pdf` into this directory, and later
  `2026-08-28-evening-…` with yesterday expanded — **both gitignored: they carry account
  PII and the repo is public**). It is state-only, minute-granularity, no
  attribution, and only Today was expanded (the ~23:30 fight window of 2026-08-28 sits in
  the collapsed "Yesterday" accordion — re-print with it expanded). Four findings:
  1. **PH5's entire 9:36 pair is missing.** Every other Deep Evening state change (Kitchen
     16, PH Mini 40, Hallway 23, Dining 15, Entrance 15, the Turned Ons) appears at 9:36 —
     PH5's On and its 1.7 s reversal both do not. Alexa's skill-side belief therefore
     stayed "PH5 off since 8:48" through the event: exactly the stale-belief precondition
     the duplicate-copy reconciler theory needs (its Matter copy saw the ON instantly;
     its skill copy never did). Consistent with the theory, not yet probative.
  2. Alexa's device is named **"Hallway Track Lights 2"** — a numbered suffix implies a
     departed or coexisting "Hallway Track Lights" #1: duplicate-entry residue.
  3. A device logged as **"Device Name N/A" turned on and off at 6:40 AM** (and
     repeatedly through the evening of 08-28, incl. ON at 11:25 PM). Resolved ~12:30 PT:
     the owner found no such device but purged **orphaned Alexa entries left over from
     the trashed pre-D36HD dimmers** (plus unneeded devices like printers) — and the
     history page resolves names at view time, so "N/A" is precisely how an orphan
     renders. The N/A actor is presumed one of those orphans, now deleted. Third
     treatment applied today: Alexa device purge.
  4. The Entrance 10:21–22 "blip" appears as an interactive dimming session
     (0→10→15→off→9→4→15) — corroborates the owner's app-audit account, and the
     "Bamboo Lamps endpoint health not reachable/OK" cycles corroborate our Wi-Fi-flap
     observations. (The "Core 600S" entries are speakers, unrelated.)

- The 2026-08-28 evening ledger (second PDF): the fight window shows **Kitchen Ceiling
  "Turned Off 11:26 PM" and PH Mini "Turned Off 11:31 PM" — and no bounce-back Ons at
  all.** Leviton never reported the fight's re-ONs to Alexa (the same skill-reporting
  lossiness as PH5's invisible 9:36 pair), so the ledger cannot attribute the fight.
  Two real finds instead:
  1. **"Device Name N/A" toggled all evening in lockstep with the scene waves** — on/off
     at 9:29, 9:33, 10:24, 10:59 PM — and its last logged state was **ON at 11:25 PM,
     one minute before the kitchen shutdown that began the fight**. Also active 6:40 AM
     and 9:29/9:33 today. An unnamed entity that participates in scenes: tap its card in
     the history (it links to the device) or hunt the Alexa device list for a nameless
     entry. Prime candidate for a half-commissioned Matter shadow or an orphaned entity
     from the replaced dimmers.
  2. **Two overlapping house-wide dim waves at 10:59 PM** — one setting ~everything to
     brightness 30, another to 40, in the same minute. Either the owner raced two scenes
     again, or two automations fired together; the owner should say what they did at
     10:59.

## Alexa-side checks (only doable from the phone)

- More → Activity: does Alexa log the mystery ONs?
- Routines: anything with a smart-home state trigger; Hunches ("auto-act on hunches");
  Guard / Away Lighting.
- Device list: duplicate copies of the D36HDs (skill + Matter).

Leviton's own article for this symptom class ("Lights are randomly turning on/off with no
schedule configured", decorasmartsupport article 1260803964990) prescribes: update
firmware, factory reset, re-add. ~~PH Mini being on 1.0.0 while its siblings run 1.0.15 is
worth fixing regardless~~ — done, owner updated it 2026-08-29 08:13.

## Next steps

1. ~~Calibrate the paddle~~ — done, 2026-08-29 08:36–08:37: four wall-offs, `chgReason` 1
   inline every time.
2. ~~Hunt the straggler~~ — issue 1 is confirmed (three captures on Office Ceiling, more
   seen by eye on other devices); the longest straggler on tape remains 17 s. A related
   failure mode was measured 2026-08-29 ~12:08: a PUT to Blue Lamp mid-Wi-Fi-bounce was
   **lost, not queued** — the cloud wrote its record (OFF) but the device never applied
   it, and the device's post-reconnect resync overwrote the record with its own truth
   (ON). (A 12:10:37 OFF first read as a minutes-late replay was in fact the owner at
   the lamp — retracted.) So commands to mid-reconnect devices silently vanish, and the
   cloud believes them until the resync; scenes hitting flappy members lose actions
   outright.
3. **Reproduce the fight under last night's conditions** — the untested variable is the
   *starting level*. Every instrumented wall-off today started from 100 %; the fight
   nights start from a dim evening scene (Deep Evening kitchen = 15–16 %, Movie Night
   PH Mini = 20 %). Protocol: run Deep Evening, wait ≥ 5 min (mirror the real timing),
   then walk out pressing Kitchen Ceiling and PH Mini off — and hands off afterwards.
   The journal plus the live monitor catch any bounce; the decoder then splits it: a
   `cld` write just before the re-ON = Leviton; a bare dev report = Alexa-via-Matter
   reacting to the off event (sub-second subscription latency matches the "something is
   monitoring this switch" feel) or the dimmer's own firmware/load behaviour at low
   level.
4. **If the bounce reproduces**: check Alexa → Activity at that minute; then unpair the
   two kitchen dimmers' **Matter** copies (see the Matter section) and repeat the
   protocol. Bounce gone = the Matter path proven. Bounce persists = dimmer-local →
   Leviton's prescription (firmware, factory reset, re-add) and a look at the loads.
6. If the capture has to run for days, promote the tripwire to a LaunchAgent so it
   survives reboots.
