#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
flavor="${1:-preview}"
case "$flavor" in
  preview) configuration="${2:-debug}"; app_name="PastePal Preview" ;;
  debug) flavor=preview; configuration=debug; app_name="PastePal Preview" ;;
  release) configuration=release; app_name="PastePal" ;;
  *) echo '用法：./scripts/build-app.sh [preview [debug|release]|debug|release]' >&2; exit 2 ;;
esac
if [[ "$configuration" != debug && "$configuration" != release ]] || [[ $# -gt 2 ]] || { [[ $# -eq 2 ]] && [[ "${1}" != preview ]]; }; then
  echo '用法：./scripts/build-app.sh [preview [debug|release]|debug|release]' >&2
  exit 2
fi
codesign_identity="${PASTEPAL_CODESIGN_IDENTITY:-EDAF5540E35BBA649726925FC5E5B0176BB07AEB}"
if ! security find-identity -v -p codesigning | grep -Fq "$codesign_identity"; then
  printf '缺少有效签名身份：%s\n' "$codesign_identity" >&2
  printf '可通过 PASTEPAL_CODESIGN_IDENTITY 显式指定其他有效身份。\n' >&2
  exit 3
fi
./scripts/swift-env.sh build -c "$configuration"
bin_dir="$(./scripts/swift-env.sh build -c "$configuration" --show-bin-path)"
app_dir="$PWD/build/$app_name.app"
legacy_app_dirs=("$PWD/build/SidePocket.app" "$PWD/build/本地剪贴板.app")
mkdir -p "$PWD/build"
staging_dir="$(mktemp -d "$PWD/build/.PastePal.$flavor.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir/Contents/MacOS" "$staging_dir/Contents/Resources"
cp -f "$bin_dir/PastePal" "$staging_dir/Contents/MacOS/PastePal"
cp -f Resources/Info.plist "$staging_dir/Contents/Info.plist"
plutil -insert PastePalBuildFlavor -string "$flavor" "$staging_dir/Contents/Info.plist"
plutil -insert PastePalBuildConfiguration -string "$configuration" "$staging_dir/Contents/Info.plist"
if [[ "$flavor" == preview ]]; then
  plutil -replace CFBundleName -string "$app_name" "$staging_dir/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "$app_name" "$staging_dir/Contents/Info.plist"
fi
cp -f Resources/AppIcon.icns "$staging_dir/Contents/Resources/AppIcon.icns"
cp -f Resources/LICENSE-KeyboardShortcuts "$staging_dir/Contents/Resources/"
for localization in "$PWD"/Resources/*.lproj; do
  [[ -d "$localization" ]] || continue
  target_localization="$staging_dir/Contents/Resources/$(basename "$localization")"
  ditto "$localization" "$target_localization"
  if [[ "$flavor" == preview && -f "$target_localization/InfoPlist.strings" ]]; then
    plutil -convert xml1 "$target_localization/InfoPlist.strings"
    plutil -replace CFBundleName -string "$app_name" "$target_localization/InfoPlist.strings"
    plutil -replace CFBundleDisplayName -string "$app_name" "$target_localization/InfoPlist.strings"
  fi
done
resource_bundles=("PastePal_PastePal.bundle" "PastePal_PastePalLocalization.bundle" "KeyboardShortcuts_KeyboardShortcuts.bundle")
for bundle_name in "${resource_bundles[@]}"; do
  resource="$bin_dir/$bundle_name"
  [[ -d "$resource" ]] || { printf '缺少资源 Bundle：%s\n' "$resource" >&2; exit 1; }
  ditto "$resource" "$staging_dir/Contents/Resources/$bundle_name"
done
codesign --force --deep --sign "$codesign_identity" "$staging_dir"
codesign --verify --deep --strict "$staging_dir"
if pgrep -f "$app_dir/Contents/MacOS/PastePal" >/dev/null; then
  mkdir -p "$PWD/build/validation"
  candidate_dir="$PWD/build/validation/$app_name.candidate.$(date +%Y%m%d-%H%M%S).app"
  mv "$staging_dir" "$candidate_dir"
  trap - EXIT
  printf '固定路径应用正在运行，未替换：%s\n' "$app_dir" >&2
  printf '已保留完整候选包：%s\n' "$candidate_dir" >&2
  exit 4
fi
rm -rf "$app_dir"
mv "$staging_dir" "$app_dir"
for legacy_app_dir in "${legacy_app_dirs[@]}"; do
  if [[ -e "$legacy_app_dir" || -L "$legacy_app_dir" ]]; then
    rm -rf "$legacy_app_dir"
    printf '已移除旧构建产物：%s\n' "$legacy_app_dir"
  fi
done
trap - EXIT
codesign --verify --deep --strict "$app_dir"
printf '已使用签名身份 %s 构建 %s（%s）：%s\n' "$codesign_identity" "$flavor" "$configuration" "$app_dir"
