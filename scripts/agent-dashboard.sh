#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=/dev/null
. "$here/agent-status-lib.sh"

COMPACT=""
session=""
for arg in "$@"
do
	case "$arg" in
		--compact)
			COMPACT=1
			;;
		*)
			session="$arg"
			;;
	esac
done
if [ -z "$session" ]
then
	session="$(tmux display-message -p '#{session_name}' 2>/dev/null)"
fi

# Standard ANSI / 256-palette colors (they resolve to the terminal theme rather
# than a hardcoded one). TERRA (the claude accent) is a 256-color terracotta.
esc=$'\033'; reset="${esc}[0m"
GREY="${esc}[90m";        CREAM="${esc}[37m"
TERRA="${esc}[38;5;173m"; WHITE="${esc}[37m"
RED="${esc}[31m";         YEL="${esc}[33m"
GRN="${esc}[32m";         CYN="${esc}[36m"
GOLD="${esc}[93m"

declare -A M_CACHE S_CACHE SID_C START COST_C TOK_C
declare -A G_CACHE GW    # type -> label glyph; glyph -> display width (cells)

# Show each agent's type label glyph (the prefix+a menu's emoji_for) beside it.
# 'off' restores the text-only view. Covers both the popup dashboard and the
# compact sidebar, since they are one renderer.
ICONS="$(tmux show-option -gqv @handlr-dashboard-icons 2>/dev/null || true)"
if [ -z "$ICONS" ]
then
	ICONS=on
fi

#####################################################
### ccusage (cost) detection + background refresh ###
#####################################################
CCUSAGE=""
if command -v ccusage >/dev/null 2>&1
then
	CCUSAGE="ccusage"
elif command -v bunx >/dev/null 2>&1
then
	CCUSAGE="bunx ccusage"
fi
COST_ENABLED=""
if [ -n "$CCUSAGE" ]
then
	COST_ENABLED=1
fi
cost_json=""; cost_pid=""; cost_mtime=0
if [ -n "$COST_ENABLED" ]
then
	cost_json=$(mktemp)
	( while true
	do
		$CCUSAGE session --json > "$cost_json.tmp" 2>/dev/null && mv -f "$cost_json.tmp" "$cost_json"
		sleep 20
	  done ) & cost_pid=$!
fi
cleanup() {
	printf '%s' "${esc}[?25h"
	if [ -n "$cost_pid" ]
	then
		kill "$cost_pid" 2>/dev/null
	fi
	if [ -n "$cost_json" ]
	then
		rm -f "$cost_json" "$cost_json.tmp"
	fi
}
trap cleanup EXIT

