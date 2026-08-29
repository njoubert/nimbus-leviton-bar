# Lights that fight back — forensic notes

Started 2026-08-29. The symptom: pressing a wall paddle off, the light dims off and
immediately comes back on; turning it off from the My Leviton phone app sticks. Suspects at
the outset: Alexa (skill and/or Matter), the new Scenes, this app on 4 machines, Leviton
itself, the new dimmers' own hardware/wiring.

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

So for any suspicious ON in the log:

| frame | meaning |
|---|---|
| ON **with** `client_id` | a *public-API* client: the My Leviton phone app, this app, a scene execution. Compare the id against one from a deliberate write of ours to tell us apart from the phone. |
| ON **without** `client_id`, fresh `chgReason` **3** | a command from outside the public API — **Alexa**, by either path: the skill (verified 2026-08-29 08:15:29 — a voice-commanded ON of Bookcase, a non-Matter DW15P, arrived with no `client_id` and stamped a fresh chgReason 3) or Matter-local. The two are so far indistinguishable in the log; either way, Alexa. |
| ON **without** `client_id`, fresh `chgReason` **1** | the device itself: paddle, wiring, firmware. (Still inferred, not yet provoked deliberately.) |
| `chgReason` **6** | OTA / reboot (observed on PH Mini's 2026-08-29 firmware update). |

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
- Bamboo Lamps (649819) flaps connected/disconnected all morning — weak Wi-Fi, unrelated.

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

1. **Calibrate the paddle** — the decoder's last unverified row. The next wall press
   anyone makes: note the device and the clock time; the journal should show the change
   with no `client_id` and a fresh `chgReason` 1. Any light being used anyway will do.
2. **Try to provoke the fight** with the journal running: press an affected dimmer off at
   the wall, the way that used to trigger it. One captured OFF→ON settles the culprit
   category via the decoder table. Also record *which* dimmers have fought — the list is
   itself evidence (all new D36HDs, or only some wall boxes?).
3. **Read the Alexa app** (section above) around any captured timestamp.
4. **If the decoder says "Alexa"** (no `client_id`, fresh chgReason 3): unpair the Matter
   copies (see the Matter section) and live with it a while. Fighting gone → the Matter
   path was the mechanism. Still fighting → the skill; temporarily disabling the My
   Leviton skill in Alexa is the counter-experiment.
5. **If the decoder says "the device"** (fresh chgReason 1): Leviton's prescription —
   firmware, factory reset, re-add — plus a look at the wall box for 3-way/companion
   wiring on the affected dimmers.
6. If the capture has to run for days, promote the tripwire to a LaunchAgent so it
   survives reboots.
