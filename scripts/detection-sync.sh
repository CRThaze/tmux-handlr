#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
data="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-handlr/detection"
mkdir -p "$data"
exec python3 "$here/sync_detection.py" --out "$data" "$@"
