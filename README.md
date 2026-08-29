<p align="center">
  <img src="docs/icon.png" alt="Nimbus Leviton Bar icon" width="128">
</p>

<h1 align="center">Nimbus Leviton Bar</h1>

<p align="center">
  A macOS menu bar switch for Leviton Decora Smart Wi-Fi dimmers, switches, fan controllers and
  plugs — everything on your My Leviton account, one click away.<br>
  No Dock icon, no window. Swift, SwiftPM, AppKit — and one dependency, our own
  <a href="https://github.com/njoubert/nimbus-updater">nimbus-updater</a>, which keeps it up to date.
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="Nimbus Leviton Bar: the lightbulb with the count of devices on in the menu bar, and the dropdown — All Devices with its tally and slider, then each room with its dot, tally and slider, and each device under its room with a slider for dimmers; offline devices marked in red; Refresh, Launch at Login, Sign Out, version, Quit" width="358">
</p>

```
./build.sh run            # debug build → dist/debug/Nimbus Leviton Bar.app, launch it (add --fg for logs here)
./build.sh stop           # quit it
./build.sh install        # release build → /Applications/Nimbus Leviton Bar.app, launch, add to Login Items
./build.sh uninstall      # remove the Login Item, the app, and its preferences
./build.sh status         # running? installed? login item?
./build.sh app            # release build → dist/Nimbus Leviton Bar.app only
./build.sh dmg            # release build → dist/NimbusLevitonBar-<version>.dmg, drag-to-Applications disk image
./build.sh icon           # re-render docs/icon.png
```

Re-running `install` replaces whatever is in `/Applications` with the current build.

## What it does

**In the bar** — a lightbulb: filled, with the number of devices that are on (`💡 3`), hollow
when everything is off, struck through when not signed in. Hover it for the tally:
`6 of 13 on · 3 offline`.

**In the dropdown** — **All Devices** first, the real master switch: its dot is green when
anything is on, hollow when all is off, red when nothing is reachable or the last request
failed, with the tally beside it; click it to turn every reachable device off (or on). Then
your rooms, in the order the My Leviton app shows them (rooms with no Wi-Fi device are left
out; rooms where nothing is reachable sink to the bottom), and under each room its devices,
unreachable ones last:

| Dot | Meaning |
|---|---|
| 🟢 | on — dimmers also show their level and a slider |
| ⚪ | off |
| 🔴 | My Leviton can't reach it (dropped off Wi-Fi); the row is disabled |

Click a device to toggle it; drag a dimmer's slider and the light is set when you let go (and
switched on, if it was off). Sliders snap to 5 % as you drag, so you land on 35 % rather than
34 %. An off dimmer reads 0 % with its slider at the bottom, as in the My Leviton app, and
dragging a slider to 0 turns the light off. Click a **room** to switch it
the way the My Leviton app does — through My Leviton's own room switch, which moves every
device in the room; the room row shows `2 of 3 on`. A room with a dimmer in it gets a slider
of its own — as does All Devices — which sets every reachable dimmer in that room (or the
whole home) to one level. Its knob sits at the *lowest* of them, counting an off dimmer as 0 —
so a room of dim lights with one bright one in it doesn't read as bright, and a small nudge
can't blast the room — and a lighter band carries on from the knob to the highest, so you can
still see how far up the rest of the room goes. 0 switches them all off.

**Hold ⌥** with the menu open and every device row shows what the device *is* rather than what
it is at: its model and firmware, `D36HD · 1.0.15`, in place of the slider and the level. Let
go and the sliders are back. (⌥ over the version line at the bottom is a different thing —
that one is **Internals**, below.)

**Scenes** sit in their own section under All Devices — what the My Leviton app calls
**Activities**: a saved set of devices and levels ("Evening Glow", "Good Morning"). Click one
and it runs, exactly as the app or a Leviton button would run it; hover it to see what it
sets. They are read-only here — create and edit them in the My Leviton app. A scene has no
state of its own, so its row shows no dot and no tally; what changes is the device rows under
it, which move the moment you click and are confirmed a second later. An account with no
Activities gets no section.

