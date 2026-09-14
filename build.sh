#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache build/LidPlane.app/Contents/{MacOS,Resources}
task_flags=()
if [ "${1:-}" = "--diagnostics" ]; then task_flags=(-D RENDER_TEST); fi
xcrun swiftc -swift-version 5 -O ${task_flags[@]+"${task_flags[@]}"} -module-cache-path "$PWD/build/module-cache" \
    -target arm64-apple-macos14.0 Sources/*.swift \
    -o build/LidPlane.app/Contents/MacOS/LidPlane
cp Info.plist build/LidPlane.app/Contents/Info.plist
cp Resources/Plane.metal build/LidPlane.app/Contents/Resources/Plane.metal
cp Resources/AppIcon.icns build/LidPlane.app/Contents/Resources/AppIcon.icns
# An ad-hoc signature ("-") makes the designated requirement the binary's own
# cdhash, so every rebuild is a brand new app as far as TCC is concerned and the
# Screen Recording grant stops matching. Signing with a stable identity — a
# self-signed code-signing certificate is enough, no Apple Developer Program
# needed — keeps the grant across rebuilds. See README.
# Preference order: explicit env var, then whatever setup-dev.sh recorded,
# then ad-hoc.
IDENTITY="${LIDPLANE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f .signing-identity ]; then
    IDENTITY="$(cat .signing-identity)"
fi
# Deliberately not `find-identity -v`: -v lists only identities with a trusted
# chain, and a self-signed root is never trusted even though codesign signs with
# it fine. Using -v here silently falls back to ad-hoc on every build.
if [ -n "$IDENTITY" ] && ! security find-identity -p codesigning | grep -Fq "\"$IDENTITY\""; then
    printf 'Warning: signing identity "%s" is unavailable; using ad-hoc signing.\n' "$IDENTITY"
    IDENTITY="-"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier local.amrut.LidPlane build/LidPlane.app
if [ "$IDENTITY" = "-" ]; then
    printf 'Warning: ad-hoc signed. Screen Recording must be re-granted after every build.\n'
    printf '         Run ./setup-dev.sh once to fix this permanently.\n'
fi
printf 'Built %s/build/LidPlane.app\n' "$PWD"
