#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_image="Resources/IconSources/PastePal-selected-logo.png"
app_master="Resources/AppIcon.png"
preview="build/validation/icon-preview.png"
mkdir -p build/validation
temporary="$(mktemp -d "${TMPDIR:-/tmp}/PastePal-icons.XXXXXX")"
iconset="$temporary/AppIcon.iconset"
mkdir -p "$iconset"
trap 'rm -rf "$temporary"' EXIT

sips -z 1024 1024 "$source_image" --out "$app_master" >/dev/null
for entry in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  read -r pixels name <<< "$entry"
  sips -z "$pixels" "$pixels" "$app_master" --out "$iconset/$name" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
xcrun swift scripts/render-icon-preview.swift Resources/AppIcon.png Sources/PastePal/Resources/StatusPastePalTemplate.svg "$preview"
printf '已生成应用与状态栏图标资源。\n'
