#!/usr/bin/env bash
set -euo pipefail

agent="${AGENT_NAME:-agent}"
state="${AGENT_STATE:-}"
sess="${AGENT_SESSION:-}"
win="${AGENT_WINDOW:-}"

# Only notify for the configured states (the daemon filters too; this is a second guard).
ntfy_states="${AGENT_NTFY_STATES:-done}"
case ",$ntfy_states," in
	*",$state,"*)
		;;
	*)
		exit 0
		;;
esac

env_file="${AGENT_NTFY_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/tmux-handlr/ntfy.env}"
[ -r "$env_file" ] || exit 0
set -a; . "$env_file"; set +a

url="${HANDLR_NTFY_URL:-${HERDR_NTFY_EXTERNAL_URL:-}}"
topic="${HANDLR_NTFY_TOPIC:-${HERDR_NTFY_TOPIC:-}}"
token="${HANDLR_NTFY_TOKEN:-${HERDR_NTFY_BEARER_TOKEN:-}}"
if [ -z "$url" ] || [ -z "$topic" ]
then
	exit 0
fi

auth=()
case "$token" in
	"")
		;;
	*:*)
		auth=(-u "$token")   # user:pass
		;;
	*)
		auth=(-H "Authorization: Bearer $token")   # bearer token
		;;
esac

curl -fsS -m 10 "${auth[@]}" \
	-H "Title: ${agent} ${state}" \
	-H "Tags: white_check_mark" \
	--data "${sess}:${win}: ${agent} is ${state}" \
	"${url%/}/${topic}" >/dev/null 2>&1 || true
