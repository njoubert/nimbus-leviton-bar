#!/usr/bin/env bash
# Build, run and install Nimbus Leviton Bar — the menu bar controller for MyLeviton lights.
#
#   ./build.sh              debug build → .build/debug/NimbusLevitonBar
#   ./build.sh run [args]   debug build as dist/debug/NimbusLevitonBar.app, (re)launch it detached.
#                           args go to the app, e.g. --hz 5. Add --fg to run in the foreground
#                           instead (logs in this terminal, Ctrl-C quits).
#   ./build.sh stop         quit every running NimbusLevitonBar (dev or installed)
#   ./build.sh app          release build → dist/NimbusLevitonBar.app (ad-hoc signed, icon baked in)
#   ./build.sh dmg          release build → dist/NimbusLevitonBar-<version>.dmg, the drag-to-Applications
#                           disk image (background drawn by Sources/NimbusLevitonBar/DMGBackground.swift)
#   ./build.sh release [RELEASE_NOTES_FILE]
#                           the whole ship: tag, build the DMG and the zip, notarize, preflight,
#                           push, and publish the GitHub release. The notes default to
#                           docs/releases/v<version>.txt, which must exist. See RELEASE.md.
#   ./build.sh install      release build → /Applications/NimbusLevitonBar.app (replacing any older
#                           copy), launch it, and register it to launch at login
#   ./build.sh uninstall    unregister the login item, quit, delete /Applications/NimbusLevitonBar.app
#                           and the saved preferences
#   ./build.sh status       running? installed? login item?
#   ./build.sh icon         re-render docs/icon.png from Sources/NimbusLevitonBar/AppIcon.swift
#   ./build.sh social       re-render docs/social-preview.png from Sources/NimbusLevitonBar/SocialCard.swift
#                           — GitHub's link-preview card. Upload it by hand under the repo's
#                           Settings › General › Social preview; GitHub has no API for it.
#   ./build.sh clean        remove build products
#
# Signing: release bundles (app / dmg / install) are ad-hoc signed unless a Developer ID is
# configured, in which case they are signed with it, hardened-runtime, timestamped, and the
# disk image is notarized and stapled. Configure it in a git-ignored ./.signing file (or the
# environment):
#   SIGN_IDENTITY="Developer ID Application: Niels Joubert (TEAMID)"
#   NOTARY_PROFILE=<profile>       # the name given to: xcrun notarytool store-credentials <profile> ...
# Debug builds (run) stay ad-hoc.
set -Eeuo pipefail   # -E: functions and subshells inherit the ERR trap below
cd "$(dirname "$0")"

NAME=NimbusLevitonBar          # executable / target / process name
APP_NAME="Nimbus Leviton Bar"  # what the user sees: the .app, the volume, Login Items
BUNDLE_ID=com.njoubert.nimbuslevitonbar
VERSION=1.6.0
INSTALL_DIR=/Applications
INSTALLED="$INSTALL_DIR/$APP_NAME.app"
DEV_APP="dist/debug/$APP_NAME.app"
REL_APP="dist/$APP_NAME.app"
DMG="dist/$NAME-$VERSION.dmg"
ZIP="dist/$NAME-$VERSION.zip"     # what the auto-updater downloads; see docs/autoupdate-plan.md
NOTES="docs/releases/v$VERSION.txt"  # the release body, committed; one file per version

# Developer ID signing / notarization, off unless configured (see the header).
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -f .signing ]; then
  # shellcheck source=/dev/null
  . ./.signing
fi

# --- helpers -----------------------------------------------------------------------------

# Output style follows ../weshootfilm/provision.sh, so the two read the same: a ruled blue
# header per section, then ✓ / ⚠ / ✗ lines with indented detail under them. Warnings and
# errors go to stderr (provision.sh puts them on stdout) so a failure survives a pipe.
red=$'\033[0;31m'; green=$'\033[0;32m'; yellow=$'\033[1;33m'; blue=$'\033[0;34m'
reset=$'\033[0m'
rule="================================================="

print_header()  { printf '\n%s%s\n%s\n%s%s\n\n' "$blue" "$rule" "$*" "$rule" "$reset"; }
print_success() { printf '%s✓ %s%s\n' "$green" "$*" "$reset"; }
print_warning() { printf '%s⚠ %s%s\n' "$yellow" "$*" "$reset" >&2; }
print_error()   { printf '%s✗ %s%s\n' "$red" "$*" "$reset" >&2; }
print_info()    { printf '  %s\n' "$*"; }
print_done()    { printf '\n%s%s\n✓ %s\n%s%s\n\n' "$green" "$rule" "$*" "$rule" "$reset"; }
print_failed()  { printf '\n%s%s\n✗ %s\n%s%s\n\n' "$red" "$rule" "$*" "$rule" "$reset" >&2; }

