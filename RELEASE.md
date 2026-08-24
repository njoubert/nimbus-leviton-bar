# Releasing

`./build.sh release` does the whole dance: tag, build both artifacts,
notarize, preflight, push, publish, and confirms the zip release exists. What it does *not* do is bump the version or give you a chance to look at the
disk image, so those come first.

## Before you start

- **Write the release notes.** `./build.shrelease` looks for `docs/releases/v$VERSION.txt` by default. Alternatively you can supply a different file by calling `./build.sh release path/to/notes.txt`.
- **`.signing` must exist** (git-ignored) with `SIGN_IDENTITY` and `NOTARY_PROFILE`. Without a
  Developer ID the build is ad-hoc signed and not notarized, and a copy that arrives with a
  quarantine flag is refused at first open.
- **`gh` must be authenticated.** If it isn't, the command still builds, tags and pushes, then
  prints the `gh release create` line for you to run by hand.
- **The working tree must be clean.** `release` bails on a dirty tree, and its check is
  `git status --porcelain`, which counts *untracked* files too — so the version bump and the
  release notes both have to be committed before you run it.

## 1. Bump the version, and commit it

`VERSION=` near the top of `build.sh` is the only place the version lives. Bump it by hand or:

```sh
sed -i '' 's/^VERSION=.*/VERSION=1.6.0/' build.sh
git commit -am "Version 1.6.0"
```

**Commit before releasing** — `CFBundleVersion` is the commit count, so the bump has to be in
history for the build to number itself correctly. Historically this was a one-line commit
touching only `build.sh` (`9f55209`); folding in the notes file from step 2 is tidier.

Minor for anything a user would notice in the menu; patch for fixes. Changes only a developer
sees — the CLI, the icon-drawing code, these notes — don't need a release of their own.

## 2. Write the release notes, and commit them

Every release's notes live in the repo, one file per version:

```sh
$EDITOR docs/releases/v1.6.0.txt
git add docs/releases/v1.6.0.txt
```

`build.sh release` looks for `docs/releases/v$VERSION.txt` by default and stops if it isn't
there — or if it is there but empty, so a stub file created ahead of time doesn't get
published as a blank release page. Naming a different file as an argument still overrides it.

**The content is markdown even though the file is `.txt`** — GitHub renders the body, so
`**bold**`, lists and links all work. The extension is `.txt` only to keep editors from
linting a payload as if it were a document.

The file is the release body **verbatim** — whatever is in it is what appears on the GitHub
release page, so no title heading (GitHub shows the version as the title already) and no front
matter. `docs/releases/` holds every release published so far; read a few for the register.

Commit it together with the version bump from step 1. It has to be committed either way:
`release` refuses to publish from a dirty tree, and its check is `git status --porcelain`,
which counts untracked files — so an uncommitted notes file would block the release it exists
for.

## 3. Look at the disk image

```sh
./build.sh dmg
open dist/NimbusLevitonBar-1.6.0.dmg
```

`release` builds the DMG and publishes without pausing, so this is the only chance to check it
by eye: the app, the Applications folder to drag onto, the background text. `hdiutil detach`
it afterwards — a stale mount puts the next one on `/Volumes/<name> 1`, and the `ditto` in a
later step then fails after the old copy is already gone.

## 4. Ship

```sh
./build.sh release
```

In order, it:

1. reads `docs/releases/v<VERSION>.txt` — or the file you name as an argument — and refuses to
   go on if it is missing or empty;
2. refuses a dirty tree;
3. tags `v<VERSION>` if there isn't one — and refuses if the tag exists but isn't `HEAD`;
4. builds the release app, notarizes and staples it, and makes both
   `dist/NimbusLevitonBar-<version>.dmg` and `dist/NimbusLevitonBar-<version>.zip`;
5. runs `--preflight` against the built bundle;
6. **pushes `main` and the tag**;
7. `gh release create`s with both artifacts attached.

Note step 6: unlike the usual flow here, the release command pushes for you. Once preflight
passes there is no further confirmation.

## What preflight is protecting

`--preflight` reads `CFBundleShortVersionString` out of the bundle it was handed and checks
what has to stay true for the copies people already have to accept this build — identity,
signature, version. It runs *before* anything is pushed, while it can still be undone. If it
fails, nothing has left the machine.

The other half of that contract is the zip: **a release carrying only a DMG is invisible to the
updater.** `build.sh release` is what makes that impossible to get wrong; assembling a release
by hand is what gets it wrong.

## If it stops partway

The tag is created locally before anything is built, so a failure usually leaves it behind.
Re-running is safe — an existing tag that points at `HEAD` is accepted. If the tag is on the
wrong commit and hasn't been pushed, `git tag -d v<version>` and start again.

If it pushed and then `gh` failed, the artifacts are already in `dist/` — publish by hand with
the line the script prints.

## Afterwards

- `.build/debug/NimbusLevitonBar --check-update` shows the release feed exactly as the updater
  reads it. That is the check that the update people receive actually works.
- The GitHub social preview is **not** part of a release. It only needs re-doing when the icon
  or the screenshot changes: `./build.sh social`, then drag `docs/social-preview.png` onto
  Settings › General › Social preview. There is no API for it.
