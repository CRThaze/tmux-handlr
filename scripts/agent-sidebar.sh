#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Toggle a narrow "sidebar" pane in the current window that runs the compact
# dashboard. tmux has no global/dockable panel, so this is per-window: it opens
# beside the window you trigger it from. The pane carries a pane-scoped
# @handlr_sidebar flag, so a second press finds and closes it.
width="$(tmux show-option -gqv @handlr-sidebar-width 2>/dev/null || true)"
if ! [[ "$width" =~ ^[0-9]+$ ]]
then
	width=24
fi
position="$(tmux show-option -gqv @handlr-sidebar-position 2>/dev/null || true)"

# list-panes with no -t stays within the current window, so toggling only ever
# touches this window's sidebar, never one in another window.
existing="$(tmux list-panes -F '#{pane_id} #{@handlr_sidebar}' 2>/dev/null \
	| awk '$2 == "1" { print $1; exit }')"
if [ -n "$existing" ]
then
	tmux kill-pane -t "$existing"
	exit 0
fi

# -d keeps focus on your work pane; -b opens the new pane before (to the left).
if [ "$position" = right ]
then
	pane="$(tmux split-window -h -d -l "$width" -P -F '#{pane_id}' \
		"$here/agent-dashboard.sh --compact")"
else
	pane="$(tmux split-window -hb -d -l "$width" -P -F '#{pane_id}' \
		"$here/agent-dashboard.sh --compact")"
fi
tmux set-option -p -t "$pane" @handlr_sidebar 1 2>/dev/null || true
