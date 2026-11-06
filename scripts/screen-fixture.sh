#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
bundle="$PWD/.build/ScreenFixture.app"
mkdir -p "$bundle/Contents/MacOS"
xcrun swiftc -parse-as-library -D SCREEN_FIXTURE -swift-version 6 \
    -target arm64-apple-macos15.0 Tests/Fixtures/ScreenFixture.swift \
    -o "$bundle/Contents/MacOS/ScreenFixture"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.richardcrane.readingglass.fixture</string>
<key>CFBundleExecutable</key><string>ScreenFixture</string>
<key>CFBundleName</key><string>ReadingGlass Synthetic Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$bundle" 2>/dev/null
print "Synthetic fixture ready: $bundle"
