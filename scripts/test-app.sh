#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .zig-cache/desktop
xcrun swiftc -swift-version 5 desktop/Models.swift tests/AppModelTests.swift -o .zig-cache/desktop/model-tests
.zig-cache/desktop/model-tests
