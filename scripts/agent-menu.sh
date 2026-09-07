#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=/dev/null
. "$here/agent-status-lib.sh"

client="${1:-}"
copt=()
if [ -n "$client" ]
then
	copt=(-c "$client")
fi

session=$(tmux display-message "${copt[@]}" -p '#{session_name}' 2>/dev/null || tmux display-message -p '#{session_name}')

# Portable colors (named/256, which resolve against the terminal palette);
# state colors come from the shared _handlr_color (honors @handlr-color-*).
label_color() {
	case "$1" in
		claude)
			tmux show-option -gqv @handlr-label-color-claude 2>/dev/null | grep . || printf 'colour173'
			;;
		*)
			printf 'colour252'
			;;
	esac
}
state_color() { _handlr_color "$1"; }

args=()
while IFS=$'\t' read -r pane type state tty widx wname pid cwd title
do
	[ -n "$pane" ] || continue
	# Pad the plaintext first, then wrap in #[fg] so the styling can't skew columns.
	type_f=$(printf '%-9s' "$type")
	state_f=$(printf '%-12s' "$state")
	label="#[fg=$(label_color "$type")]$(emoji_for "$type") #[fg=colour252]${type_f} #[fg=$(state_color "$state")]${state_f}#[fg=colour244] ${widx}:${wname}.${pane#%}"
	# Jump without a client: select-window/select-pane lose client context in
	# some binding contexts; a fresh `tmux` subprocess is reliable.
	cmd="run-shell \"tmux select-window -t $pane ; tmux select-pane -t $pane\""
	args+=("$label" "" "$cmd")
done < <(enum_agents "$session")

# Portable popup chrome (defaults follow the terminal palette); the same
# @handlr-popup-style / @handlr-popup-border-style options handlr.tmux uses for prefix+A.
pstyle=$(tmux show-option -gqv @handlr-popup-style 2>/dev/null | grep . || printf 'bg=default,fg=default')
pborder=$(tmux show-option -gqv @handlr-popup-border-style 2>/dev/null | grep . || printf 'fg=default,bg=default')

if [ ${#args[@]} -eq 0 ]
then
	args=("#[fg=colour244]no agents in this session" "" "")
fi

args+=("")   # separator
args+=("#[fg=colour110]  ▸ full dashboard" "d" \
	"display-popup -E -w 92% -h 60% -b rounded -T ' agents ' -s '$pstyle' -S '$pborder' '$here/agent-dashboard.sh'")

tmux display-menu "${copt[@]}" -T "#[align=centre,fg=yellow] agents " -x R -y S "${args[@]}"