# What the closing banner says on success; commands set it to something better than their name.
RESULT=""
result() { RESULT=$1; }

# What the script is doing, for the failure message. `set -e` exits with whatever the failing
# command printed, which for ditto, hdiutil and osascript is often nothing at all — a release
# died mid-way once and looked exactly like a release that had finished.
STAGE=""
stage() { STAGE=$1; }

on_error() {
  local code=$1 line=$2 cmd=$3
  print_error "FAILED: ${STAGE:-$cmd_name} — exit $code at build.sh line $line"
  print_info "command: $cmd" >&2
  # Anything the run started but did not finish, so the state is never a guess.
  if [ -n "${tagged_here:-}" ]; then
    print_info "the tag $tagged_here was created by this run; nothing was pushed or published" >&2
    print_info "re-run to resume, or: git tag -d $tagged_here" >&2
  fi
  exit "$code"
}

# Two ./build.sh runs cannot share dist/: make_bundle rm -rf's the app bundle and notarize_app
# writes a fixed temp zip, so a second run silently pulls the ground out from under the first.
LOCK="dist/.build-lock"
lock_held=""
acquire_lock() {
  # `release` re-invokes this script for `dmg`; that child runs under the parent's lock.
  [ -n "${BUILD_LOCK_INHERITED:-}" ] && return 0
  mkdir -p dist
  while ! mkdir "$LOCK" 2>/dev/null; do
    local pid other
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    other=$(cat "$LOCK/cmd" 2>/dev/null || echo "?")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      print_error "another ./build.sh is running: $other (pid $pid)"
      print_info "both write dist/ and would clobber each other — wait for it, or kill $pid" >&2
      exit 1
    fi
    print_warning "clearing a stale lock (pid ${pid:-unknown} is gone)"
    rm -rf "$LOCK"
  done
  printf '%s\n' "$$" > "$LOCK/pid"
  printf '%s\n' "$1" > "$LOCK/cmd"
  lock_held=1
}
release_lock() { [ -n "$lock_held" ] && rm -rf "$LOCK"; lock_held=""; }

# Assemble a .app around a built binary: Info.plist, icon, ad-hoc signature.
#   make_bundle <config: debug|release> <out.app>
make_bundle() {
  local config=$1 app=$2 bin=".build/$1/$NAME"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/$NAME"
  cp LICENSE "$app/Contents/Resources/LICENSE"

  # The icon is drawn in code; render it to an .iconset and let iconutil pack it.
  local iconset="dist/$config-AppIcon.iconset"
  "$bin" --render-iconset "$iconset" >/dev/null
  iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
  rm -rf "$iconset"

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  plutil -convert xml1 -o /dev/null "$app/Contents/Info.plist"   # validate (plutil -lint misparses here)
  if [ "$config" = release ] && [ -n "$SIGN_IDENTITY" ]; then
    # Hardened runtime + secure timestamp are what notarization requires. No entitlements:
    # URLSession and the Keychain work under the hardened runtime.
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --identifier "$BUNDLE_ID" "$app"
    codesign --verify --strict --deep "$app"
    print_info "bundled $app  (signed: $SIGN_IDENTITY)"
  elif [ -n "$SIGN_IDENTITY" ]; then
    # Debug builds are signed with the same identity (no hardened runtime, no timestamp) so
    # the code signature — and with it the Keychain's "Always Allow" for our items — stays
    # the same from one rebuild to the next. Ad-hoc signatures change every build and each
    # one prompts for the keychain password again.
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$app"
    print_info "bundled $app  (signed: $SIGN_IDENTITY, debug)"
  else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$app" >/dev/null 2>&1 || print_warning "codesign failed (continuing unsigned)"
    print_info "bundled $app  (ad-hoc signed)"
  fi
}

# Send something to Apple's notary service and staple the ticket to it.
#   notarize <path to .zip/.dmg to submit> <path to staple (the .app or the .dmg)>
notarize() {
  local submit=$1 staple=$2
  print_success "notarizing $(basename "$submit") — this waits on Apple, usually a few minutes"
  if ! xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" --wait; then
    print_error "notarization failed; for the reason run:"
    print_info "xcrun notarytool log <submission id> --keychain-profile $NOTARY_PROFILE" >&2
    return 1
  fi
  xcrun stapler staple -q "$staple"
  print_info "stapled $staple"
}

