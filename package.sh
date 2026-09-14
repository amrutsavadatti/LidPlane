#!/bin/bash
# Builds a distributable .dmg.
#
# The app is signed with a self-signed certificate, which Gatekeeper does not
# trust, so a downloaded copy is blocked on first launch and the user has to go
# through Privacy & Security > Open Anyway. That is the accepted trade for not
# enrolling in the Apple Developer Program. Instructions ride along inside the
# disk image, because the user cannot read anything in the app until they have
# already got past the block.
#
# Signing still matters even though it does not satisfy Gatekeeper: it fixes the
# app's designated requirement to the certificate rather than the binary hash,
# so a user who grants Screen Recording keeps that grant across updates. Ad-hoc
# signed releases would force a re-grant on every version.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LidPlane.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
OUT_DIR="dist"
DMG="$OUT_DIR/LidPlane-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

printf '== Packaging LidPlane %s ==\n\n' "$VERSION"

bash build.sh >/dev/null
printf 'Built %s\n' "$APP"

REQUIREMENT="$(codesign -d --requirements - "$APP" 2>&1 | grep designated || true)"
if printf '%s' "$REQUIREMENT" | grep -q cdhash; then
    cat <<EOF

Refusing to package: the app is ad-hoc signed.

Its designated requirement is keyed to the binary hash, so every release would
be a different app to TCC and users would have to re-grant Screen Recording on
every single update.

Run ./setup-dev.sh first.
EOF
    exit 1
fi
printf 'Signed with a stable identity:\n  %s\n\n' "${REQUIREMENT#*designated => }"

codesign --verify --deep --strict "$APP"
printf 'Signature verifies.\n'

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/Open Me First.txt" <<'EOF'
LidPlane
========

1. Drag LidPlane to the Applications folder.

2. Open Applications and double-click LidPlane.

   macOS will refuse, saying it cannot verify the developer. This is
   expected. LidPlane is signed, but not notarized by Apple, and macOS
   blocks anything it has not seen notarized.

3. Open System Settings > Privacy & Security.

   Scroll down. There will be a message about LidPlane being blocked,
   with an "Open Anyway" button. Click it.

4. Double-click LidPlane again and choose Open.

   You only have to do this once.

On first launch LidPlane asks for Screen Recording permission and then
measures your lid's hinge range. It freezes an image of your own display
while the lid moves; nothing is written to disk or sent anywhere.

LidPlane lives in the menu bar and has no window. Click its icon for the
on/off switch, right-click for calibration and quit.
EOF

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
hdiutil create -volname "LidPlane $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO -quiet "$DMG"

printf '\nWrote %s (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
printf 'SHA-256: %s\n' "$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
printf '\nUsers must follow the Open Anyway steps in the disk image.\n'
