# shellcheck shell=bash

emoji_for() {
	local t="$1"
	local glyphs
	local pair
	local k
	local -a _p
	local -A MAP=()
	# Optional per-type override: @handlr-agent-glyphs 'claude=🤖,codex=🧠,default=🤖'
	# (falls back to the old @agent-indicator-icons so migration is drop-in).
	glyphs=$(tmux show-option -gqv @handlr-agent-glyphs 2>/dev/null || :)
	if [ -z "$glyphs" ]
	then
		glyphs=$(tmux show-option -gqv @agent-indicator-icons 2>/dev/null || :)
	fi
	if [ -n "$glyphs" ]
	then
		IFS=',' read -ra _p <<< "$glyphs"
		for pair in "${_p[@]}"
		do
			k="${pair%%=*}"
			k="${k//[[:space:]]/}"
			MAP[$k]="${pair#*=}"
		done
		if [ -n "${MAP[$t]:-}" ]
		then
			printf '%s' "${MAP[$t]}"; return
		elif [[ "$t" == dsh-* ]] && [ -n "${MAP[dsh]:-}" ]
		then
			printf '%s' "${MAP[dsh]}"; return
		elif [ -n "${MAP[default]:-}" ]
		then
			printf '%s' "${MAP[default]}"; return
		fi
	fi
	case "$t" in
		claude)    printf '' ;;   # nf-cod-claude (Nerd Font)
		codex)     printf '' ;;   # nf-cod-openai (Nerd Font)
		copilot)   printf '' ;;   # nf-cod-copilot (Nerd Font)
		opencode)  printf '🄲' ;;   # squared C
		dsh|dsh-*) printf '🐳' ;;   # whale (deepseek + interface variants)
		gemini)    printf '♊' ;;   # Gemini zodiac
		qwen)      printf 'Ⓠ' ;;   # circled Q
		grok)      printf '𝕏' ;;   # double-struck X (xAI)
		cursor)    printf '▮' ;;   # block cursor
		cline)     printf '❯' ;;   # prompt chevron
		kiro)      printf 'Ⓚ' ;;   # circled K (try nf fa-ghost U+EEFE for the ghost mascot)
		devin)     printf 'Ⓓ' ;;   # circled D
		maki)      printf '◎' ;;   # bullseye
		kimi)      printf '☽' ;;   # first-quarter moon (Moonshot)
		qodercli)  printf '🅀' ;;   # squared Q
		agy)       printf '⇧' ;;   # up arrow (Antigravity)
		aider)     printf 'æ' ;;   # ae ligature
		*)         printf '🤖' ;;   # robot (default)
	esac
}

# state to its indicator color, from the @handlr-color-<state> options with portable
# named-color defaults: named colors resolve against the terminal palette, so
# nothing here is tied to one theme. Used by the dots segment and the prefix+a menu.
_handlr_color() {
	local opt
	local def
	local v
	case "$1" in
		running)
			opt='@handlr-color-running'
			def='yellow'
			;;
		needs-input)
			opt='@handlr-color-needs-input'
			def='red'
			;;
		done)
			opt='@handlr-color-done'
			def='green'
			;;
		*)
			opt='@handlr-color-idle'
			def='cyan'
			;;
	esac
	v=$(tmux show-option -gqv "$opt" 2>/dev/null || :)
	printf '%s' "${v:-$def}"
}

# cwd to claude's project-dir name. Claude (a JS app) encodes it with
# cwd.replace(/[^a-zA-Z0-9]/g,'-'), one dash per character. GNU sed only
# reproduces that under a UTF-8 *C* locale; the login locale (en_US.UTF-8)
# leaves non-ascii chars untouched, so e.g. `eä.net` mis-encoded to `eä-net`
# instead of claude's `e--net` and the transcript was never found (so it reads idle, no cost).
_claude_proj_enc() { printf '%s' "$1" | LC_ALL=C.UTF-8 sed 's/[^a-zA-Z0-9]/-/g'; }

