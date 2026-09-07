#!/bin/bash
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
case "${1:-}" in
  build|test|run)
    task_root="$(cd "$(dirname "$0")/.." && pwd)"
    cd "$task_root"
    swift package resolve
    python3 scripts/prepare-dependencies.py
    ;;
esac
exec swift "$@"
