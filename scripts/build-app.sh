#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
APP="zig-out/Simutex.app"
BUILD=".zig-cache/desktop"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -target arm64-apple-macosx15.0 -fobjc-arc -fblocks -O2 -mmacosx-version-min=15.0 -isysroot "$SDK" -c desktop/SimulatorBridge.m -o "$BUILD/SimulatorBridge.o"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 -sdk "$SDK" -import-objc-header desktop/SimulatorBridge.h desktop/Models.swift desktop/SimulatorView.swift desktop/Inspector.swift desktop/App.swift "$BUILD/SimulatorBridge.o" -framework AppKit -framework MetalKit -framework IOSurface -o "$APP/Contents/MacOS/Simutex"
cp zig-out/bin/simutex "$APP/Contents/Resources/simutex"
VERSION=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -1)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Simutex</string>
<key>CFBundleIdentifier</key><string>com.scchan.simutex</string>
<key>CFBundleName</key><string>Simutex</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/simutex"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
