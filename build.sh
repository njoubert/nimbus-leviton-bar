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
#   ./build.sh install      release build → /Applications/NimbusLevitonBar.app (replacing any older
#                           copy), launch it, and register it to launch at login
#   ./build.sh uninstall    unregister the login item, quit, delete /Applications/NimbusLevitonBar.app
#                           and the saved preferences
#   ./build.sh status       running? installed? login item?
#   ./build.sh icon         re-render docs/icon.png from Sources/NimbusLevitonBar/AppIcon.swift
#   ./build.sh clean        remove build products
#
# Signing: release bundles (app / dmg / install) are ad-hoc signed unless a Developer ID is
# configured, in which case they are signed with it, hardened-runtime, timestamped, and the
# disk image is notarized and stapled. Configure it in a git-ignored ./.signing file (or the
# environment):
#   SIGN_IDENTITY="Developer ID Application: Niels Joubert (TEAMID)"
#   NOTARY_PROFILE=<profile>       # the name given to: xcrun notarytool store-credentials <profile> ...
# Debug builds (run) stay ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

NAME=NimbusLevitonBar          # executable / target / process name
APP_NAME="Nimbus Leviton Bar"  # what the user sees: the .app, the volume, Login Items
BUNDLE_ID=com.njoubert.nimbuslevitonbar
VERSION=1.0.0
INSTALL_DIR=/Applications
INSTALLED="$INSTALL_DIR/$APP_NAME.app"
DEV_APP="dist/debug/$APP_NAME.app"
REL_APP="dist/$APP_NAME.app"
DMG="dist/$NAME-$VERSION.dmg"

# Developer ID signing / notarization, off unless configured (see the header).
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -f .signing ]; then
  # shellcheck source=/dev/null
  . ./.signing
fi

# --- helpers -----------------------------------------------------------------------------

dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
say()  { printf '%s%s%s\n' "$green" "$*" "$reset"; }
note() { printf '%s%s%s\n' "$dim" "$*" "$reset"; }
warn() { printf '%s%s%s\n' "$yellow" "$*" "$reset" >&2; }

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
    note "bundled $app  (signed: $SIGN_IDENTITY)"
  elif [ -n "$SIGN_IDENTITY" ]; then
    # Debug builds are signed with the same identity (no hardened runtime, no timestamp) so
    # the code signature — and with it the Keychain's "Always Allow" for our items — stays
    # the same from one rebuild to the next. Ad-hoc signatures change every build and each
    # one prompts for the keychain password again.
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$app"
    note "bundled $app  (signed: $SIGN_IDENTITY, debug)"
  else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$app" >/dev/null 2>&1 || warn "codesign failed (continuing unsigned)"
    note "bundled $app  (ad-hoc signed)"
  fi
}

# Send something to Apple's notary service and staple the ticket to it.
#   notarize <path to .zip/.dmg to submit> <path to staple (the .app or the .dmg)>
notarize() {
  local submit=$1 staple=$2
  say "notarizing $(basename "$submit") — this waits on Apple, usually a few minutes"
  if ! xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" --wait; then
    warn "notarization failed; for the reason run:"
    warn "  xcrun notarytool log <submission id> --keychain-profile $NOTARY_PROFILE"
    return 1
  fi
  xcrun stapler staple -q "$staple"
  note "stapled $staple"
}

# Notarize the release app itself (so a copy dragged out of the DMG verifies offline too),
# then the DMG is signed, notarized and stapled in make_dmg.
notarize_app() {
  local app=$1 zip="dist/$NAME-notarize.zip"
  [ -n "$NOTARY_PROFILE" ] || { warn "no NOTARY_PROFILE: app signed but not notarized"; return 0; }
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip" "$app"
  rm -f "$zip"
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
  [ -d "$vol" ] || { warn "mount failed"; hdiutil detach "$dev" -quiet || true; return 1; }

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
  note "packed $out ($(du -h "$out" | cut -f1))"
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
    pgrep -x "$NAME" >/dev/null && { warn "still running, killing"; pkill -9 -x "$NAME" || true; sleep 0.3; }
    say "stopped $NAME"
  else
    note "$NAME is not running"
  fi
}

