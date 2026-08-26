# `lgtv` — the LG webOS SSAP spike

Phase 0 of [`docs/lg-tv-plan.md`](../../docs/lg-tv-plan.md): a scratch SSAP client, built to
answer one question — **does this television accept the native `settings/setSystemSettings`,
or does it still need the luna alert bridge?** It answered, and it is kept because the next
question will want the same instrument.

It is a **standalone SwiftPM package**. Nothing in the app's `Package.swift` refers to it, so
`swift build` at the repo root neither builds nor sees it, and no failure here can reach a
release. It shares no code with the app and the app shares none with it.

```
./build.sh                 build, and sign so macOS keeps its Local Network grant
.build/debug/lgtv discover
.build/debug/lgtv pair
.build/debug/lgtv probe    the go/no-go, restores whatever it changes
```

`--verbose` prints every frame in and out. The client-key is redacted in both directions,
always — there is no reveal switch, the same rule the app's Internals panel follows.

## The answer

**The native endpoint is closed to us, the luna bridge works.** Measured 2026-08-25 against
`OLED65G5WUA` (webOS 25, `10.10.3.230`, UDN `uuid:74ee9ab1-…`).

| Path | Result |
|---|---|
| `ssap://settings/setSystemSettings` | **`401 insufficient permissions`** — as a string and as a number, both |
| `createAlert` → `onClose` → `luna://com.webos.settingsservice/setSystemSettings` | **works** — `backlight` 100 → 75, still 75 at 2 s and at 5 s, restored cleanly |
| `ssap://settings/getSystemSettings` | works |
| subscribe to `getSystemSettings` | works — the TV pushes partial updates of its own accord |

So on the plan's own build-vs-buy gate this reads *use BetterDisplay*. But the picture is more
specific than "it does not work", and the specifics are what a decision should rest on:

**LG has closed the native write to third-party apps and left the bridge open.** The chain is
airtight and every link was measured:

1. The canonical community manifest — the one every client copies, signed with LG's leaked
   `test-signing-cert` — is refused outright: **`403 Pairing rejected: blacklisted certificate
   detected`**. It cannot even pair. That refusal arrives *before* the on-screen prompt.
2. Dropping the `signatures` array pairs fine. But an unsigned app is granted a fixed set of
   permissions, and `WRITE_SETTINGS` is not in it.
3. Hoisting `signed.permissions` into the top-level `permissions` array changes nothing — the
   control for that is `READ_UPDATE_INFO`, hoisted alongside, and
   `getCurrentSWInformation` still answers `401`. **The manifest's permission list is not the
   lever.** The set grants what it grants.
4. `WRITE_NOTIFICATION_ALERT` *is* granted, which is exactly why the bridge still works: it
   launders the write through a notification's `onClose` action, which runs with the settings
   service's own privilege.

That is why BetterDisplay uses the bridge. It is not a legacy path it never updated; it is the
only path there is.

### What that leaves

- **The bridge is not fragile in the way "privilege hack" suggests** — it wrote through
  **Filmmaker Mode**, which the plan expected to lock the control, and the value held. The
  plan's fear was the wrong one.
- **`externalpq` is still in this set's service list**, so the webOS 26 calibration removal has
  not landed here yet. Whether the bridge survives it is still unknown and still the real risk.
- The firmware version could not be read: `getCurrentSWInformation` needs `READ_UPDATE_INFO`,
  which is one of the permissions we do not get.

## Traps found here (they cost hours; don't re-learn them)

- **The blacklisted certificate, above.** Any tutorial's manifest fails on webOS 25. Drop
  `signatures`; keep everything else.
- **macOS Local Network permission is bound to the code signature.** An unsigned binary is a
  new identity on every `swift build`, so the first run after each build has its multicast
  silently dropped and discovery finds *nothing* — no error, no prompt, an empty result that
  reads exactly like a television in standby. `./build.sh` signs with the Developer ID from
  `../../.signing`, which fixes it permanently. This is the same trap as the Keychain one in
  the repo's `CLAUDE.md`, with the same cause and the same cure. **The app will need this
  permission too, and a user who has not granted it sees no television and no reason why.**
- **This Mac is multi-homed on one `/8`** (`en0` 10.1.0.1, `en1` 10.10.1.83) and an
  unqualified multicast send goes out exactly one interface — whichever the route table picked,
  not necessarily the television's. `Discovery` sets `IP_MULTICAST_IF` and sends on every
  eligible interface. The plan's "single flat LAN, multicast just works" was true by luck.
- **One unknown key fails the whole settings read** with `500 Application error`, and omitting
  `keys` to ask for the category wholesale does the same — which is the obvious way to go
  looking for the valid keys, and it does not work. `ai_Brightness` and `energySavingModified`
  each 500 on their own. Verified valid on this set: `backlight`, `brightness`, `contrast`,
  `color`, `pictureMode`, `energySaving`.
- **`register` answers twice.** The first `response` only names the pairing style; the
  registration is the later `registered` frame, and between them sits a human with a remote. A
  pending-request table that resolves on the first answer never sees the client-key.
- **An error is not silence, and reporting it as silence hides the answer.** The probe's first
  version wrapped the native write in `try?`, printed "no answer", and buried the
  `401 insufficient permissions` that *was* the whole result.
- **Values come back as strings** (`"backlight": "100"`), and are accepted as either.
- **Port 3000 accepts TCP on this set** — the plan recorded it as reset. It is still not what
  to use; 3001 is.
- The certificate is **not self-signed**: `CN=LGE TV SSG`, issued by an LG intermediate CA,
  valid to 2034, SHA-256 `11c5b1c5…`. It cannot validate (unknown root, and the name will
  never match a DHCP address), but it is perfectly pinnable, and stable enough to pin.

## Layout

```
Sources/lgtv/
  main.swift        dispatch
  Discovery.swift   SSDP M-SEARCH, per-interface, and the description XML
  SSAP.swift        the socket: TLS exception, register, id-correlated requests, subscriptions
  Manifest.swift    the registration manifest and its variants
  Commands.swift    the verbs
  KeyStore.swift    .lgtv-key.json — the client-key, 0600, git-ignored
```

`.lgtv-key.json` is a credential: whoever holds that key drives the television without touching
the remote. It is git-ignored, mode 0600, and never printed — only ever as a six-hex
fingerprint, the same convention as `Diagnostics.fingerprint` in the app. A file rather than the
Keychain for the same reason `DevCredentials` exists: a non-interactive shell cannot read a
Keychain item, and a debugging tool that only works from a foreground terminal is useless for
the job it is for.

## Safety

`probe` records `backlight` before it writes and puts it back afterwards, then reads back to
confirm it landed. Every write goes to the owner's real television, which is also this Mac's
display — an echo is not proof, so nothing here believes a write until a later read agrees.
