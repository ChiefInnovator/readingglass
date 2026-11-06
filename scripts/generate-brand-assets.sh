#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/brand/AppIcon.iconset
swift scripts/generate-brand-assets.swift
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" site/assets/app-icon.png --out ".build/brand/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" site/assets/app-icon.png --out ".build/brand/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/brand/AppIcon.iconset -o Resources/AppIcon.icns