parse_cost() {   # reload the period -> cost/tokens map from the temp json
	COST_C=(); TOK_C=()
	local period
	local cost
	local tokens
	while IFS=$'\t' read -r period cost tokens
	do
		if [ -n "$period" ]
		then
			COST_C[$period]="$cost"
			TOK_C[$period]="$tokens"
		fi
	done < <(python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for s in d.get("session",[]):
    p=s.get("period")
    if p: print("%s\t%s\t%s" % (p, s.get("totalCost",0), s.get("totalTokens",0)))
' "$cost_json" 2>/dev/null)
}

trunc() {
	if [ "${#1}" -gt "$2" ]
	then
		REPLY="${1:0:$2-1}…"
	else
		REPLY="$1"
	fi
}
fmt_dur() {
	local d=$(( $1/86400 ))
	local h=$(( ($1%86400)/3600 ))
	local m=$(( ($1%3600)/60 ))
	local sec=$(( $1%60 ))
	if [ "$d" -gt 0 ]
	then
		printf -v REPLY '%dd%02dh' "$d" "$h"
	elif [ "$h" -gt 0 ]
	then
		printf -v REPLY '%dh%02dm' "$h" "$m"
	else                      printf -v REPLY '%dm%02ds' "$m" "$sec"; fi
}
fmt_cost() {   # in: float string; out: "$12.34" or a dash
	if [[ "$1" =~ ^[0-9]*\.?[0-9]+ ]]
	then
		printf -v REPLY '$%.2f' "$1"
	else
		REPLY='—'
	fi
}
fmt_tokens() { # in: integer; out: "79.5M" / "812k" / "42" / a dash
	local t="$1"
	if ! [[ "$t" =~ ^[0-9]+$ ]]
	then
		REPLY='—'
	elif [ "$t" -ge 1000000 ]
	then
		printf -v REPLY '%d.%dM' $(( t/1000000 )) $(( (t%1000000)/100000 ))
	elif [ "$t" -ge 1000 ]
	then
		printf -v REPLY '%dk' $(( t/1000 ))
	else REPLY="$t"; fi
}

glyph_cells() {   # REPLY = display columns (1 or 2) of glyph $1, cached in GW
	local w
	if [ -z "${GW[$1]:-}" ]
	then
		w=$(printf '%s' "$1" | wc -L 2>/dev/null || echo 1)
		if ! [[ "$w" =~ ^[0-9]+$ ]] || [ "$w" -lt 1 ]
		then
			w=1
		fi
		GW[$1]="$w"
	fi
	REPLY="${GW[$1]}"
}
icon_pad() {   # REPLY = glyph $1 padded with spaces to a fixed 2-cell slot
	local sp
	glyph_cells "$1"
	sp=$(( 2 - REPLY )); (( sp < 0 )) && sp=0
	if [ "$sp" -gt 0 ]
	then
		printf -v REPLY '%s%*s' "$1" "$sp" ""
	else
		REPLY="$1"
	fi
}

render() {
	local now; printf -v now '%(%s)T' -1
	local cols
	cols=$(tput cols 2>/dev/null || true)
	if ! [[ "$cols" =~ ^[0-9]+$ ]]
	then
		cols="${COLUMNS:-120}"
	fi

	# refresh the cost cache only when the background updater rewrote the file
	if [ -n "$COST_ENABLED" ] && [ -s "$cost_json" ]
	then
		local m; m=$(stat -c %Y "$cost_json" 2>/dev/null || echo 0)
		if [ "$m" != "$cost_mtime" ]
		then
			cost_mtime="$m"
			parse_cost
		fi
	fi

################################
### pass 1: gather + measure ###
################################
	local -a P_ic
	local -a P_glyph
	local -a P_type
	local -a P_state
	local -a P_sc
	local -a P_where
	local -a P_up
	local -a P_model
	local -a P_cost
	local -a P_tok
	local -a P_cwd
	local -a P_title
	local w_type=5
	local w_state=5
	local w_where=5
	local w_up=6
	local w_model=5
	local w_cost=4
	local w_tok=6
	local w_cwd=3
	local w_title=5
	local n=0
	local pane
	local type
	local state
	local tty
	local widx
	local wname
	local pid
	local cwd
	local title
	local model
	local sid
	local sc
	local icol
	local up
	local cwds
	local where
	local et
	local fcost
	local ftok
	while IFS=$'\t' read -r pane type state tty widx wname pid cwd title
	do
		[ -n "$pane" ] || continue
		if [ "${S_CACHE[$pane]:-}" != "$state" ] || [ -z "${M_CACHE[$pane]:-}" ]
		then
			model=$(agent_model "$tty" "$type" "$cwd")
			if [ -z "$model" ]
			then
				model="—"
			fi
			M_CACHE[$pane]="$model"; S_CACHE[$pane]="$state"
			SID_C[$pane]=$(session_id "$type" "$cwd")
		else
			model="${M_CACHE[$pane]}"
		fi
		sid="${SID_C[$pane]:-}"
		if [ -z "${START[$pane]:-}" ]
		then
			et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
			if [ -n "$et" ]
			then
				START[$pane]=$(( now - et ))
			else
				START[$pane]="$now"
			fi
		fi
		fmt_dur $(( now - START[$pane] )); up="$REPLY"
		# sid is empty for dsh and for panes not yet tracked; guard the
		# assoc-array lookup, since an empty subscript is a bash error
		# ("bad array subscript").
		if [ -n "$sid" ]
		then
			fmt_cost "${COST_C[$sid]:-}"
		else
			REPLY='—'
		fi
		fcost="$REPLY"
		if [ -n "$sid" ]
		then
			fmt_tokens "${TOK_C[$sid]:-}"
		else
			REPLY='—'
		fi
		ftok="$REPLY"
		case "$state" in
			needs-input)
				sc="$RED"
				;;
			running)
				sc="$YEL"
				;;
			done)
				sc="$GRN"
				;;
			*)
				sc="$CYN"
				;;
		esac
		if [ "$type" = claude ]
		then
			icol="$TERRA"
		else
			icol="$WHITE"
		fi
		if [ -z "${G_CACHE[$type]:-}" ]
		then
			G_CACHE[$type]="$(emoji_for "$type")"
		fi
		cwds="${cwd/#$HOME/\~}"; where="${widx}:${wname}.${pane#%}"
		P_ic[n]="$icol"; P_glyph[n]="${G_CACHE[$type]}"; P_type[n]="$type"; P_state[n]="$state"; P_sc[n]="$sc"
		P_where[n]="$where"; P_up[n]="$up"; P_model[n]="$model"; P_cost[n]="$fcost"; P_tok[n]="$ftok"
		P_cwd[n]="$cwds"; P_title[n]="$title"
		(( ${#type}  > w_type ))  && w_type=${#type}
		(( ${#state} > w_state )) && w_state=${#state}
		(( ${#where} > w_where )) && w_where=${#where}
		(( ${#up}    > w_up ))    && w_up=${#up}
		(( ${#model} > w_model )) && w_model=${#model}
		(( ${#fcost} > w_cost ))  && w_cost=${#fcost}
		(( ${#ftok}  > w_tok ))   && w_tok=${#ftok}
		(( ${#cwds}  > w_cwd ))   && w_cwd=${#cwds}
		(( ${#title} > w_title )) && w_title=${#title}
		n=$((n+1))
	done < <(enum_agents "$session")

	(( w_type  > 14 )) && w_type=14
	(( w_state > 12 )) && w_state=12
	(( w_where > 30 )) && w_where=30
	(( w_up    > 12 )) && w_up=12
	(( w_model > 32 )) && w_model=32
	local iconw=0
	if [ "$ICONS" != off ]
	then
		iconw=3           # fixed 2-cell icon slot + its separator
	fi
	local used=$(( 2 + 3 + iconw + w_type+1 + w_state+1 + w_where+1 + w_up+1 + w_model+1 ))
	if [ -n "$COST_ENABLED" ]
	then
		used=$(( used + w_cost+1 + w_tok+1 ))
	fi
	local avail=$(( cols - used - 1 )); (( avail < 20 )) && avail=20
	if (( w_cwd + 1 + w_title > avail ))
	then
		local tot=$(( w_cwd + w_title ))
		w_cwd=$(( avail * w_cwd / tot )); w_title=$(( avail - w_cwd - 1 ))
		(( w_cwd   < 8 )) && w_cwd=8
		(( w_title < 8 )) && w_title=8
	fi

#######################################################################
### compact (sidebar) layout: one agent per two lines, narrow-pane ###
#######################################################################
	# Forced by --compact, or auto when the pane is too narrow for the table.
	local compact="$COMPACT"
	if [ -z "$compact" ] && [ "$cols" -lt 60 ]
	then
		compact=1
	fi
	if [ -n "$compact" ]
	then
		local cout="${esc}[H"
		local ci
		local cbase
		local cnm
		local cup
		local cmax
		if (( n == 0 ))
		then
			cout+="  ${GREY}no agents${reset}${esc}[K"$'\n'
		fi
		local cnw
		for (( ci=0; ci<n; ci++ ))
		do
			# line 1: state dot + (optional) type glyph + type name.
			if [ "$ICONS" != off ]
			then
				cnw=$(( cols - 6 ))
			else
				cnw=$(( cols - 4 ))
			fi
			(( cnw < 1 )) && cnw=1
			trunc "${P_type[ci]}" "$cnw"; cnm="$REPLY"
			if [ "$ICONS" != off ]
			then
				cout+=" ${P_sc[ci]}●${reset} ${P_ic[ci]}${P_glyph[ci]} ${cnm}${reset}${esc}[K"$'\n'
			else
				cout+=" ${P_sc[ci]}●${reset} ${P_ic[ci]}${cnm}${reset}${esc}[K"$'\n'
			fi
			# line 2: cwd basename + uptime, packed close (two-space gap).
			cbase="${P_cwd[ci]##*/}"; cup="${P_up[ci]}"
			cmax=$(( cols - 5 - ${#cup} ))   # 3 indent + 2-space gap
			(( cmax < 1 )) && cmax=1
			trunc "$cbase" "$cmax"; cbase="$REPLY"
			cout+="   ${GREY}${cbase}  ${cup}${reset}${esc}[K"$'\n'
		done
		printf '%s%s' "$cout" "${esc}[0J"
		return
	fi

#########################################################################
### pass 2: draw (COST/TOKENS inserted after MODEL only when enabled) ###
#########################################################################
	local out="${esc}[H"
	local line
	local seg
	local i
	local ft
	local fs
	local fw
	local fu
	local fm
	local fk
	local fc
	local fT
	local ipfx=""
	if [ "$ICONS" != off ]
	then
		ipfx="   "        # blank icon slot in the header, matching the row width
	fi
	printf -v line "  %s%s%-${w_type}s %-${w_state}s %-${w_where}s %-${w_up}s %-${w_model}s" \
		"$GREY" "$ipfx" "AGENT" "STATE" "WHERE" "UPTIME" "MODEL"
	if [ -n "$COST_ENABLED" ]
	then
		printf -v seg " %-${w_cost}s %-${w_tok}s" "COST" "TOKENS"
		line+="$seg"
	fi
	printf -v seg " %-${w_cwd}s %s%s" "CWD" "TITLE" "$reset"; line+="$seg"
	out+="${line}${esc}[K"$'\n'$'\n'
	(( n == 0 )) && out+="  ${GREY}no agents in this session${reset}${esc}[K"$'\n'
	for (( i=0; i<n; i++ ))
	do
		trunc "${P_type[i]}"  "$w_type";  ft="$REPLY"
		trunc "${P_state[i]}" "$w_state"; fs="$REPLY"
		trunc "${P_where[i]}" "$w_where"; fw="$REPLY"
		trunc "${P_up[i]}"    "$w_up";    fu="$REPLY"
		trunc "${P_model[i]}" "$w_model"; fm="$REPLY"
		trunc "${P_cwd[i]}"   "$w_cwd";   fc="$REPLY"
		trunc "${P_title[i]}" "$w_title"; fT="$REPLY"
		# Type label glyph (opt out via @handlr-dashboard-icons) in a fixed 2-cell
		# slot, so its variable width can't push the columns off the header; the
		# name stays tinted (P_ic: terracotta for claude, white otherwise) too.
		local ficon=""
		if [ "$ICONS" != off ]
		then
			icon_pad "${P_glyph[i]}"; ficon="${P_ic[i]}${REPLY}${reset} "
		fi
		printf -v line "  %s%s%-${w_type}s%s %s%-${w_state}s%s %-${w_where}s %-${w_up}s %-${w_model}s" \
			"$ficon" "${P_ic[i]}" "$ft" "$reset" \
			"${P_sc[i]}" "$fs" "$reset" "$fw" "$fu" "$fm"
		if [ -n "$COST_ENABLED" ]
		then
			printf -v seg " %s%-${w_cost}s%s %-${w_tok}s" "$GOLD" "${P_cost[i]}" "$reset" "${P_tok[i]}"
			line+="$seg"
		fi
		printf -v seg " %-${w_cwd}s %s" "$fc" "$fT"; line+="$seg"
		out+="${line}${esc}[K"$'\n'
	done
	out+=$'\n'"  ${GREY}q quit · refresh 2s · session ${session}${reset}${esc}[K"
	printf '%s%s' "$out" "${esc}[0J"
}

printf '%s' "${esc}[?25l"
while true
do
	render
	read -rsn1 -t 2 key || key=""
	case "$key" in
		q|Q)
			break
			;;
	esac
done