# Resolve an agent's model, most accurate first:
#   1. LIVE session model: the model of the most recent turn. For claude that's
#      the last "model" recorded in the session transcript (cwd, then project dir, then
#      newest *.jsonl), so it tracks a mid-session /model switch. (opencode/dsh
#      have no cheap live source yet: opencode's sits in per-message JSON, dsh's
#      in a zstd-compressed session jsonl; they fall through to 2/3.)
#   2. an explicit --model/-m in the pane's argv (launch-time);
#   3. the agent type's configured default.
# Provider prefix ("localai/…") is stripped. Caveat: claude's live lookup reads
# the NEWEST transcript for the cwd, so several claude sessions in one directory
# can alias; and the last "model" may belong to a subagent turn.
agent_model() {
	local tty="$1"
	local type="$2"
	local cwd="$3"
	local m=""

	# 1. live session model (claude transcript).
	if [ "$type" = claude ]
	then
		local enc
		local dir
		local newest
		enc=$(_claude_proj_enc "$cwd")
		dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc"
		newest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
		if [ -n "$newest" ]
		then
			m=$(tail -n 400 "$newest" 2>/dev/null \
				| grep -oE '"model":"[^"]*"' | tail -1 | sed -E 's/.*:"([^"]*)".*/\1/')
		fi
	fi

	# 2. explicit --model / -m in the pane's process argv.
	if [ -z "$m" ]
	then
		m=$(ps -t "${tty#/dev/}" -o args= 2>/dev/null \
			| grep -oE -- '(--model|-m)[ =]+[^ ]+' | head -1 | sed -E 's/^(--model|-m)[ =]+//')
	fi

	# 3. per-agent configured default.
	if [ -z "$m" ]
	then
		# The top-level "model": "…" is a plain string near the top of each config,
		# so grep it (opencode's config is JSONC; trailing commas break json.load).
		local cfg=""
		case "$type" in
			claude)
				cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
				;;
			opencode)
				cfg="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
				;;
		esac
		case "$type" in
			claude|opencode)
				m=$(grep -m1 -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null \
					| sed -E 's/.*"([^"]*)"$/\1/')
				;;
			dsh|dsh-*)
				m=$(awk '/^agent-default-model:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/^[[:space:]]+model:/{sub(/^[[:space:]]*model:[[:space:]]*/,"");print;exit}' "$HOME/.dsh/settings.yaml" 2>/dev/null)
				;;
		esac
	fi

	printf '%s' "${m##*/}"   # strip provider prefix (localai/…, anthropic/…)
}

# session_id TYPE CWD: the id ccusage keys a session by (its "period"), or "".
#   claude   : newest transcript uuid for the cwd (basename of *.jsonl);
#   opencode : the newest opencode session id whose .directory == cwd.
# dsh isn't tracked by ccusage, so it returns "".
session_id() {
	local type="$1"
	local cwd="$2"
	case "$type" in
		claude)
			local enc
			local f
			enc=$(_claude_proj_enc "$cwd")
			f=$(ls -t "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc"/*.jsonl 2>/dev/null | head -1)
			if [ -n "$f" ]
			then
				f="${f##*/}"
				printf '%s' "${f%.jsonl}"
			fi
			;;
		opencode)
			python3 -c '
import json,glob,os,sys
cwd=sys.argv[1]
base=os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),"opencode","storage","session")
best,bt=None,-1
for f in glob.glob(base+"/*/ses_*.json")+glob.glob(base+"/ses_*.json"):
    try: d=json.load(open(f))
    except Exception: continue
    if d.get("directory")==cwd:
        t=d.get("time",{}).get("updated",0)
        if t>bt: bt,best=t,d.get("id")
print(best or "")' "$cwd" 2>/dev/null
			;;
	esac
}

