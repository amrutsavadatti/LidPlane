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
codesign --force --sign - --identifier local.amrut.LidPlane build/LidPlane.app
printf 'Built %s/build/LidPlane.app\n' "$PWD"
