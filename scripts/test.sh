#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
# Xcode forwards TEST_RUNNER_ variables into the hosted test process.
export TEST_RUNNER_READINGGLASS_TEST_REAL_MODEL="${READINGGLASS_TEST_REAL_MODEL:-0}"
export TEST_RUNNER_READINGGLASS_VALIDATION_DIR="${READINGGLASS_VALIDATION_DIR:-}"
./scripts/prepare-background-model.sh
result=".build/Tests-$(date +%Y%m%d-%H%M%S).xcresult"
identity="$(./scripts/signing-identity.sh)"
team="${READINGGLASS_DEVELOPMENT_TEAM:-$(print -r -- "$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')}"
build_settings=("CODE_SIGN_IDENTITY=$identity" "CODE_SIGN_STYLE=Manual")
if [[ -n "$team" ]]; then build_settings+=("DEVELOPMENT_TEAM=$team"); fi
if ! xcodebuild -project ReadingGlass.xcodeproj -scheme ReadingGlass \
    -configuration Debug -derivedDataPath .build/DerivedData \
    -destination 'platform=macOS,arch=arm64' "${build_settings[@]}" \
    -resultBundlePath "$result" test > .build/test.log 2>&1; then
    tail -100 .build/test.log
    exit 1
fi
tail -14 .build/test.log
print "Results: $PWD/$result"
