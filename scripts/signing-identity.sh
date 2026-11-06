#!/bin/zsh
set -euo pipefail
if [[ -n "${READINGGLASS_SIGN_IDENTITY:-}" ]]; then
    print -r -- "$READINGGLASS_SIGN_IDENTITY"
else
    # A stable designated requirement preserves Screen Recording consent across
    # rebuilds. Machines without a developer certificate can still build ad hoc.
    identity="$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    print -r -- "${identity:--}"
fi
