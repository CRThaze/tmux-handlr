# shellcheck shell=bash

run_segment() {
	# Locate the lib via TMUX_HANDLR_DIR (exported by handlr.tmux), so this segment
	# works wherever it's installed (powerline user-segments dir, a symlink, or in
	# the plugin). Falls back to sibling layouts if the env var is unset.
	local lib=""
	local d
	local here
	local cand
	d=$(tmux show-environment -g TMUX_HANDLR_DIR 2>/dev/null | sed -n 's/^TMUX_HANDLR_DIR=//p')
	if [ -n "$d" ] && [ -r "$d/scripts/agent-status-lib.sh" ]
	then
		lib="$d/scripts/agent-status-lib.sh"
	fi
	if [ -z "$lib" ]
	then
		here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd) || return 0
		for cand in "$here/../scripts/agent-status-lib.sh" "$here/agent-status-lib.sh"
		do
			if [ -r "$cand" ]
			then
				lib="$cand"
				break
			fi
		done
	fi
	[ -n "$lib" ] || return 0
	# shellcheck source=/dev/null
	. "$lib" 2>/dev/null || return 0

	render_pane_indicators
}
