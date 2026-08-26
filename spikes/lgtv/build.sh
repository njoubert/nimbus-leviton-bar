#!/usr/bin/env bash
# Build the spike, and sign it so macOS stops forgetting it.
#
# Local Network permission is bound to a binary's code signature. An unsigned build gets a new
# identity on every rebuild, so the first run after every `swift build` has its multicast
# silently dropped and discovery finds nothing — the same shape as the Keychain trap in the
# repo's CLAUDE.md, and the same fix: sign with the stable Developer ID from ../../.signing.
set -euo pipefail

cd "$(dirname "$0")"

print_header() { printf '\n\033[1m%s\033[0m\n' "$1"; }
print_success() { printf '✓ %s\n' "$1"; }
print_warning() { printf '⚠ %s\n' "$1" >&2; }
print_info() { printf '  %s\n' "$1"; }

print_header "Building lgtv"
swift build "$@"
BIN=".build/debug/lgtv"

if [ -f ../../.signing ]; then
    # shellcheck disable=SC1091
    . ../../.signing
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$BIN"
    print_success "signed as $SIGN_IDENTITY"
    print_info "the Local Network grant now survives a rebuild"
else
    print_warning "no SIGN_IDENTITY in ../../.signing — building unsigned"
    print_info "macOS will drop the first multicast send after every rebuild, so the"
    print_info "first 'lgtv discover' will find nothing; just run it twice"
fi

print_success "$BIN"
