#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: agent-state.sh --agent dsh --state running [--pane %N]
States: running | needs-input | done | idle | off   (off/empty clears it).
EOF
}

agent=""; state=""; pane="${TMUX_PANE:-}"
while [ $# -gt 0 ]
do
	case "$1" in
		-h|--help)
			usage
			exit 0
			;;
		--agent)
			agent="${2:-}"
			shift 2
			;;
		--state)
			state="${2:-}"
			shift 2
			;;
		--pane)
			pane="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
	esac
done
[ -n "$pane" ] || exit 0

tagvar="TMUX_AGENT_PANE_${pane}_AGENT"      # enum reads this to refine the type
dir="${XDG_RUNTIME_DIR:-/tmp}/tmux-handlr/override"
mkdir -p "$dir" 2>/dev/null || true
f="$dir/${pane}"

# Agent exited: clear both the type tag and the state override, so a pane that
# later reuses this id can't inherit a stale dsh/claude label or state.
if [ "$state" = off ]
then
	tmux set-environment -gu "$tagvar" 2>/dev/null || true
	rm -f "$f" 2>/dev/null || true
	exit 0
fi

# Live agent: keep the type tag current.
if [ -n "$agent" ]
then
	tmux set-environment -g "$tagvar" "$agent" 2>/dev/null || true
fi

# Authoritative state override for the daemon (state + epoch, TTL-checked there).
case "$state" in
	"")
		rm -f "$f" 2>/dev/null || true
		;;
	*)
		printf '%s %s\n' "$state" "$(date +%s)" > "$f" 2>/dev/null || true
		;;
esac
