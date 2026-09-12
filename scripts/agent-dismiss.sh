#!/usr/bin/env bash
set -uo pipefail

# Dismiss the transient "done" flash, sending a pane back to idle now instead of
# waiting out @handlr-done-window. Writes a one-shot marker the detect.py daemon
# consumes on its next tick (it ignores the marker while the agent is live, so
# this only ever clears a done flash, never a running/needs-input state).
#
#   agent-dismiss.sh [%pane]   dismiss one pane (default: $TMUX_PANE, the caller)
#   agent-dismiss.sh --all     dismiss every pane currently showing done

rt="${XDG_RUNTIME_DIR:-/tmp}/tmux-handlr"
mkdir -p "$rt/dismiss" 2>/dev/null || true

if [ "${1:-}" = "--all" ]
then
	cache="$rt/state.tsv"
	[ -r "$cache" ] || exit 0
	while IFS=$'\t' read -r pane state
	do
		if [ "$state" = done ]
		then
			touch "$rt/dismiss/$pane" 2>/dev/null || true
		fi
	done < "$cache"
	exit 0
fi

pane="${1:-${TMUX_PANE:-}}"
[ -n "$pane" ] || exit 0
touch "$rt/dismiss/$pane" 2>/dev/null || true
