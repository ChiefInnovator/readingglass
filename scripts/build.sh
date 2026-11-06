#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
configuration="${READINGGLASS_CONFIGURATION:-Debug}"
case "$configuration" in Debug|Release) ;; *) print -u2 "Configuration must be Debug or Release"; exit 1 ;; esac
./scripts/prepare-background-model.sh
identity="$(./scripts/signing-identity.sh)"
team="${READINGGLASS_DEVELOPMENT_TEAM:-$(print -r -- "$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')}"
build_settings=("CODE_SIGN_IDENTITY=$identity" "CODE_SIGN_STYLE=Manual" "ARCHS=arm64")
if [[ -n "$team" ]]; then build_settings+=("DEVELOPMENT_TEAM=$team"); fi
if ! xcodebuild -project ReadingGlass.xcodeproj -scheme ReadingGlass \
    -configuration "$configuration" -derivedDataPath .build/DerivedData \
    "${build_settings[@]}" build > .build/build.log 2>&1; then
    tail -80 .build/build.log
    exit 1
fi
print "Built: $PWD/.build/DerivedData/Build/Products/$configuration/ReadingGlass.app"