# _agent_activity_mtime TYPE CWD: epoch mtime of the harness's newest session
# file for CWD (how we tell "actively running" from "finished"), or "". It only
# stats files; never decompresses (dsh sessions are zstd). Per-harness paths:
#   claude   : newest ~/.claude/projects/<enc>/*.jsonl        (enc: non-alnum to -)
#   dsh      : newest file under ~/.dsh/sessions/<--path-->/   (enc: / to -, wrapped)
#   opencode : newest storage/message|part/<ses>/*.json        (ses via session_id)
_agent_activity_mtime() {
	local type="$1"
	local cwd="$2"
	local enc
	local dir
	local f
	local base
	local ses
	case "$type" in
		claude)
			enc=$(_claude_proj_enc "$cwd")
			dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc"
			f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1 || :)   # || : : a no-match isn't an error
			if [ -n "$f" ]
			then
				stat -c %Y "$f" 2>/dev/null || :
			fi
			;;
		dsh|dsh-*)
			# dsh encodes cwd as --<path, / becomes ->>-- and keeps dots (ascii cwds only).
			dir="$HOME/.dsh/sessions/--$(printf '%s' "$cwd" | sed 's#^/##; s#/#-#g')--"
			[ -d "$dir" ] || return 0
			find "$dir" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1
			;;
		opencode)
			ses=$(session_id opencode "$cwd" || :); [ -n "$ses" ] || return 0
			base="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/storage"
			f=$(ls -t "$base/message/$ses"/*.json "$base/part/$ses"/*.json 2>/dev/null | head -1 || :)
			if [ -n "$f" ]
			then
				stat -c %Y "$f" 2>/dev/null || :
			fi
			;;
	esac
}

# agent_state TYPE CWD PANE NOW RUN_WIN DONE_WIN: running|needs-input|done|idle.
# A pure function of observable session state (no event latches), so it can't
# go stale the way the old hook-set env var did:
#   * running   : session file written within RUN_WIN seconds (agent is working);
#   * needs-input: a permission marker (claude PermissionRequest hook touches
#                   ~/.cache/agent-state/needs-input/<pane>) that the session has
#                   NOT written past (agent blocked). Self-clears when the agent
#                   next writes (mt jumps past the marker); grace absorbs the
#                   hook-vs-transcript write ordering; expires after DONE_WIN so a
#                   reused pane's leftover marker can't false-fire;
#   * done      : finished within DONE_WIN (transient green);
#   * idle      : otherwise (or no session file / unknown harness).
agent_state() {
	local type="$1"
	local cwd="$2"
	local pane="$3"
	local now="$4"
	local run_win="$5"
	local done_win="$6"
	local mt
	local nimt=""
	local grace=5
	mt=$(_agent_activity_mtime "$type" "$cwd" || :)
	local ni="${XDG_CACHE_HOME:-$HOME/.cache}/agent-state/needs-input/$pane"
	if [ -f "$ni" ]
	then
		nimt=$(stat -c %Y "$ni" 2>/dev/null || :)
	fi

	if [ -n "$nimt" ] && [ "$(( now - nimt ))" -lt "$done_win" ]
	then
		if [ -z "$mt" ] || [ "$mt" -le "$(( nimt + grace ))" ]
		then
			printf 'needs-input'
			return
		fi
	fi
	if [ -z "$mt" ]
	then
		printf 'idle'
		return
	fi
	local age=$(( now - mt ))
	if [ "$age" -lt "$run_win" ]
	then
		printf 'running'
	elif [ "$age" -lt "$done_win" ]
	then
		printf 'done'
	else printf 'idle'; fi
}

# enum_agent_panes [session]: TSV rows, one per agent pane, WITHOUT state:
#   pane  type  tty  win_index  win_name  pid  cwd  title
# This is the enumeration half, i.e. "which panes are agents, and of what type",
# and the single source of truth behind both enum_agents (below) and the
# detect.py daemon (which resolves state by screen-scraping). Model is NOT
# included: it's the expensive field, and consumers resolve it lazily via
# agent_model. No session arg means every pane on the server.
enum_agent_panes() {
	local session="${1:-}"
	local -a scope
	if [ -n "$session" ]
	then
		scope=(-s -t "$session")
	else
		scope=(-a)
	fi

	local processes
	processes=$(tmux show-option -gqv @handlr-processes 2>/dev/null)
	if [ -z "$processes" ]
	then
		processes=$(tmux show-option -gqv @agent-indicator-processes 2>/dev/null)
	fi
	# Default set: agents whose CLI self-names with a distinctive whole-word token
	# (so process-matching is safe). opencode2 = opencode's v2-beta binary
	# (normalized to opencode below); agy = Google Antigravity's binary. Kept
	# OUT on purpose: pi/amp/hermes (too-short or colliding tokens cause false
	# positives). To turn one on, append it via @handlr-extra-processes (below)
	# instead of restating the whole list.
	if [ -z "$processes" ]
	then
		processes="claude,codex,aider,cursor,opencode,opencode2,dsh,gemini,qwen,copilot,grok,cline,kiro,devin,maki,kimi,qoder,qodercli,agy"
	fi
	# @handlr-extra-processes APPENDS to the resolved list (add agents without
	# rewriting the default); e.g. the excluded pi/amp/hermes, at your own risk.
	local extra; extra=$(tmux show-option -gqv @handlr-extra-processes 2>/dev/null || :)
	if [ -n "$extra" ]
	then
		processes="$processes,$extra"
	fi
	local -a procs
	IFS=',' read -ra procs <<< "$processes"

	# Batch the two dominant per-pane costs into single calls. Running a ps and a
	# show-environment PER PANE cost ~100 forks/render on a 14-pane session (0.6s),
	# which at status-interval 1 churned the status line and made clicks land on a
	# moving target. Now it's one ps, one show-environment, and a fork-free word match.
	#
	# Per process we weigh only the PROGRAM being run, never its data arguments: the
	# executable name (comm), plus the script path (argv1) for interpreter processes,
	# since agents shipped as `node .../cli.js` self-name in that path. A file
	# argument like `nvim .dsh/notes.md` can no longer be mistaken for the dsh agent.
	local -A TTY_CMD
	local -A PANE_AGENT
	local _tty
	local _comm
	local _rest
	local _argv1
	local _line
	local _k
	while read -r _tty _comm _rest
	do
		if [ -z "$_tty" ] || [ "$_tty" = "?" ]
		then
			continue
		fi
		case "$_comm" in
			node|nodejs|deno|bun|python|python[23]|python[23].*|ruby|perl|bash|sh|dash|zsh|fish)
				_rest="${_rest#* }"          # drop argv0
				_argv1="${_rest%% *}"        # keep argv1 (the script); ignore data args
				TTY_CMD[$_tty]+=" $_comm $_argv1"
				;;
			*)
				TTY_CMD[$_tty]+=" $_comm"    # native binary: it self-names via comm
				;;
		esac
	done < <(ps -e -o tty= -o comm= -o args= 2>/dev/null)
	while IFS= read -r _line
	do
		_line="${_line#TMUX_AGENT_PANE_}"; _k="${_line%%_AGENT=*}"
		if [ -n "$_k" ]
		then
			PANE_AGENT[$_k]="${_line#*=}"
		fi
	done < <(tmux show-environment -g 2>/dev/null | grep -E '^TMUX_AGENT_PANE_.*_AGENT=' || :)

	local T=$'\t'
	local pane
	local tty
	local pid
	local widx
	local wname
	local cwd
	local title
	local cmds
	local type
	local tag
	local p
	while IFS=$'\t' read -r pane tty pid widx wname cwd title
	do
		[ -n "$tty" ] || continue
		cmds="${TTY_CMD[${tty#/dev/}]:-}"
		[ -n "$cmds" ] || continue
		type=""
		for p in "${procs[@]}"
		do
			p="${p//[[:space:]]/}"
			[ -z "$p" ] && continue
			# A whole-word match (like grep -w) without a fork.
			if [[ " $cmds " =~ (^|[^[:alnum:]_])"$p"([^[:alnum:]_]|$) ]]
			then
				type="$p"
				break
			fi
		done
		[ -n "$type" ] || continue
		# The _AGENT tag (set by dsh's plugin or our agent-state.sh) refines the type
		# for an agent whose process is generic (e.g. dsh -> dsh-tui). Honor it only
		# when it agrees with or refines the process match; a tag that contradicts a
		# confident match is stale (a reused pane id from an exited agent) and must
		# not relabel the live pane.
		tag="${PANE_AGENT[$pane]:-}"
		if [ -n "$tag" ] \
			&& { [ "$tag" = "$type" ] || [ "${tag%%-*}" = "$type" ] || [ "${type%%-*}" = "$tag" ]; }
		then
			type="$tag"
		fi
		# Normalize interface/beta binary tokens to their canonical agent id (the
		# herdr manifest id) so the manifest/glyph lookups resolve.
		case "$type" in
			opencode2)
				type=opencode
				;;
			qoder)
				type=qodercli
				;;
		esac
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$pane" "$type" "$tty" "$widx" "$wname" "$pid" "$cwd" "$title"
	done < <(tmux list-panes "${scope[@]}" \
		-F "#{pane_id}${T}#{pane_tty}${T}#{pane_pid}${T}#{window_index}${T}#{window_name}${T}#{pane_current_path}${T}#{pane_title}" 2>/dev/null)
}

# enum_agents [session]: TSV rows, one per agent pane, WITH state:
#   pane  type  state  tty  win_index  win_name  pid  cwd  title
# State comes from the detect.py daemon's screen-scrape cache
# (${XDG_RUNTIME_DIR:-/tmp}/tmux-handlr/state.tsv). When that cache is missing
# or stale (daemon down for > 10s), each pane falls back to the mtime heuristic
# (agent_state), so the UI degrades gracefully and never goes blank. This is the
# ONLY function the dots segment / prefix+a menu / prefix+A dashboard call, so
# all three always agree.
enum_agents() {
	local session="${1:-}"

	# mtime-fallback windows (used only when the cache lacks a pane).
	local now
	local rw
	local dw
	printf -v now '%(%s)T' -1
	rw=$(tmux show-option -gqv @handlr-running-window 2>/dev/null)
	if ! [[ "$rw" =~ ^[0-9]+$ ]]
	then
		rw=$(tmux show-option -gqv @agent-status-running-window 2>/dev/null)
	fi
	if ! [[ "$rw" =~ ^[0-9]+$ ]]
	then
		rw=20
	fi
	dw=$(tmux show-option -gqv @handlr-done-window 2>/dev/null)
	if ! [[ "$dw" =~ ^[0-9]+$ ]]
	then
		dw=$(tmux show-option -gqv @agent-status-done-window 2>/dev/null)
	fi
	if ! [[ "$dw" =~ ^[0-9]+$ ]]
	then
		dw=120
	fi

	# Load the daemon state cache, but only when fresh. A dead daemon's cache
	# goes stale in ~10s; at that point we ignore it and the mtime fallback resumes.
	local -A CACHE
	local cachefile="${XDG_RUNTIME_DIR:-/tmp}/tmux-handlr/state.tsv"
	local cmt
	local cp
	local cs
	if [ -r "$cachefile" ]
	then
		cmt=$(stat -c %Y "$cachefile" 2>/dev/null || echo 0)
		if [ "$(( now - cmt ))" -lt 10 ]
		then
			while IFS=$'\t' read -r cp cs
			do
				if [ -n "$cp" ]
				then
					CACHE[$cp]="$cs"
				fi
			done < "$cachefile"
		fi
	fi

	local pane
	local type
	local tty
	local widx
	local wname
	local pid
	local cwd
	local title
	local state
	while IFS=$'\t' read -r pane type tty widx wname pid cwd title
	do
		[ -n "$pane" ] || continue
		if [ -n "${CACHE[$pane]:-}" ]
		then
			state="${CACHE[$pane]}"
		else
			state=$(agent_state "$type" "$cwd" "$pane" "$now" "$rw" "$dw")
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$pane" "$type" "$state" "$tty" "$widx" "$wname" "$pid" "$cwd" "$title"
	done < <(enum_agent_panes "$session")
}

# render_pane_indicators [session]: the status-line string; agents grouped by
# type (each type's configurable glyph label), then a clickable per-pane state
# indicator wrapped in #[range=user|<pane>] so a MouseDown1Status binding can jump.
# The single renderer for the dots segment: both the plugin's copy and a user's
# powerline user-segment call this, so there's one place to change.
#
# Style via @handlr-indicator:
#   dots      (default): one ● per pane, colored by state; the RUNNING dot cycles
#               the running-animation frames (@handlr-dots-animate, on by default).
#   symbolic  : a glyph per state: running = animated frames, needs-input = ?,
#               done = ✓, idle = ○.
# Overridable: @handlr-glyph-running (space-separated running-animation frames,
#   used by both modes), -done, -needs-input, -idle; @handlr-dots-animate (on|off).
# Colors stay constant per state in both modes (red/yellow/green/cyan).
render_pane_indicators() {
	local current="${1:-}"
	if [ -z "$current" ]
	then
		current=$(tmux display-message -p '#{session_name}' 2>/dev/null) || return 0
	fi
	[ -n "$current" ] || return 0

	local style; style=$(tmux show-option -gqv @handlr-indicator 2>/dev/null || :)
	if [ -z "$style" ]
	then
		style=dots
	fi
	local dots_anim; dots_anim=$(tmux show-option -gqv @handlr-dots-animate 2>/dev/null || :)
	if [ -z "$dots_anim" ]
	then
		dots_anim=on
	fi

	# Animate the running indicator in symbolic mode; in dots mode, unless
	# @handlr-dots-animate is off.
	local -a run_frames
	local g_done
	local g_needs
	local g_idle
	local now
	local animate_running=0
	if [ "$style" = symbolic ] || { [ "$style" = dots ] && [ "$dots_anim" != off ]; }
	then
		local g_run; g_run=$(tmux show-option -gqv @handlr-glyph-running 2>/dev/null || :)
		# Mode-dependent default: a single @handlr-glyph-running override applies
		# to whichever mode is active. dots = pie-fill; symbolic = quadrant-block orbit.
		if [ -z "$g_run" ]
		then
			if [ "$style" = symbolic ]
			then
				g_run='▘ ▝ ▗ ▖'
			else
				g_run='◔ ◑ ◕ ●'
			fi
		fi
		IFS=' ' read -ra run_frames <<< "$g_run"
		# One frame per status redraw. tmux caches #() segment output and only
		# re-runs it every `status-interval` (integer seconds), ~1 frame/sec. A
		# finer counter would alias to the same frame each redraw (looks frozen).
		# Short, high-contrast sets (pie-fill, block-orbit) read as motion at 1/sec;
		# long braille sets don't.
		printf -v now '%(%s)T' -1
		if [ ${#run_frames[@]} -gt 0 ]
		then
			animate_running=1
		fi
	fi
	if [ "$style" = symbolic ]
	then
		g_done=$(tmux show-option -gqv @handlr-glyph-done 2>/dev/null || :)
		if [ -z "$g_done" ]
		then
			g_done=''
		fi
		g_needs=$(tmux show-option -gqv @handlr-glyph-needs-input 2>/dev/null || :)
		if [ -z "$g_needs" ]
		then
			g_needs=''
		fi
		g_idle=$(tmux show-option -gqv @handlr-glyph-idle 2>/dev/null || :)
		if [ -z "$g_idle" ]
		then
			g_idle='○'
		fi
	fi

	local -a rows=()
	local pane
	local type
	local state
	local tty
	local widx
	local wname
	local pid
	local cwd
	local title
	while IFS=$'\t' read -r pane type state tty widx wname pid cwd title
	do
		[ -n "$pane" ] || continue
		rows+=("$type|$pane|$state")
	done < <(enum_agents "$current")
	[ ${#rows[@]} -gt 0 ] || return 0

	# Ordered unique types: preferred order first, then whatever's left.
	local -a types=()
	local t
	local r
	for t in claude opencode codex dsh dsh-tui $(printf '%s\n' "${rows[@]}" | cut -d'|' -f1 | sort -u)
	do
		printf '%s\n' "${rows[@]}" | grep -q "^${t}|" || continue
		case " ${types[*]} " in
			*" $t "*)
				;;
			*)
				types+=("$t")
				;;
		esac
	done

	local out=""
	local color
	local glyph
	local first=1
	local label_color
	local idx
	for t in "${types[@]}"
	do
		if [ $first -ne 1 ]
		then
			out+="  "
		fi
		first=0
		# nf-cod-claude honors fg (emoji doesn't): a warm accent for claude, grey
		# otherwise. Override the claude accent via @handlr-label-color-claude.
		case "$t" in
			claude)
				label_color=$(tmux show-option -gqv @handlr-label-color-claude 2>/dev/null || :)
				if [ -z "$label_color" ]
				then
					label_color=colour173
				fi
				;;
			*)
				label_color=colour252
				;;
		esac
		out+="#[fg=${label_color}]$(emoji_for "$t")"
		for r in "${rows[@]}"
		do
			[ "${r%%|*}" = "$t" ] || continue
			pane="${r#*|}"; pane="${pane%%|*}"; state="${r##*|}"
			color=$(_handlr_color "$state")   # @handlr-color-<state>, with named defaults
			if [ "$style" = symbolic ]
			then
				case "$state" in
					running)
						glyph="${run_frames[$(( now % ${#run_frames[@]} ))]}"
						;;
					needs-input)
						glyph="$g_needs"
						;;
					done)
						glyph="$g_done"
						;;
					*)
						glyph="$g_idle"
						;;
				esac
			elif [ "$state" = running ] && [ "$animate_running" = 1 ]
			then
				glyph="${run_frames[$(( now % ${#run_frames[@]} ))]}"   # the animated running dot
			else
				glyph='●'
			fi
			out+="#[range=user|${pane}]#[fg=${color}] ${glyph} #[norange]"
		done
	done

	if [ -n "$out" ]
	then
		printf '%s#[default]' "$out"
	fi
	return 0
}
