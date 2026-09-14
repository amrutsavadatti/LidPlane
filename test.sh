#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/Motion.swift Tests/MotionTests.swift -o build/motion-tests
build/motion-tests
