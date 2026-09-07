#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
seg="$here/../segments/agent_pane_dots.sh"

# powerline's user-segments dir: the config var when exported, else the conventional path.
dir="${TMUX_POWERLINE_DIR_USER_SEGMENTS:-${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/segments}"

if [ ! -f "$seg" ]
then
	echo "handlr: segment not found: $seg" >&2
	exit 1
fi

if ! mkdir -p "$dir" 2>/dev/null
then
	echo "handlr: cannot create $dir" >&2
	exit 1
fi

if ! ln -sf "$(cd "$(dirname "$seg")" && pwd)/agent_pane_dots.sh" "$dir/agent_pane_dots.sh"
then
	exit 1
fi

echo "handlr: linked agent_pane_dots.sh -> $dir"
echo "handlr: now add 'agent_pane_dots' to your theme's TMUX_POWERLINE_*_STATUS_SEGMENTS"