# --- commands ----------------------------------------------------------------------------

cmd="${1:-build}"
[ $# -gt 0 ] && shift

case "$cmd" in
  build)
    swift build
    sign_dev_binary
    say "ok → .build/debug/$NAME"
    ;;

  run)
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
    say "launched $DEV_APP   (./build.sh stop to quit, ./build.sh run --fg for logs)"
    ;;

  stop)
    stop_all
    if [ -e "$INSTALLED" ]; then note "the installed copy can be restarted with: open -a $NAME"; fi
    ;;

  app)
    swift build -c release
    make_bundle release "$REL_APP"
    [ -n "$SIGN_IDENTITY" ] && notarize_app "$REL_APP"
    say "built $REL_APP"
    ;;

  dmg)
    swift build -c release
    make_bundle release "$REL_APP"
    [ -n "$SIGN_IDENTITY" ] && notarize_app "$REL_APP"
    make_dmg "$REL_APP" "$DMG"
    say "built $DMG"
    note "Test it: open $DMG"
    ;;

  install)
    swift build -c release
    make_bundle release "$REL_APP"
    [ -n "$SIGN_IDENTITY" ] && notarize_app "$REL_APP"
    stop_all
    if [ -e "$INSTALLED" ]; then
      note "replacing $INSTALLED"
      rm -rf "$INSTALLED"
    fi
    ditto "$REL_APP" "$INSTALLED"
    # SMAppService registration is done by the app itself, for the bundle it runs from —
    # so launch the installed copy and have it register.
    open -n "$INSTALLED" --args --enable-login-item
    sleep 1.5
    say "installed $INSTALLED"
    note "login item: $("$INSTALLED/Contents/MacOS/$NAME" --login-item-status)"
    note "It is running now and will start at login. Toggle that in the menu or in System Settings › General › Login Items."
    ;;

  uninstall)
    if [ -e "$INSTALLED" ]; then
      stop_all
      # Unregister from the installed bundle before it disappears, or Login Items keeps a ghost.
      "$INSTALLED/Contents/MacOS/$NAME" --disable-login-item || warn "could not unregister the login item"
      rm -rf "$INSTALLED"
      say "removed $INSTALLED"
    else
      stop_all
      note "$INSTALLED is not installed"
    fi
    if defaults delete "$BUNDLE_ID" >/dev/null 2>&1; then note "removed preferences"; fi
    ;;

  status)
    if pgrep -x "$NAME" >/dev/null; then
      say "running: $(pgrep -x "$NAME" | xargs ps -o pid=,command= -p | head -3)"
    else
      note "not running"
    fi
    if [ -e "$INSTALLED" ]; then
      say "installed: $INSTALLED (v$(defaults read "$INSTALLED/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?'))"
      sig=$(codesign -dv --verbose=2 "$INSTALLED" 2>&1 || true)   # Authority= lines need verbose=2
      auth=$(printf '%s\n' "$sig" | grep -m1 '^Authority=' | cut -d= -f2- || true)
      gate=$(spctl -a -t exec -v "$INSTALLED" 2>&1 || true)   # "source=Notarized Developer ID" when stapled/notarized
      note "signed by: ${auth:-ad-hoc (no identity)}  ·  Gatekeeper: ${gate#*: }"
      note "login item: $("$INSTALLED/Contents/MacOS/$NAME" --login-item-status)"
    else
      note "not installed in $INSTALL_DIR"
    fi
    ;;

  icon)
    swift build >/dev/null
    .build/debug/$NAME --render-icon docs/icon.png --size 512
    ;;

  clean)
    rm -rf .build dist
    ;;

  *)
    sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
