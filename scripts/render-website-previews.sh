#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/validation
output="$(mktemp -d "$PWD/build/validation/website-previews.XXXXXX")"
./scripts/swift-env.sh build
bin_dir="$(./scripts/swift-env.sh build --show-bin-path)"
PASTEPAL_PREVIEW_OUTPUT="$output" \
PASTEPAL_PREVIEW_IMAGE="$PWD/resources/IconSources/PastePal-selected-logo.png" \
"$bin_dir/PastePal" --render-website-previews
printf '原生面板已导出到：%s\n' "$output"
