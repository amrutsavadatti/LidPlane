#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache build/RenderCheck.app/Contents/{MacOS,Resources}
xcrun swiftc -swift-version 5 -D RENDER_TEST -module-cache-path "$PWD/build/module-cache" \
    Sources/Renderer.swift Tests/RenderIntegration.swift -o build/RenderCheck.app/Contents/MacOS/RenderCheck
cp Resources/Plane.metal build/RenderCheck.app/Contents/Resources/Plane.metal
if [ "${1:-}" != "--build-only" ]; then
    build/RenderCheck.app/Contents/MacOS/RenderCheck
fi
