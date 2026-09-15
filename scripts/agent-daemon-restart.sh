#!/usr/bin/env bash
set -uo pipefail

# Restart the detect.py detection daemon: kill the running one (if any), then let
# the status lib respawn it through its usual spawn guard. Bound to a key via
# @handlr-restart-key. Handy after editing detection rules, or to force a clean
# slate when a pane's state looks wedged.

DIR="${TMUX_HANDLR_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
rt="${XDG_RUNTIME_DIR:-/tmp}/tmux-handlr"
pidfile="$rt/daemon.pid"

# Kill any running daemon. The [d]etect trick keeps the pattern from matching this
# script's own argv (mirrors _handlr_ensure_daemon's pgrep guard).
if command -v pkill >/dev/null 2>&1
then
	pkill -f '[d]etect\.py --daemon' 2>/dev/null || true
elif [ -f "$pidfile" ]
then
	pid="$(cat "$pidfile" 2>/dev/null || :)"
	if [ -n "$pid" ]
	then
		kill "$pid" 2>/dev/null || true
	fi
fi
rm -f "$pidfile" 2>/dev/null || true

# Wait for it to actually exit, so the ensure guard below doesn't see the dying
# process in pgrep and skip the respawn.
if command -v pgrep >/dev/null 2>&1
then
	for _ in 1 2 3 4 5 6 7 8 9 10
	do
		pgrep -f '[d]etect\.py --daemon' >/dev/null 2>&1 || break
		sleep 0.2
	done
fi

# Respawn via the shared guard (respects @handlr-daemon off; won't double-spawn).
# shellcheck source=agent-status-lib.sh
. "$DIR/scripts/agent-status-lib.sh" 2>/dev/null || exit 0
_handlr_ensure_daemon

tmux display-message "handlr: detection daemon restarted" 2>/dev/null || true
