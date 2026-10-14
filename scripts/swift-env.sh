#!/bin/bash
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Apple Git 会注入命令行工具的 SDKROOT；SDK 必须与所选 Xcode 一致。
SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
case "${1:-}" in
  test)
    shift
    set -- test --skip '/testDesktop' "$@"
    ;;
  test-desktop)
    shift
    set -- test --skip '/test(?!Desktop)' "$@"
    ;;
esac
case "${1:-}" in
  build|test|run)
    task_root="$(cd "$(dirname "$0")/.." && pwd)"
    cd "$task_root"
    swift package resolve
    python3 scripts/prepare-dependencies.py
    ;;
esac
exec swift "$@"
