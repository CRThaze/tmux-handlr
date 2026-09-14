#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Option reader in the canonical tmux-plugin style (mirrors tpm/tmux-resurrect).
get_tmux_option() {
	local option="$1"
	local default_value="$2"
	local value
	value="$(tmux show-option -gqv "$option")"
	if [ -z "$value" ]
	then
		printf '%s' "$default_value"
	else
		printf '%s' "$value"
	fi
}

set_binds() {
	local menu_key
	local dash_key
	local sidebar_key
	local dismiss_key
	local style
	local border
	menu_key="$(get_tmux_option '@handlr-menu-key' 'a')"
	dash_key="$(get_tmux_option '@handlr-dashboard-key' 'A')"
	# Sidebar is opt-in: empty default binds no key (prefix+s is tmux's own
	# session tree), so the user picks a free key to enable it.
	sidebar_key="$(get_tmux_option '@handlr-sidebar-key' '')"
	# Dismiss the current pane's done flash (back to idle); opt-in, empty = no bind.
	dismiss_key="$(get_tmux_option '@handlr-dismiss-key' '')"
	# Dashboard colors; overridable to match any theme.
	style="$(get_tmux_option '@handlr-popup-style' 'bg=default,fg=default')"
	border="$(get_tmux_option '@handlr-popup-border-style' 'fg=default,bg=default')"
	# Bind the keys.
	tmux bind-key "$menu_key" run-shell "$CURRENT_DIR/scripts/agent-menu.sh '#{client_name}'"
	tmux bind-key "$dash_key" display-popup -E -w 92% -h 60% -b rounded \
		-T ' agents ' -s "$style" -S "$border" "$CURRENT_DIR/scripts/agent-dashboard.sh"
	if [ -n "$sidebar_key" ]
	then
		tmux bind-key "$sidebar_key" run-shell "$CURRENT_DIR/scripts/agent-sidebar.sh"
	fi
	if [ -n "$dismiss_key" ]
	then
		tmux bind-key "$dismiss_key" run-shell "$CURRENT_DIR/scripts/agent-dismiss.sh '#{pane_id}'"
	fi
}

start_daemon() {
	# One implementation of "make sure the daemon is up" lives in the status lib
	# (_handlr_ensure_daemon: pgrep-guarded so it can't double-spawn). Reuse it here
	# so init and the status-line supervisor share the exact same spawn guard,
	# instead of a second pidfile-only check that dups when the pidfile desyncs.
	# shellcheck source=scripts/agent-status-lib.sh
	. "$CURRENT_DIR/scripts/agent-status-lib.sh" 2>/dev/null || return 0
	_handlr_ensure_daemon
}

# Non-powerline users get the indicator appended to status-right as a #() job.
# Under powerline we skip it (powerline owns status-right); use the segment there.
setup_status_right() {
	if [ "$(get_tmux_option '@handlr-status-right' 'off')" = 'on' ]
	then
		local cur
		cur="$(tmux show-option -gqv status-right)"
		case "$cur" in
			*handlr-status.sh*)
				return 0  # Already appended.
				;;
		esac
		tmux set -g status-right "${cur} #($CURRENT_DIR/scripts/handlr-status.sh)"
	else
		return 0  # Not enabled
	fi
}

main() {
	# Export the handlr directory so the support scripts can find it.
	tmux set-environment -g TMUX_HANDLR_DIR "$CURRENT_DIR"
	if [ "$(get_tmux_option '@handlr-setup-binds' 'on')" = 'on' ]
	then
		set_binds
	fi
	if [ "$(get_tmux_option '@handlr-install-segment' 'off')" = 'on' ]
	then
		"$CURRENT_DIR/scripts/install-segment.sh" >/dev/null 2>&1
	fi
	setup_status_right
	if [ "$(get_tmux_option '@handlr-daemon' 'on')" = 'on' ]
	then
		start_daemon
	fi
}
main