# Notarize the release app itself (so a copy dragged out of the DMG verifies offline too),
# then the DMG is signed, notarized and stapled in make_dmg.
notarize_app() {
  local app=$1 zip="dist/$NAME-notarize.zip"
  [ -n "$NOTARY_PROFILE" ] || { print_warning "no NOTARY_PROFILE: app signed but not notarized"; return 0; }
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip" "$app"
  rm -f "$zip"
}

# The auto-updater's asset: the stapled app, zipped with ditto (which keeps symlinks and
# extended attributes, so the signature and the notarization ticket survive). Must run after
# notarize_app, or the download is the pre-staple copy.
#   make_zip <app> <out.zip>
make_zip() {
  local app=$1 out=$2
  rm -f "$out"
  ditto -c -k --keepParent "$app" "$out"
  print_info "packed $out ($(du -h "$out" | cut -f1))"
}

# Wrap dist/NimbusLevitonBar.app in the usual drag-to-Applications disk image: the app, an
# Applications alias, and a background picture that says what to do and what to expect.
# Finder keeps icon positions / background / window size in the volume's .DS_Store, and the
# only supported way to write that is to ask Finder — hence the AppleScript (the first run
# prompts for permission to control Finder).
#   make_dmg <app> <out.dmg>
make_dmg() {
  local app=$1 out=$2 bin="$1/Contents/MacOS/$NAME"
  local staging="dist/dmg-staging" rw="dist/$NAME-rw.dmg" vol="/Volumes/$APP_NAME"

  rm -rf "$staging" "$rw"
  mkdir -p "$staging/.background"
  ditto "$app" "$staging/$APP_NAME.app"
  ln -s /Applications "$staging/Applications"
  cp LICENSE "$staging/.LICENSE"    # hidden: present, but not a third icon to drag
  local bgflags=()
  [ -n "$SIGN_IDENTITY" ] && bgflags+=(--signed)   # drops the "unsigned build" footer
  "$bin" --render-dmg-background "$staging/.background" "${bgflags[@]+"${bgflags[@]}"}" >/dev/null
  # One TIFF holding the 1× and 2× renders, so Finder picks the sharp one on Retina.
  tiffutil -cathidpicheck "$staging/.background/background.png" "$staging/.background/background@2x.png" \
    -out "$staging/.background/background.tiff" >/dev/null 2>&1
  rm "$staging/.background/background.png" "$staging/.background/background@2x.png"

  # A stale mount from an earlier run would make this one land on "/Volumes/$NAME 1".
  if [ -d "$vol" ]; then hdiutil detach "$vol" -quiet -force || true; fi
  hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDRW -fs HFS+ -quiet "$rw"
  local dev
  dev=$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | awk '/^\/dev\// {print $1; exit}')
  [ -d "$vol" ] || { print_warning "mount failed"; hdiutil detach "$dev" -quiet || true; return 1; }

  # Geometry matches DMGBackground.swift: 640×440 window, icon centres at (170,210) / (470,210).
  osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    -- Finder remembers the (hidden) sidebar's width and adds it back on reopen unless zeroed.
    set sidebar width of container window to 0
    -- bounds include the 28 pt title bar.
    set the bounds of container window to {200, 120, 840, 588}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 12
    set label position of opts to bottom
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 210}
    set position of item "Applications" of container window to {470, 210}
    close
    open
    set sidebar width of container window to 0
    set the bounds of container window to {200, 120, 840, 588}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  sync
  rm -rf "$vol/.fseventsd"
  chmod -Rf go-w "$vol" || true
  hdiutil detach "$dev" -quiet
  rm -f "$out"
  hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -quiet -o "$out"
  rm -rf "$rw" "$staging"
  if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$out"
    if [ -n "$NOTARY_PROFILE" ]; then
      notarize "$out" "$out"
      spctl -a -t open --context context:primary-signature -v "$out" 2>&1 | sed 's/^/  /' || true
    fi
  else
    codesign --force --sign - "$out" >/dev/null 2>&1 || true
  fi
  print_info "packed $out ($(du -h "$out" | cut -f1))"
}

# Sign the bare debug binary the same way, so the CLI (--print, --set, --get…) shares the
# bundle's keychain access instead of prompting on every rebuild.
sign_dev_binary() {
  local bin=".build/debug/$NAME"
  if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$bin"
  else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$bin" >/dev/null 2>&1 || true
  fi
}

# Quit every running copy and wait for it to go away.
stop_all() {
  if pgrep -x "$NAME" >/dev/null; then
    pkill -x "$NAME" || true
    for _ in $(seq 1 30); do pgrep -x "$NAME" >/dev/null || break; sleep 0.1; done
    pgrep -x "$NAME" >/dev/null && { print_warning "still running, killing"; pkill -9 -x "$NAME" || true; sleep 0.3; }
    print_success "stopped $NAME"
  else
    print_info "$NAME is not running"
  fi
}

