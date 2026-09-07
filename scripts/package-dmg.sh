#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app_path="${1:-build/PastePal.app}"
version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
architecture="$(lipo -archs "$app_path/Contents/MacOS/PastePal")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo '版本号必须为 X.Y.Z' >&2; exit 2; }
[[ "$architecture" == arm64 ]] || { echo '当前 DMG 发布仅支持 arm64' >&2; exit 2; }
[[ "$(plutil -extract CFBundleName raw "$app_path/Contents/Info.plist")" == PastePal ]] || { echo '仅可打包正式 PastePal.app' >&2; exit 2; }
[[ "$(plutil -extract PastePalBuildFlavor raw "$app_path/Contents/Info.plist")" == release ]] || { echo '需要正式 Release 构建' >&2; exit 2; }
codesign --verify --deep --strict "$app_path"

identity="${PASTEPAL_CODESIGN_IDENTITY:-EDAF5540E35BBA649726925FC5E5B0176BB07AEB}"
mkdir -p build
output="$PWD/build/PastePal-$version-arm64.dmg"
[[ ! -e "$output" ]] || { echo "输出已存在：$output" >&2; exit 2; }
staging="$(mktemp -d "$PWD/build/.dmg.XXXXXX")"
cleanup() {
  python3 - "$staging" <<'PY'
from pathlib import Path
import shutil, sys
path = Path(sys.argv[1])
if path.parent == Path.cwd() / 'build' and path.name.startswith('.dmg.') and not path.is_symlink():
    shutil.rmtree(path)
PY
}
trap cleanup EXIT
mkdir "$staging/payload"
ditto "$app_path" "$staging/payload/PastePal.app"
ln -s /Applications "$staging/payload/Applications"
hdiutil create -volname PastePal -srcfolder "$staging/payload" -fs HFS+ -format UDZO "$staging/PastePal.dmg"
codesign --sign "$identity" "$staging/PastePal.dmg"
codesign --verify --strict "$staging/PastePal.dmg"
hdiutil verify "$staging/PastePal.dmg"
mv "$staging/PastePal.dmg" "$output"
printf '已生成：%s\n' "$output"
