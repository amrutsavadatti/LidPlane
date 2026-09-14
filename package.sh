#!/bin/bash
# Builds a distributable .dmg.
#
# The app is signed with a self-signed certificate, which Gatekeeper does not
# trust, so a downloaded copy is blocked on first launch and the user has to go
# through Privacy & Security > Open Anyway. That is the accepted trade for not
# enrolling in the Apple Developer Program. Those steps live on the download
# page rather than in the image, since the user has to read them before the app
# will open at all.
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
DMG="$OUT_DIR/LidPlane.dmg"
STAGING="$(mktemp -d)"
# The download page is a separate repository. It lives alongside by default;
# point LIDPLANE_SITE_DIR elsewhere if you move it. Only its version and size
# text is touched; the disk image itself goes to GitHub Releases.
SITE_DIR="${LIDPLANE_SITE_DIR:-Website}"
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

VOLNAME="LidPlane $VERSION"
mkdir -p "$STAGING/.background"
# Finder lays the background out by PIXEL count against the window's POINT
# size, ignoring DPI entirely. So this image must be exactly 1000x500 pixels to
# fill a 1000x500pt window. Two things that do not work: a 2x PNG tagged 144 DPI
# (Finder shows a 1000x500 pixel corner of it), and `tiffutil -cathidpicheck`
# (it drops the DPI and the 2x rep becomes a 2000x1000 POINT image). The cost is
# a slightly soft background on Retina, which beats a cropped one.
cp Resources/dmg-background.png "$STAGING/.background/background.png"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Styling has to happen on a writable image: Finder stores the window geometry
# and background in a .DS_Store, which cannot be written to a compressed one.
# So build read-write, decorate, then convert.
RW_DIR="$(mktemp -d)"
RW_DMG="$RW_DIR/rw.dmg"
SIZE_MB=$(( $(du -sk "$STAGING" | cut -f1) / 1024 + 40 ))
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov \
    -format UDRW -size "${SIZE_MB}m" -quiet "$RW_DMG"

# A stale mount of the same name makes macOS append " 1" to the mount point, so
# the path can never be assumed — read it back from attach instead.
for stale in /Volumes/LidPlane*; do
    [ -d "$stale" ] && hdiutil detach "$stale" -force -quiet 2>/dev/null || true
done
ATTACH="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT="$(printf '%s\n' "$ATTACH" | grep -o '/Volumes/.*$' | tail -1)"
DEV="$(printf '%s\n' "$ATTACH" | grep '^/dev/' | head -1 | awk '{print $1}')"
MOUNTED_NAME="$(basename "$MOUNT")"

# Finder automation needs an Automation permission grant, and a headless or
# locked session cannot show that prompt. A plain disk image still installs
# perfectly well, so a failure here is cosmetic and must not fail the build.
printf 'Styling the disk-image window…\n'
if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$MOUNTED_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {160, 120, 1160, 648}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 118
        set text size of opts to 13
        set background picture of opts to file ".background:background.png"
        set position of item "LidPlane.app" of container window to {260, 290}
        set position of item "Applications" of container window to {740, 290}
        update without registering applications
        delay 1
        close
        open
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {160, 120, 1160, 648}
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT
then
    printf 'Window styled.\n'
else
    printf 'Could not style the window (Finder automation unavailable).\n'
    printf 'The disk image is still valid, just unstyled.\n'
fi

sync
# Detach by device node; it survives a renamed or busy mount point. Never let a
# stubborn unmount fail the build after the image itself is sound.
hdiutil detach "$DEV" -quiet 2>/dev/null \
    || hdiutil detach "$DEV" -force -quiet 2>/dev/null \
    || true
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$DMG"
rm -rf "$RW_DIR"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ' | sed -e 's/M$/ MB/' -e 's/K$/ KB/')"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

printf '\nWrote %s (%s)\n' "$DMG" "$SIZE"
printf 'SHA-256: %s\n' "$SHA"

# The disk image is hosted as a GitHub Release asset, not in the website repo.
# The site links to releases/latest/download/LidPlane.dmg, which only resolves if
# every release attaches a file with exactly that name — hence no version in it.
# Version and size on the page are still generated here rather than typed.
if [ -f "$SITE_DIR/index.html" ]; then
    /usr/bin/sed -i '' \
        -e "s|Version [0-9.]* · [^·]*· macOS|Version $VERSION · $SIZE · macOS|g" \
        "$SITE_DIR/index.html"
    printf 'Updated version and size in %s/index.html.\n' "$SITE_DIR"
fi

cat <<EOF

Next, publish the release on GitHub:
  tag:     v$VERSION
  asset:   $DMG   (upload as LidPlane.dmg — do not rename it)
  notes:   SHA-256 $SHA
EOF