None of these clicks close the menu, so you can set up a room in one visit. A row flips the
moment you click it and the request follows; if My Leviton says no, the row snaps back and the
reason shows in the status line. Turning a dimmer on sends no level, so the dimmer's own rule
applies (back to its last level, or to its preset — whichever you chose in the My Leviton app;
[Setting up](#setting-up) suggests which, and why).

Below the list: **Refresh**, with the state of the connection beside it — `live` while My
Leviton's push feed is up, so a switch flipped anywhere shows up here within a second;
otherwise how long ago the list was fetched (`updated 47 seconds ago`), which is when the
once-a-minute poll is all there is. An error takes that spot when there is one. Then Launch at
Login; the update items (below); Sign Out.

**Updates** — the app keeps itself current, through
[nimbus-updater](https://github.com/njoubert/nimbus-updater) (MIT, shared with
[Nimbus Net Bar](https://github.com/njoubert/nimbus-net-bar); it is a normal SwiftPM package
dependency, pinned in `Package.resolved`). Once a day, and when you open the menu if the last
check is stale, it looks for a newer release; when it finds one it downloads it in the
background and the menu offers **Install Update 1.2.0 and Relaunch**, which takes a couple of
seconds and puts the menu bar icon back where it was. A download is installed only if macOS
confirms it is signed by the same Developer ID as the running copy, so a tampered download is
refused rather than installed. **Check for Updates…** asks straight away and tells you what it
found; **Check for Updates Automatically** turns the daily check off. A copy that is not
installed in `/Applications` — run from the disk image, or a debug build — never replaces
itself; it offers a link to the release page instead.

**Keeping up to date** — the list is refreshed when the menu opens (if it is more than a few
seconds old), once a minute in the background so the bar count stays honest, and live over
My Leviton's realtime feed when a switch is changed from the wall, the app, or a schedule.
The feed carries a device's state, not the shape of your home: a device added, removed or
renamed in the My Leviton app shows up on a fetch instead.

`live` is checked rather than assumed. The feed is pinged every 30 seconds and has ten to
answer; each minute's fetch is compared against what the feed has been telling us, and a light
that changed without the feed saying so costs it the label and gets it reconnected. It also
reconnects when the Mac wakes, and when you click **Refresh**. Whatever happens to it, the
once-a-minute fetch is still there — a feed that dies quietly costs you up to a minute's delay,
never a wrong reading.

**Internals** — hold ⌥ over the version line at the bottom of the menu and it turns into
**Internals…**, which opens a window on what the app is doing on the network: the push feed's
state (how long it has been up, how many devices it is subscribed to, frames seen, the last
ping's round trip), every request to My Leviton with what was sent and what came back, every
websocket frame, and the app's own milestones — with buttons to reconnect the feed, fetch now,
or sign in again. It records from launch, so whatever went wrong ten minutes ago is still
there to look at. Nothing secret goes into it: the password never appears, and the session
token only as a fingerprint (`#a3f19c`) — enough to see that it changed, no use to anyone
else. **Copy** puts the summary and the one-line log on the clipboard, ready for a bug report;
it deliberately leaves the bodies out, since a device record carries your address, MAC and
local IP.

## Setting up

1. **Install it** — `./build.sh install` builds a release copy into `/Applications`, launches
   it and adds it to your Login Items. From a disk image, drag it across and open it once from
   `/Applications`; see [Distribution](#distribution) for what macOS will say about an
   unsigned copy.
2. **Sign in** — it asks for your My Leviton email and password on first launch (and for the
   emailed code, if your account uses two-factor). They go in your login Keychain; see
   [Account and privacy](#account-and-privacy).
3. **Check Launch at Login** — the first launch from `/Applications` sets it for you; the menu
   item turns it off again and that sticks.
4. **Set your dimmers to "last level"** — in the My Leviton app, a dimmer's settings let it
   either come back on at the level it was last at or come on at a fixed preset level you pick.
   Turn the preset off, so it returns to the last level. Both work here, but the sliders are
   nicer that way.

**Why that last one matters.** The reason is in the hardware: a dimmer with a fixed preset
comes on at that preset no matter what the cloud is told in the same breath. Setting one from
off to 40 % therefore takes two requests two seconds apart — switch it on, wait for it to
report where it landed, then dim it — and you watch the light sit at its preset (100 %, say)
before it drops to the 40 % you asked for. A "last level" dimmer takes both in one request and
arrives at 40 % directly, with no detour. Nothing misbehaves if you keep your presets; those
dimmers are just slower to set, and they flash on the way. `--print` marks the ones that have a
preset, so you can see at a glance which is which.

## Account and privacy

On first launch it asks for your My Leviton email and password — the same login as the My
Leviton app — and keeps them in your login Keychain, never in a preferences file. The session
token My Leviton issues is kept there too, so day to day the password is not sent again; it
is only replayed when a session expires or is rejected. **Sign Out** in the menu removes both.

It talks to `my.leviton.com` for everything about your lights: no analytics, no crash
reporting, nothing else about your home leaves the machine.

The one other thing it contacts is GitHub, to keep itself up to date. Once a day it asks
`api.github.com` for this project's newest release; if there is one, it downloads the app from
`release-assets.githubusercontent.com`, checks that the download is signed with the same
Developer ID as the copy you are running, and then offers **Install Update … and Relaunch** in
the menu. Nothing is installed until you click that. Those requests carry no account
information — only the app's name and version, as the User-Agent. Turn the whole thing off
with **Check for Updates Automatically** in the menu, and nothing contacts GitHub unless you
pick **Check for Updates…** yourself.

From the command line the same client is available without the UI (handy for scripts and
for checking what the account returns):

```
.build/debug/NimbusLevitonBar --login you@example.com   # prompts for the password (or takes $MYLEVITON_PASSWORD), saves both
.build/debug/NimbusLevitonBar --print                   # residences and devices, as text
.build/debug/NimbusLevitonBar --set "Kitchen" 40        # a name or an id; on | off | 0–100
.build/debug/NimbusLevitonBar --watch                   # print realtime updates as they arrive
.build/debug/NimbusLevitonBar --scenes                   # the Activities and what each one sets
.build/debug/NimbusLevitonBar --scene "Evening Glow"    # run one
.build/debug/NimbusLevitonBar --get Residences/1/residentialRooms   # any GET, pretty-printed
.build/debug/NimbusLevitonBar --check-update              # what the updater sees on GitHub
.build/debug/NimbusLevitonBar --logout
```

In a shell that cannot be prompted for Keychain access — an ssh session, a cron job — those
commands report "not signed in" however good the Keychain entries are. Put `MYLEVITON_EMAIL`
and `MYLEVITON_PASSWORD` in a `.leviton` file in the working directory (`chmod 600`; it is
git-ignored) and the command line, and only the command line, signs in from that instead. The
app itself never reads it.

## Distribution

`./build.sh dmg` makes the usual disk image: the app, an Applications folder to drag it onto,
and a background that says what to expect — the first launch from `/Applications` registers
the Login Item (once; turning it off later sticks) and asks you to sign in.

Without a Developer ID the build is ad-hoc signed and not notarized, so a copy that arrives
with a quarantine flag (browser download, AirDrop) is refused at first open and has to be
allowed in System Settings › Privacy & Security ("Open Anyway"); a copy that comes over scp or
a USB stick opens straight away. With one, put it in a git-ignored `.signing` file next to
`build.sh` and `app`/`dmg`/`install` sign with it (hardened runtime, timestamped), notarize the
app and the disk image, and staple both:

```
SIGN_IDENTITY="Developer ID Application: Niels Joubert (TEAMID)"
NOTARY_PROFILE=<profile>      # the name you gave: xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password …
```

## Testing

`swift test` runs the whole suite (~245 tests, ~20 seconds) with no credentials and no
network beyond localhost — nothing in it can touch your lights, your Keychain, or your
My Leviton account. `TESTING.md` has the map, the harness, and the rules; it also documents
`--probe`, a read-only check that my.leviton.com still answers in the shapes this app
assumes.

## Licence

GPL-3.0-or-later. Not affiliated with Leviton; My Leviton is theirs.
