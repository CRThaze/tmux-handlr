# tmux-handlr: coding-agent status for tmux

A **tmux plugin** that shows the live state of every coding agent you have running
(Claude Code, Codex, OpenCode, Gemini CLI, Copilot, Cursor, and more) as status-line dots,
a switcher menu, a dashboard, and a sidebar, with push notifications when an agent
finishes or is waiting on you.

![tmux session with the handlr sidebar listing nine agent panes by state, the prefix+a agent switcher menu open, and colored per-agent status dots in the powerline status bar](doc/img/overview.png)

> Herdr is a great agent tracker, it's just missing a good multiplexer.

tmux users can now get [Herdr](https://github.com/herdrdev/herdr)-style harness status
information without having to switch away from their favorite multiplexer.

*(Note: Herdr is actually a pretty performant multiplexer and no slander against
Herdr, its users, its developers, or their coding agents is intended.)*

## What This Does

Live status for coding-agent panes in tmux. `handlr` reports, per pane, whether the agent
is **working**, **needs input**, **done**, or **idle**; you see it as clickable status-line
dots, a `prefix + a` switcher menu, and a `prefix + A` detail dashboard (also available as a
toggle-able **sidebar** pane), plus an optional [ntfy](https://ntfy.sh) push when an agent
finishes or stalls on a prompt.

![The prefix+A dashboard popup: a table of agent panes with state, window, uptime, model, cost, tokens, working directory, and pane title](doc/img/dashboard.png)

Out of the box it detects **claude, codex, opencode, dsh (deepseek)**, plus every agent
[herdr](https://github.com/herdrdev/herdr) ships rules for (cursor, gemini, amp, cline, …).

## Why the state is right

Most tmux agent-status tools watch a session file's modification time and guess, so a long
tool call reads as "done" the moment the transcript pauses and an idle prompt reads as
"working" for minutes. `handlr` reads each pane's title and rendered screen against herdr's
per-agent rules instead, and the dots, menu, and dashboard all read one shared state cache,
so they never disagree. Full mechanics are in [How detection works](#how-detection-works).

## Quick start

New to customizing tmux? These four steps go from nothing to a working setup; only the
first is required.

**1. Install the plugin.** With [TPM](https://github.com/tmux-plugins/tpm), add this line to
`~/.tmux.conf`:

```tmux
set -g @plugin 'CRThaze/tmux-handlr'
```

Then press `prefix + I` to fetch and load it. `handlr.tmux` starts the detection daemon and
binds the menu and dashboard keys.

**2. Use the menu, dashboard, and sidebar, no extra setup.** Press `prefix + a` for the
switcher menu (pick an agent to jump to it) and `prefix + A` for the detail dashboard. Both
work immediately. Prefer your own keybindings? See [`@handlr-setup-binds`](#options).

**3. (Optional) Add the always-visible status-line dots.** The colored dots live in your
status line, so they need one wiring step:
- **Using [tmux-powerline](https://github.com/erikw/tmux-powerline)?** Run
  `scripts/install-segment.sh` (or set `@handlr-install-segment 'on'`), then add
  `agent_pane_dots` to your theme's segment list.
- **Not using powerline?** Set `@handlr-status-right 'on'` and handlr appends the dots to
  `status-right` for you.

Either route, the dots become click-to-jump once you add a short mouse binding. Full
instructions are in [Status-line dots](#status-line-dots).

**4. (Optional) Get notified when an agent finishes or needs you.** Point
`@handlr-notify-command` at a script; a ready-made [ntfy](https://ntfy.sh) pusher ships in
`scripts/agent-ntfy-notify.sh`. See [Notifications](#notifications).

The glyphs look best with a [Nerd Font](https://www.nerdfonts.com/); if you don't have one,
the dots still work and you can swap the label glyphs (see the Nerd Font note under
[Options](#options)).

## Requirements

- tmux 3.x, bash, `ps`
- `python3` **3.6+** for the detection engine, **standard library only, no pip installs**
- A **Nerd Font** (recommended): the default `claude`/`codex`/`copilot` labels and the
  `symbolic`-mode badges are Nerd Font glyphs. Without one, override them with plain-Unicode
  glyphs via `@handlr-agent-glyphs` and `@handlr-glyph-*` (see [Options](#options)); the `dots`
  indicator and its pie-fill animation are plain Unicode and need no special font.
- [tmux-powerline](https://github.com/erikw/tmux-powerline): needed for the status-line
  indicator as a powerline **segment**. Skipping powerline? Use the plain `status-right`
  fallback (see [Status-line dots](#status-line-dots)); the menu, dashboard, and
  notifications work either way.
- `curl`: optional, only for `detection-sync.sh` and ntfy notifications

## Supported agents

Detected out of the box (in the default `@handlr-processes`), with their default label glyph.
State comes from herdr's screen-detection rules (`herdr ✓`) except where noted; every glyph is
overridable with [`@handlr-agent-glyphs`](#options).

| Agent                   | Glyph | Matched process name(s) | State detection |
|-------------------------|-------|-------------------------|-----------------|
| Claude Code             | (nf)  | `claude`                | herdr pattern ✓ |
| Codex                   | (nf)  | `codex`                 | herdr pattern ✓ |
| GitHub Copilot          | (nf)  | `copilot`               | herdr pattern ✓ |
| opencode                | 🄲     | `opencode`, `opencode2` | herdr pattern ✓ |
| Gemini CLI              | ♊    | `gemini`                | herdr pattern ✓ |
| Qwen Code               | Ⓠ     | `qwen`                  | herdr pattern ✓ |
| Grok CLI                | 𝕏     | `grok`                  | herdr pattern ✓ |
| Cursor (`cursor-agent`) | ▮     | `cursor`                | herdr pattern ✓ |
| Cline                   | ❯     | `cline`                 | herdr pattern ✓ |
| Kiro                    | Ⓚ     | `kiro`                  | herdr pattern ✓ |
| Devin (terminal)        | Ⓓ     | `devin`                 | herdr pattern ✓ |
| Maki                    | ◎     | `maki`                  | herdr pattern ✓ |
| Kimi                    | ☽     | `kimi`                  | herdr pattern ✓ |
| Qoder                   | 🅀     | `qoder`/`qodercli`      | herdr pattern ✓ |
| Antigravity             | ⇧     | `agy`                   | herdr pattern ✓ |
| dsh (deepseek TUI)      | 🐳    | `dsh` + self-report     | ours (`dsh-tui`) |
| aider                   | æ     | `aider`                 | **mtime only**: herdr ships no aider rules |

Notes:
- **Fonts:** `claude`, `codex`, `copilot` are Nerd Font glyphs; the rest are plain Unicode and
  render anywhere (see the Nerd Font note under [Options](#options)).
- **Future brand glyphs:** `gemini`, `grok`, `kimi` have real brand codicons upstream
  (U+ECD1 / U+ECEC / U+ECD2) that aren't in the current Nerd Fonts release yet; they use Unicode
  now and can be swapped when the font updates. `kiro`'s mascot is a ghost: try nf `fa-ghost`
  (U+EEFE) via `@handlr-agent-glyphs` if your font has it.
- **Excluded by default (false-positive-prone tokens):** `pi` (2 chars), `amp` (3 chars, matches
  paths/sockets), `hermes` (collides with React Native's `hermes` engine). herdr *does* have rules
  for them; enable the one(s) you run with `set -g @handlr-extra-processes 'pi,amp,hermes'`
  (appends to the default; at your own risk), or, if the harness can call it, self-report via
  `scripts/agent-state.sh --agent <name> --state …` (no false-positive risk).
- Any agent not listed falls back to 🤖 and the mtime heuristic.

## How detection works

```
handlr.tmux ──starts──▶ detect.py --daemon ──loops every ~1.5s──▶ state cache (TSV)
                              │                                         │
             reads OSC title + capture-pane, matches                  read by
             detection/*.json rules (herdr-derived)                   ▼
                                              agent_pane_dots segment · prefix+a menu · prefix+A dashboard
```

The daemon polls every agent pane about every 1.5s and decides each pane's state with a
**fallback ladder**: it takes the first rung that gives a confident answer and skips the
rest. Higher rungs are both cheaper to check and more trustworthy, so the ladder is ordered
strongest first:

1. **Self-reported state, authoritative.** If the harness told handlr its own state through
   `scripts/agent-state.sh` (dsh does this via `dsh-herdr-agent-state`), handlr trusts it over
   everything below: the agent said so, there is nothing to guess. See
   [Self-reporting agents](#self-reporting-agents-dsh-etc).
2. **OSC title.** The pane's terminal title (`#{pane_title}`) is free to read and already
   carries working/idle for most claude and codex sessions, so handlr checks it before paying
   for a screen capture.
3. **Screen scrape.** `tmux capture-pane` renders the pane and handlr matches it against a
   prioritized per-agent ruleset (permission prompts, spinners, the empty prompt box, …). This
   rung is what makes "needs input" work for every agent, not just one. The rules are herdr's,
   bundled under Apache-2.0 and kept current by a scheduled sync (see
   [Detection rules & updates](#detection-rules--updates)).
4. **Timestamp fallback.** Only when no rule matches the pane, or the daemon isn't running at
   all, handlr falls back to the session-file mtime heuristic. It is the least precise rung, so
   it sits last, but it keeps the UI on a best-effort guess instead of going blank.

The green **done** flash sits outside the ladder: the daemon synthesizes it when a pane
crosses from working or needs-input to idle, holds it for `@handlr-done-window`, then lets it
settle to idle. To avoid a premature flash while an agent is still printing its after-action
report or pausing between steps, idle must persist for `@handlr-done-delay` seconds before done
fires; a return to working inside that window cancels it. Dismiss a flash early by binding
`@handlr-dismiss-key`, or run `scripts/agent-dismiss.sh [%pane]` / `--all`.

Because the dots, the `prefix + a` menu, and the `prefix + A` dashboard all read the single
state cache the daemon writes, they can never show different states for the same pane.

## Options

| Option | Default | Meaning |
|---|---|---|
| `@handlr-setup-binds` | `on` | Bind the menu/dashboard keys. Set `off` to keep your own binds. |
| `@handlr-menu-key` | `a` | `prefix +` this opens the agent switcher menu; opened from inside an agent pane, that agent's row starts selected. |
| `@handlr-dashboard-key` | `A` | `prefix +` this opens the detail dashboard. |
| `@handlr-popup-style` | `bg=default,fg=default` | Dashboard popup `-s` style. |
| `@handlr-popup-border-style` | `fg=default,bg=default` | Dashboard popup `-S` border style. |
| `@handlr-sidebar-key` | *(unset)* | `prefix +` this **toggles** a sidebar pane running the dashboard's compact layout. Opt-in: unset binds nothing, so pick a free key (e.g. `s`). |
| `@handlr-sidebar-width` | `24` | Sidebar pane width, in columns. |
| `@handlr-sidebar-position` | `left` | Which side the sidebar opens on: `left` or `right`. |
| `@handlr-dashboard-icons` | `on` | Show each agent's type glyph (as in the `prefix+a` menu) in the `prefix+A` dashboard and the sidebar. `off` = text only. |
| `@handlr-dismiss-key` | *(unset)* | `prefix +` this dismisses the **current pane's** done flash back to idle now. Opt-in: unset binds nothing. (`scripts/agent-dismiss.sh --all` clears every done pane at once.) |
| `@handlr-all-sessions` | `on` | List agents from **every** tmux session in the dots, menu, dashboard, and sidebar (menu/dashboard rows get a `session:` prefix, and picking one switches the client there). `off` scopes them to the client's current session. |
| `@handlr-daemon` | `on` | Run the detection daemon. `off` means timestamp-fallback only. |
| `@handlr-processes` | *(the supported-agents set)* | Process names treated as agents (replaces the default list; see [Supported agents](#supported-agents)). |
| `@handlr-extra-processes` | *(unset)* | **Appends** to the default list: add agents without restating it (e.g. the excluded `pi,amp,hermes`, at your own risk). |
| `@handlr-running-window` | `20` | Fallback: seconds of write-activity that counts as running. |
| `@handlr-done-window` | `120` | Seconds the green "done" state persists before idle. |
| `@handlr-done-delay` | `3` | Seconds a pane must stay idle before "done" fires (debounces the flash while a report is still printing or between steps). `0` disables. |
| `@handlr-notify-command` | *(unset)* | Command run on notify-state edges (env: `AGENT_NAME/STATE/SESSION/WINDOW`). |
| `@handlr-notify-states` | `done,needs-input` | Which states fire `@handlr-notify-command`. |
| `@handlr-marker` | `on` | Honor the claude permission-marker accelerator (see [Hooks](#optional-claude-hooks)). |
| `@handlr-indicator` | `dots` | Indicator style: `dots` (● colored by state; the running dot animates) or `symbolic` (a distinct glyph per state). |
| `@handlr-dots-animate` | `on` | In `dots` mode, animate the running dot (cycles `@handlr-glyph-running`); `off` = static ●. |
| `@handlr-agent-glyphs` | *(built-in)* | Per-type label glyphs: `claude=✻,codex=🧠,dsh=🐳,default=🤖`. Overrides the built-ins; also used by the `prefix+a` menu. |
| `@handlr-glyph-running` | *(mode-dependent)* | Running-animation frames (space-separated). Default: `◔ ◑ ◕ ●` (pie-fill) in `dots` mode, `▘ ▝ ▗ ▖` (block orbit) in `symbolic`. An override applies to whichever mode is active. |
| `@handlr-glyph-needs-input` | nf-cod-unverified (U+EB76) | symbolic mode: the "needs input" glyph (shown red; pairs with the done badge). |
| `@handlr-glyph-done` | nf-cod-verified_filled (U+EBE9) | symbolic mode: the "done" glyph (shown green). |
| `@handlr-glyph-idle` | `○` | symbolic mode: the "idle" glyph. |
| `@handlr-color-running` | `yellow` | Color for the running state (any tmux color: name / `colourN` / `#hex`). |
| `@handlr-color-needs-input` | `red` | Color for the needs-input state. |
| `@handlr-color-done` | `green` | Color for the done state. |
| `@handlr-color-idle` | `cyan` | Color for the idle state. |
| `@handlr-label-color-claude` | `colour173` | Accent color for the claude type label. |

State colors default to **named** colors (so they follow your terminal palette) and are set per
state via `@handlr-color-*`; they apply to both modes and to the `prefix+a` menu. (The `prefix+A`
dashboard uses fixed ANSI equivalents.)

The **sidebar** (`@handlr-sidebar-key`) toggles a narrow pane showing the dashboard's compact,
stacked layout. tmux panes belong to a single window, so the sidebar is per-window: it opens
beside the window you trigger it from, and pressing the key again closes it.
`@handlr-agent-glyphs` keys match the agent type exactly, with a `dsh` key also covering `dsh-*`
interface variants and a `default=` catch-all. In `dots` mode the `-done`/`-needs-input`/`-idle`
glyph options are unused (those states are a solid `●`, distinguished by color); the running dot
uses `@handlr-glyph-running` when `@handlr-dots-animate` is on.

**Spin/animation rate:** the running indicator advances one frame per status redraw. tmux caches
the powerline `#()` segment's output and only re-runs it every `status-interval` (integer seconds),
so it's effectively **1 frame/sec**; there is no way to animate a powerline segment faster. Short,
high-contrast sets read as motion at 1/sec; long sets (e.g. a 10-frame braille spinner) look
sluggish. Set `@handlr-dots-animate off` (or a single-frame `@handlr-glyph-running`) for a static ●.

Ready-to-use frame sets (all single-cell and state-colored; `set -g @handlr-glyph-running '…'`):

| Name | Frames | Feel |
|---|---|---|
| pie-fill *(dots default)* | `◔ ◑ ◕ ●` | circle fills, loading |
| block orbit *(symbolic default)* | `▘ ▝ ▗ ▖` | block hops around corners |
| half-circles | `◐ ◓ ◑ ◒` | filled half rotates |
| clock arc | `◴ ◵ ◶ ◷` | quarter-arc sweeps |
| star twinkle | `✶ ✷ ✸ ✹` | pulsing star |
| arrows | `← ↑ → ↓` | rotating pointer |

> **Nerd Font note:** the built-in `claude` and `codex` labels are Nerd Font glyphs
> (nf-cod-claude U+EC82, nf-cod-openai U+EC81). If you don't use a
> [Nerd Font](https://www.nerdfonts.com/), override them with plain-Unicode glyphs
> (e.g. `set -g @handlr-agent-glyphs 'claude=✻,codex=✳,default=🤖'`, any asterisk/emoji works);
> otherwise they show as missing-glyph boxes. Even with a Nerd Font patched in, these glyphs
> tend not to render at font sizes below ~11. (`opencode`'s 🄲 and `dsh`'s 🐳 are plain Unicode
> and render anywhere.)

For back-compatibility, `@agent-indicator-processes`, `@agent-status-running-window`,
`@agent-status-done-window`, and `@agent-indicator-icons` (i.e. `@handlr-agent-glyphs`) are read as
fallbacks if the `@handlr-*` equivalents are unset.

## Status-line dots

**With tmux-powerline.** Powerline doesn't auto-discover segments, so put
`segments/agent_pane_dots.sh` where powerline looks (either your
`TMUX_POWERLINE_DIR_USER_SEGMENTS` dir or powerline's own `segments/`) and add
`agent_pane_dots` to your theme's `TMUX_POWERLINE_{LEFT,RIGHT}_STATUS_SEGMENTS`. The segment
finds the engine via `TMUX_HANDLR_DIR` (exported by `handlr.tmux`), so it works from any location.
To symlink it into place for you, run `scripts/install-segment.sh` (or set
`@handlr-install-segment 'on'` to have `handlr.tmux` do it on load); you still add the segment
name to your theme.

**Without powerline.** Use the plain `status-right` fallback: either add it yourself:

```tmux
set -ga status-right '#($HOME/.tmux/plugins/tmux-handlr/scripts/handlr-status.sh)'
```

or set `@handlr-status-right 'on'` and `handlr.tmux` appends that for you. (Skip this under
powerline: it rewrites `status-right` on every load and would drop it.)

### Mouse Support

Whichever route you used (powerline segment or plain `status-right`), each indicator
carries a `range=user|<pane_id>` marker. To make the dots click-to-jump, add a
`MouseDown1Status` binding that matches the marker and selects that pane:

```tmux
bind -n MouseDown1Status {
	if -F '#{m/r:^%[0-9]+$,#{mouse_status_range}}' {
		run-shell "tmux select-window -t '#{mouse_status_range}'; tmux select-pane -t '#{mouse_status_range}'"
	} {}
}
```

`MouseDown1Status` is one global binding, so if you already dispatch other clickable
status elements (tabs, the session name), fold the `^%[0-9]+$` check into that existing
`if`-chain instead of replacing it.

## Notifications

Set `@handlr-notify-command` to any script; the daemon runs it once per state edge listed in
`@handlr-notify-states`, with `AGENT_NAME`, `AGENT_STATE`, `AGENT_SESSION`, `AGENT_WINDOW` in
the environment. A ready ntfy pusher ships in `scripts/agent-ntfy-notify.sh`; it reads the
server/topic/token from an env file (default
`~/.config/herdr/plugins/config/zom-2018.herdr-ntfy-notify/.env`, overridable with
`AGENT_NTFY_ENV`) so **no secret lives in this repo**.

## Optional: claude hooks

Two optional claude hooks sharpen detection:

- **PermissionRequest** runs `d="${XDG_CACHE_HOME:-$HOME/.cache}/agent-state/needs-input"; [ -n "$TMUX_PANE" ] || exit 0; mkdir -p "$d"; touch "$d/$TMUX_PANE"`
  makes a blocked claude pane show instantly (accelerator; screen-scraping catches it anyway).
- **Stop** runs `[ -n "$TMUX_PANE" ] || exit 0; rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/agent-state/needs-input/$TMUX_PANE"`
  clears that marker.

The `[ -n "$TMUX_PANE" ] || exit 0` guard is required: when claude runs outside tmux (or in a
context that doesn't inherit `$TMUX_PANE`), an unguarded command collapses to the marker
*directory* and `rm`/`touch` errors out in the hook.

## Self-reporting agents (dsh, etc.)

Agents that aren't a recognizable process, or that know their own state, can report it:

```sh
scripts/agent-state.sh --agent dsh-tui --state running   # running | needs-input | done | idle | off
```

Use an interface-specific id (`dsh-tui`, `dsh-web`, …) so distinct interfaces of the same
harness don't collide; ship a matching `detection/<id>.json` (or alias it) for the
screen-scrape fallback.

This tags the pane's agent type and records an authoritative state the daemon honors above
screen-scraping. `off` hands detection back. `$TMUX_PANE` is used if `--pane` is omitted.

## Detection rules & updates

Rules live as JSON under `detection/` (converted from herdr's TOML; `UPSTREAM.json` records
the source commit). At runtime a refreshed copy in
`${XDG_DATA_HOME:-~/.local/share}/tmux-handlr/detection/` wins over the bundle.

- **Manual refresh:** `scripts/detection-sync.sh` (needs python 3.11+ for the TOML read).
- **Automatic:** the `sync-detection` GitHub Action tracks `herdrdev/herdr` weekly, validates
  every change (JSON Schema + regex ReDoS smoke test + engine self-test), and opens a PR for
  review. Validation failures or an upstream `schema_version` bump fail the run and file an
  issue instead; nothing unreviewed is merged.

## Development

```sh
python3 scripts/detect.py --selftest        # engine unit checks (fixtures)
python3 scripts/detect.py --pane %5 --type claude   # resolve one live pane
python3 scripts/sync_detection.py --check-only --out detection   # validate bundled JSON
```

Test locally without publishing: symlink `~/.tmux/plugins/tmux-handlr` to your checkout, then
`prefix + r`.

## FAQ

### How do I get notified when Claude Code (or any agent) finishes in tmux?

Set `@handlr-notify-command` to a script; the daemon runs it on every `done` and
`needs-input` edge. `scripts/agent-ntfy-notify.sh` is a ready-made [ntfy](https://ntfy.sh)
pusher, so your phone buzzes when an agent finishes or asks for permission. See
[Notifications](#notifications).

### How do I see which tmux pane is waiting for input?

Panes in the `needs-input` state show a red dot in the status line, red text in the
`prefix + a` menu and `prefix + A` dashboard, and are listed in the sidebar. Pick the entry in
the menu to jump there, or click the dot once you add the mouse binding from
[Status-line dots](#status-line-dots).

### Is this a herdr alternative for tmux?

It is a herdr companion for tmux, not a replacement. It reuses herdr's detection rules and
gives you the same per-agent state inside tmux, without a separate multiplexer. If you already
live in tmux, this is the piece herdr is missing.

### Does it work with Codex, OpenCode, Gemini CLI, Copilot, Cursor, aider?

Yes for all of the above and more; see [Supported agents](#supported-agents). aider has no
upstream rules and falls back to the timestamp heuristic. Anything else can self-report
via `scripts/agent-state.sh`.

### Does it need Python packages or a daemon?

The detection engine is Python 3.6+ standard library only, no pip installs. A small
background daemon polls panes every ~1.5s; disable it with `@handlr-daemon off` to fall
back to the mtime heuristic.

## License

Apache-2.0; see [`LICENSE`](LICENSE). The bundled detection manifests under `detection/` are
derived from [herdr](https://github.com/herdrdev/herdr) and remain Apache-2.0 © Herdr, Inc.;
see [`NOTICE`](NOTICE).
