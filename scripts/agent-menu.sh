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
cur=$(tmux display-message "${copt[@]}" -p '#{pane_id}' 2>/dev/null || :)
all=""
if _handlr_all_sessions
then
	all=1
fi

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
start=""   # menu index of the pane the client is in, if it is an agent
n=0
while IFS=$'\t' read -r pane type state tty widx wname pid cwd title sname
do
	[ -n "$pane" ] || continue
	# Pad the plaintext first, then wrap in #[fg] so the styling can't skew columns.
	type_f=$(printf '%-9s' "$type")
	state_f=$(printf '%-12s' "$state")
	where="${widx}:${wname}.${pane#%}"
	if [ -n "$all" ]
	then
		where="${sname}:${where}"
	fi
	label="#[fg=$(label_color "$type")]$(emoji_for "$type") #[fg=colour252]${type_f} #[fg=$(state_color "$state")]${state_f}#[fg=colour244] ${where}"
	# Jump without a client: select-window/select-pane lose client context in
	# some binding contexts; a fresh `tmux` subprocess is reliable. switch-client
	# first, since the pane may live in another session (a pane id is a valid
	# session target: tmux resolves the session containing it).
	cmd="run-shell \"tmux switch-client ${copt[*]} -t $pane ; tmux select-window -t $pane ; tmux select-pane -t $pane\""
	args+=("$label" "" "$cmd")
	if [ "$pane" = "$cur" ]
	then
		start="$n"
	fi
	n=$((n + 1))
done < <(enum_agents "$session")

# Portable popup chrome (defaults follow the terminal palette); the same
# @handlr-popup-style / @handlr-popup-border-style options handlr.tmux uses for prefix+A.
pstyle=$(tmux show-option -gqv @handlr-popup-style 2>/dev/null | grep . || printf 'bg=default,fg=default')
pborder=$(tmux show-option -gqv @handlr-popup-border-style 2>/dev/null | grep . || printf 'fg=default,bg=default')

if [ ${#args[@]} -eq 0 ]
then
	if [ -n "$all" ]
	then
		args=("#[fg=colour244]no agents" "" "")
	else
		args=("#[fg=colour244]no agents in this session" "" "")
	fi
fi

args+=("")   # separator
args+=("#[fg=colour110]  ▸ full dashboard" "d" \
	"display-popup -E -w 92% -h 60% -b rounded -T ' agents ' -s '$pstyle' -S '$pborder' '$here/agent-dashboard.sh'")

# -C opens the menu with the current agent's row selected. Older tmux lacks the
# flag and rejects the whole command, so fall back to an unselected menu there.
if [ -n "$start" ] \
	&& tmux display-menu "${copt[@]}" -C "$start" -T "#[align=centre,fg=yellow] agents " -x R -y S "${args[@]}" 2>/dev/null
then
	exit 0
fi
tmux display-menu "${copt[@]}" -T "#[align=centre,fg=yellow] agents " -x R -y S "${args[@]}"