# --- commands ----------------------------------------------------------------------------

cmd="${1:-build}"
cmd_name="./build.sh $cmd"
[ $# -gt 0 ] && shift

on_exit() {
  local code=$?
  release_lock
  if [ "$code" -eq 0 ]; then print_done "${RESULT:-$cmd_name}"
  else print_failed "${RESULT:-$cmd_name} — exit $code"; fi
}

trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap 'on_exit' EXIT
trap 'print_error "interrupted during ${STAGE:-$cmd_name}"; exit 130' INT TERM

case "$cmd" in
  build|run|app|dmg|install|release|icon|social|clean) acquire_lock "$cmd_name" ;;
esac

case "$cmd" in
  build)
    print_header "Building $APP_NAME (debug)"
    swift build
    sign_dev_binary
    print_success "ok → .build/debug/$NAME"
    ;;

  run)
    print_header "Running $APP_NAME (debug)"
    fg=0; args=()
    for a in "$@"; do [ "$a" = "--fg" ] && fg=1 || args+=("$a"); done
    swift build
    sign_dev_binary
    make_bundle debug "$DEV_APP"
    stop_all
    if [ $fg = 1 ]; then
      exec "$DEV_APP/Contents/MacOS/$NAME" "${args[@]+"${args[@]}"}"
    fi
    open -n "$DEV_APP" --args "${args[@]+"${args[@]}"}"
    print_success "launched $DEV_APP   (./build.sh stop to quit, ./build.sh run --fg for logs)"
    ;;

  stop)
    print_header "Stopping $APP_NAME"
    stop_all
    if [ -e "$INSTALLED" ]; then print_info "the installed copy can be restarted with: open -a $NAME"; fi
    ;;

  app)
    print_header "Building $APP_NAME $VERSION (release)"
    swift build -c release
    make_bundle release "$REL_APP"
    [ -n "$SIGN_IDENTITY" ] && notarize_app "$REL_APP"
    print_success "built $REL_APP"
    ;;

  dmg)
    print_header "Building the disk image — $APP_NAME $VERSION"
    stage "compiling"          ; swift build -c release
    stage "bundling the app"   ; make_bundle release "$REL_APP"
    if [ -n "$SIGN_IDENTITY" ]; then stage "notarizing the app"; notarize_app "$REL_APP"; fi
    stage "packing the zip"    ; make_zip "$REL_APP" "$ZIP"
    stage "building the disk image"; make_dmg "$REL_APP" "$DMG"
    stage ""
    print_success "built $DMG"
    result "built $DMG"
    print_info "Test it: open $DMG"
    ;;

  # Everything a release needs, in the order the notes say: build both artifacts, tag, publish.
  # Refuses to publish from a dirty tree or a commit that is not the version's tag.
  release)
    print_header "Releasing $APP_NAME $VERSION"
    # The body is docs/releases/v<VERSION>.txt unless another file is named, so the notes for
    # every release are in the history rather than in someone's scratch directory. (.txt, not
    # .md, though the content is markdown: they are payloads, and editors lint .md files.)
    notes=${1:-$NOTES}
    if [ ! -s "$notes" ]; then
      print_error "no release notes at $notes"   # -s, so an empty stub counts as missing
      print_info "write them there and commit them, then run this again (see RELEASE.md)" >&2
      exit 2
    fi
    if [ -n "$(git status --porcelain)" ]; then
      print_warning "working tree is dirty; commit first"
      exit 1
    fi
    tag="v$VERSION"
    if git rev-parse "$tag" >/dev/null 2>&1; then
      if [ "$(git rev-parse "$tag^{commit}")" != "$(git rev-parse HEAD)" ]; then
        print_warning "$tag exists but is not HEAD — $(git log -1 --format=%h\ %s "$tag^{commit}")"
        print_info "a previous release run tagged an older commit; move it with:" >&2
        print_info "git tag -d $tag   (it is only local until this script pushes it)" >&2
        exit 1
      fi
    else
      git tag -a "$tag" -m "$APP_NAME $VERSION"
      tagged_here=$tag       # so on_error can say the tag exists and nothing was pushed
      print_info "tagged $tag"
    fi
    stage "building the release artifacts"
    BUILD_LOCK_INHERITED=1 "$0" dmg
    # The requirements auto-update depends on, checked while it can still be undone: identity,
    # signature, version, and whether the copies people already have would accept this build.
    print_header "Preflight — can installed copies accept this build?"
    stage "preflight"
    swift build >/dev/null
    sign_dev_binary
    ".build/debug/$NAME" --preflight "$REL_APP"
    print_header "Publishing $tag"
    stage "pushing main and $tag"
    git push origin main
    git push origin "$tag"
    tagged_here=""           # pushed: no longer this run's to clean up
    if command -v gh >/dev/null 2>&1; then
      stage "publishing the GitHub release"
      gh release create "$tag" "$DMG" "$ZIP" --title "$VERSION" --notes-file "$notes"
      stage ""
      print_success "published $tag"
      result "published $tag — $(gh release view "$tag" --json url --jq .url 2>/dev/null || echo "$tag")"
    else
      print_warning "gh is not installed; publish by hand:"
      print_info "gh release create $tag $DMG $ZIP --title $VERSION --notes-file $notes"
      print_info "both files: the updater cannot see a release that carries only the DMG"
      result "built and tagged $tag — publish it by hand with the line above"
    fi
    ;;

  install)
    print_header "Installing $APP_NAME $VERSION"
    swift build -c release
    make_bundle release "$REL_APP"
    [ -n "$SIGN_IDENTITY" ] && notarize_app "$REL_APP"
    stop_all
    if [ -e "$INSTALLED" ]; then
      print_info "replacing $INSTALLED"
      rm -rf "$INSTALLED"
    fi
    ditto "$REL_APP" "$INSTALLED"
    # SMAppService registration is done by the app itself, for the bundle it runs from —
    # so launch the installed copy and have it register.
    open -n "$INSTALLED" --args --enable-login-item
    sleep 1.5
    print_success "installed $INSTALLED"
    print_info "login item: $("$INSTALLED/Contents/MacOS/$NAME" --login-item-status)"
    print_info "It is running now and will start at login. Toggle that in the menu or in System Settings › General › Login Items."
    ;;

  uninstall)
    print_header "Uninstalling $APP_NAME"
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
    rm -rf "$INSTALL_DIR/.$NAME-old.app" "$INSTALL_DIR/.$NAME-update.app"
    if [ -e "$INSTALLED" ]; then
      stop_all
      # Unregister from the installed bundle before it disappears, or Login Items keeps a ghost.
      "$INSTALLED/Contents/MacOS/$NAME" --disable-login-item || print_warning "could not unregister the login item"
      rm -rf "$INSTALLED"
      print_success "removed $INSTALLED"
    else
      stop_all
      print_info "$INSTALLED is not installed"
    fi
    if defaults delete "$BUNDLE_ID" >/dev/null 2>&1; then print_info "removed preferences"; fi
    ;;

  status)
    print_header "$APP_NAME status"
    if pgrep -x "$NAME" >/dev/null; then
      print_success "running: $(pgrep -x "$NAME" | xargs ps -o pid=,command= -p | head -3)"
    else
      print_info "not running"
    fi
    if [ -e "$INSTALLED" ]; then
      print_success "installed: $INSTALLED (v$(defaults read "$INSTALLED/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?'))"
      sig=$(codesign -dv --verbose=2 "$INSTALLED" 2>&1 || true)   # Authority= lines need verbose=2
      auth=$(printf '%s\n' "$sig" | grep -m1 '^Authority=' | cut -d= -f2- || true)
      gate=$(spctl -a -t exec -v "$INSTALLED" 2>&1 || true)   # "source=Notarized Developer ID" when stapled/notarized
      print_info "signed by: ${auth:-ad-hoc (no identity)}  ·  Gatekeeper: ${gate#*: }"
      print_info "login item: $("$INSTALLED/Contents/MacOS/$NAME" --login-item-status)"
      if [ -w "$INSTALL_DIR" ]; then
        print_info "updates: $INSTALL_DIR is writable, so the app can replace itself"
      else
        print_warning "updates: $INSTALL_DIR is not writable by you — the app will only link to the release page"
      fi
      for stray in "$INSTALL_DIR/.$NAME-old.app" "$INSTALL_DIR/.$NAME-update.app"; do
        if [ -e "$stray" ]; then print_warning "left over from an update: $stray"; fi
      done
    else
      print_info "not installed in $INSTALL_DIR"
    fi
    ;;

  icon)
    print_header "Rendering the app icon"
    swift build >/dev/null
    .build/debug/$NAME --render-icon docs/icon.png --size 512
    ;;

  social)
    print_header "Rendering the social preview card"
    swift build >/dev/null
    .build/debug/$NAME --render-social docs/social-preview.png
    ;;

  clean)
    print_header "Cleaning build products"
    rm -rf .build dist
    ;;

  *)
    sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
