#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=/dev/null
. "$here/agent-status-lib.sh" 2>/dev/null || exit 0
render_pane_indicators
