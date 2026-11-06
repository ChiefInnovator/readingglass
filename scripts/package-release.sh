#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version="${1:-}"
version="${version#v}"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "Usage: scripts/package-release.sh vMAJOR.MINOR.PATCH"
    exit 1
fi
source_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' ReadingGlass.xcodeproj/Configuration/Info.plist)"
if [[ "$source_version" != "$version" ]]; then
    print -u2 "Release tag $version does not match app version $source_version"
    exit 1
fi
READINGGLASS_CONFIGURATION=Release ./scripts/build.sh
app=".build/DerivedData/Build/Products/Release/ReadingGlass.app"
codesign --verify --deep --strict "$app"
test -f "$app/Contents/Resources/ReadingGlass-LICENSE.txt"
test -d "$app/Contents/Resources/LaMa512.mlmodelc"
mkdir -p .build/releases
archive="ReadingGlass-${version}-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" ".build/releases/$archive"
(cd .build/releases && shasum -a 256 "$archive" > SHA256SUMS)
print "Packaged: $PWD/.build/releases/$archive"
print "Preview package: not notarized. Do not label it as a notarized distribution."
