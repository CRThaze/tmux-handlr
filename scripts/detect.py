#!/usr/bin/env python3
"""tmux-handlr detection engine.

For every agent pane we take its OSC title (tmux #{pane_title}) and its rendered
screen (tmux capture-pane) and run them through per-agent rule manifests,
resolving working / needs-input / idle. This mirrors what herdr does. Stdlib
only (json, re, subprocess, os, sys, time, pathlib), 3.11+: the rules arrive as
JSON (sync_detection.py turns herdr's TOML into it at packaging/sync time), so
tomllib is never needed here.

Modes:
  detect.py --daemon                 loop over every agent pane, synthesize the
                                     transient "done" state, fire the notify hooks
                                     on edges, write the state cache.
  detect.py --pane %N [--type T]     resolve one pane and print its state.
  detect.py --selftest               run the assert-based demo().

State mapping (herdr -> ours): working->running, blocked->needs-input,
idle->idle, unknown/skip_state_update->hold-previous. "done" is not a herdr
state; the daemon manufactures it on a running/needs-input -> idle edge.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

HOLD = "__hold__"                       # recognized, don't change state
_STATE_MAP = {"working": "running", "blocked": "needs-input", "idle": "idle"}
_PAT_CACHE = {}                         # translated-pattern -> compiled re or None

#######################################
### regex: Rust syntax -> Python re ###
#######################################

def translate_regex(p: str) -> str:
    """Turn the Rust-regex constructs herdr relies on into Python re syntax."""
    def sub(m: re.Match[str]) -> str:
        h = int(m.group(1), 16)
        return f"\\u{h:04x}" if h <= 0xFFFF else f"\\U{h:08x}"
    # Rust writes codepoint escapes as \x{2800} and \u{fe0f} alike; Python re
    # expects \uHHHH / \U00HHHHHH. Both braced forms get translated.
    p = re.sub(r"\\[xu]\{([0-9A-Fa-f]+)\}", sub, p)
    p = p.replace(r"\p{Alphabetic}", r"[^\W\d_]")  # stdlib re lacks \p{}; alpha approximation
    p = re.sub(r"(?<!\\)\\z", r"\\Z", p)           # Rust end-of-text \z -> Python \Z (no \z in re)
    return p


def compile_pat(pattern: str) -> re.Pattern[str] | None:
    """Compile a (Rust-syntax) pattern into a Python re; cached. None on failure."""
    if pattern in _PAT_CACHE:
        return _PAT_CACHE[pattern]
    try:
        c = re.compile(translate_regex(pattern))
    except re.error:
        c = None
    _PAT_CACHE[pattern] = c
    return c


def _as_list(v: object) -> list:
    return v if isinstance(v, list) else [v]

##################################################
### regions: computed once per (title, screen) ###
##################################################

_RULE_CHARS = set("-=—─━═╌╍╎┈┉│┃")
_BOX_TOP = "╭┌╔┏"
_BOX_BOT = "╰└╚┗"
_MARKERS = ("❯", ">")


class RegionCtx(object):
    """Resolves herdr region names to text lazily, for one pane snapshot."""

    def __init__(self, title: str | None, screen: str | None) -> None:
        self.title = title or ""
        self.screen = screen or ""
        self.lines = self.screen.split("\n")
        self.non_empty = [ln for ln in self.lines if ln.strip()]
        self._cache: dict[str, str | None] = {}

    def get(self, name: str) -> str | None:
        if name in self._cache:
            return self._cache[name]
        val = self._compute(name)
        self._cache[name] = val
        return val

    def _compute(self, name: str) -> str | None:
        if name == "osc_title":
            return self.title
        if name == "whole_recent":
            return self.screen
        m = re.match(r"(bottom|top)_non_empty_lines\((\d+)\)$", name)
        if m:
            n = int(m.group(2))
            ne = self.non_empty
            return "\n".join(ne[-n:] if m.group(1) == "bottom" else ne[:n])
        if name == "after_last_horizontal_rule":
            i = self._last_rule_idx()
            return "\n".join(self.lines[i + 1:]) if i is not None else ""
        if name == "prompt_box_body":
            return self._prompt_box_body()
        if name == "after_last_prompt_marker":
            i = self._last_marker_idx()
            return "\n".join(self.lines[i + 1:]) if i is not None else ""
        if name == "whole_recent_without_current_prompt_marker":
            i = self._last_marker_idx()
            if i is None:
                return self.screen
            return "\n".join(self.lines[:i] + self.lines[i + 1:])
        if name == "last_non_empty_above_prompt_box":
            b = self._box_top_idx()
            if b is None:
                return ""
            for ln in reversed(self.lines[:b]):
                if ln.strip():
                    return ln
            return ""
        return None                     # osc_progress and every unknown region

    def _is_rule(self, ln: str) -> bool:
        s = ln.strip()
        return len(s) >= 3 and set(s) <= _RULE_CHARS

    def _last_rule_idx(self) -> int | None:
        for i in range(len(self.lines) - 1, -1, -1):
            if self._is_rule(self.lines[i]):
                return i
        return None

    def _box_top_idx(self) -> int | None:
        for i in range(len(self.lines) - 1, -1, -1):
            if any(c in self.lines[i] for c in _BOX_TOP):
                return i
        return None

    def _prompt_box_body(self) -> str:
        top = self._box_top_idx()
        if top is None:
            return "\n".join(self.non_empty[-3:])       # rough: the bottom lines
        bot = None
        for j in range(top + 1, len(self.lines)):
            if any(c in self.lines[j] for c in _BOX_BOT):
                bot = j
                break
        end = bot if bot is not None else len(self.lines)
        return "\n".join(self.lines[top + 1:end])

    def _last_marker_idx(self) -> int | None:
        for i in range(len(self.lines) - 1, -1, -1):
            s = self.lines[i].lstrip()
            if any(s.startswith(mk) for mk in _MARKERS):
                return i
        return None

##########################
### matcher evaluation ###
##########################

_MATCHER_KEYS = ("regex", "line_regex", "contains", "any", "all", "not")
# Keys the engine understands (matchers + metadata). sync_detection.py flags
# anything outside this set as an upstream capability change to review.
_KNOWN_RULE_KEYS = frozenset(_MATCHER_KEYS + (
    "id", "state", "priority", "region",
    "visible_working", "visible_blocker", "visible_idle", "skip_state_update"))


def region_supported(name: str) -> bool:
    """True when the engine implements this region name (osc_progress and
    unknown names are unsupported). sync_detection.py surfaces new regions via it."""
    return RegionCtx("", "").get(name) is not None


def _eval_obj(obj: dict, text: str, lines: list[str], low: str) -> bool:
    """True when the match-object matches the region (text/lines/lowercased text)."""
    for key in _MATCHER_KEYS:
        if key not in obj:
            continue
        val = obj[key]
        if key == "regex":
            if not any((compile_pat(p) or _NEVER).search(text) for p in _as_list(val)):
                return False
        elif key == "line_regex":
            pats = [compile_pat(p) or _NEVER for p in _as_list(val)]
            if not any(p.search(ln) for p in pats for ln in lines):
                return False
        elif key == "contains":
            if not all(s.lower() in low for s in _as_list(val)):
                return False
        elif key == "any":
            if not any(_eval_obj(o, text, lines, low) for o in val):
                return False
        elif key == "all":
            if not all(_eval_obj(o, text, lines, low) for o in val):
                return False
        elif key == "not":
            if any(_eval_obj(o, text, lines, low) for o in val):
                return False
    return True


_NEVER = re.compile(r"(?!x)x")          # compiles but never matches (stand-in for a bad pattern)

#################
### manifests ###
#################

def _detection_dirs() -> list[Path]:
    """The rule dirs, lowest precedence (bundled) first, refreshed last."""
    here = Path(__file__).resolve().parent
    bundled = here.parent / "detection"
    data_home = os.environ.get("XDG_DATA_HOME")
    data_home = Path(data_home) if data_home else Path.home() / ".local/share"
    refreshed = data_home / "tmux-handlr" / "detection"
    return [bundled, refreshed]


def _rule_matchable(rule: dict) -> bool:
    """A rule is usable when its region is supported and every pattern compiles."""
    region = rule.get("region", "")
    probe = RegionCtx("", "").get(region) if region != "osc_title" else ""
    # osc_title/whole_recent always resolve; parametrized/known regions come back
    # as "" (not None); unknown/osc_progress come back None, i.e. unsupported.
    if region not in {"osc_title", "whole_recent"} and probe is None:
        return False
    if not any(k in rule for k in _MATCHER_KEYS):
        return False                    # no matcher would match everything; skip
    for pat in _collect_patterns(rule):
        if compile_pat(pat) is None:
            return False
    return True


def _collect_patterns(obj: dict) -> list[str]:
    out = []
    for k in ("regex", "line_regex"):
        if k in obj:
            out.extend(_as_list(obj[k]))
    for k in ("any", "all", "not"):
        if k in obj:
            for sub in obj[k]:
                out.extend(_collect_patterns(sub))
    return out


def load_manifests(dirs: list[Path] | None = None) -> dict[str, dict]:
    """type/alias -> manifest dict (rules priority-desc, unusable ones dropped)."""
    dirs = dirs or _detection_dirs()
    by_id = {}
    for d in dirs:
        if not d.is_dir():
            continue
        for f in d.glob("*.json"):
            base = f.name
            if base == "index.json" or base == "UPSTREAM.json" or base.endswith(".schema.json"):
                continue
            try:
                with open(f, encoding="utf-8") as fh:
                    man = json.load(fh)
            except (ValueError, OSError):
                continue
            mid = man.get("id") or f.stem
            rules = [r for r in man.get("rules", []) if _rule_matchable(r)]
            rules.sort(key=lambda r: r.get("priority", 0), reverse=True)
            man["_rules"] = rules
            # Highest priority among rules that need the screen (region != osc_title).
            # A title-only match may short-circuit the capture only if it outranks
            # this; otherwise a low-priority idle-title rule would hide a higher-
            # priority blocked/working rule that only shows on screen.
            man["_max_screen_prio"] = max(
                [r.get("priority", 0) for r in rules if r.get("region") != "osc_title"],
                default=0)
            by_id[mid] = man
    index = {}
    for man in by_id.values():
        index[man.get("id")] = man
        for alias in man.get("aliases", []) or []:
            index.setdefault(alias, man)
    return index


def evaluate(manifest: dict, ctx: RegionCtx, restrict: set[str] | None = None) -> dict | None:
    """Return the winning rule (highest priority that matches) or None.

    restrict: if given, only rules whose region is in this set are considered
    (used for the cheap title-only first pass)."""
    for rule in manifest.get("_rules", []):
        region = rule.get("region", "")
        if restrict is not None and region not in restrict:
            continue
        text = ctx.get(region)
        if text is None:
            continue
        lines = text.split("\n")
        if _eval_obj(rule, text, lines, text.lower()):
            return rule
    return None


def _rule_to_state(rule: dict | None) -> str | None:
    if rule is None:
        return None
    if rule.get("skip_state_update"):
        return HOLD
    return _STATE_MAP.get(rule.get("state"), HOLD)   # unknown states hold

##########################
### high-level resolve ###
##########################

def resolve(
    manifest: dict | None,
    title: str,
    capture_fn: Callable[[], str | None],
    marker_present: bool = False,
) -> str | None:
    """Resolve one pane to 'running'|'needs-input'|'idle'|HOLD, or None (no
    verdict; the caller falls back to the mtime heuristic)."""
    if manifest is None:
        return "needs-input" if marker_present else None
    # Rung 1: title only (cheap, skips capture-pane). Trust it only when the
    # matching title rule outranks every screen rule; otherwise a low-priority
    # idle-title match could mask a higher-priority blocked/working rule that
    # needs the screen.
    trule = evaluate(manifest, RegionCtx(title, ""), restrict={"osc_title"})
    if trule is not None and trule.get("priority", 0) >= manifest.get("_max_screen_prio", 0):
        st = _rule_to_state(trule)
        if st in {"running", "needs-input", "idle"}:
            return st
    # Rung 2/3: full screen plus the full ruleset.
    ctx = RegionCtx(title, capture_fn() or "")
    rule = evaluate(manifest, ctx)
    st = _rule_to_state(rule)
    if st is not None:
        return st
    # Rung 3.5: the needs-input marker as a fallback hint (claude accelerator).
    if marker_present:
        return "needs-input"
    return None

####################
### tmux helpers ###
####################

def _tmux(*args: str) -> str | None:
    try:
        return subprocess.check_output(("tmux",) + args, stderr=subprocess.DEVNULL).decode("utf-8", "replace")
    except (subprocess.CalledProcessError, OSError):
        return None


def capture_pane(pane: str) -> str:
    out = _tmux("capture-pane", "-p", "-t", pane)
    return out if out is not None else ""


def pane_title(pane: str) -> str:
    out = _tmux("display-message", "-p", "-t", pane, "#{pane_title}")
    return (out or "").rstrip("\n")


def tmux_opt(name: str, default: str = "") -> str:
    out = _tmux("show-option", "-gqv", name)
    out = (out or "").rstrip("\n")
    return out if out else default


def marker_present(pane: str) -> bool:
    cache = os.environ.get("XDG_CACHE_HOME")
    cache = Path(cache) if cache else Path.home() / ".cache"
    return (cache / "agent-state" / "needs-input" / pane).exists()


def runtime_dir() -> Path:
    d = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "tmux-handlr"
    try:
        d.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return d


def take_dismiss(pane: str) -> bool:
    """True if a 'dismiss done' was requested for this pane; consumes the marker.
    agent-dismiss.sh writes it so the user can clear a held done flash early."""
    try:
        (runtime_dir() / "dismiss" / pane).unlink()
        return True
    except OSError:
        return False


def _int_opt(name: str, default: int, fallback: str = "") -> int:
    v = tmux_opt(name, "") or (tmux_opt(fallback, "") if fallback else "")
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def enum_agent_panes(lib: str) -> list[dict[str, str]] | None:
    """Reuse the bash lib's enumeration (the single source of truth for "what is
    an agent"). Returns a list of row dicts, or None when the tmux server is gone."""
    if _tmux("list-panes", "-a", "-F", "#{pane_id}") is None:
        return None                     # server gone: signal the loop to exit
    try:
        out = subprocess.check_output(
            ["bash", "-c", 'source "$1"; enum_agent_panes', "_", lib],
            stderr=subprocess.DEVNULL).decode("utf-8", "replace")
    except (subprocess.CalledProcessError, OSError):
        return []
    cols = ("pane", "type", "tty", "widx", "wname", "pid", "cwd", "title", "sname")
    rows = []
    for line in out.split("\n"):
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < len(cols):
            parts += [""] * (len(cols) - len(parts))
        rows.append(dict(zip(cols, parts)))
    return rows


_OVERRIDE_MAP = {
    "running": "running",
    "needs-input": "needs-input",
    "done": "idle",
    "idle": "idle",
}


def read_override(pane: str, now: float, ttl: float) -> str | None:
    """An authoritative state written by agent-state.sh (e.g. dsh's native
    events); honored above screen-scraping while it's fresh. Returns a raw
    state or None. 'done' maps to idle so the daemon's own done-flash
    synthesis still applies."""
    f = runtime_dir() / "override" / pane
    try:
        with open(f, encoding="utf-8") as fh:
            parts = fh.read().split()
    except OSError:
        return None
    if len(parts) < 2:
        return None
    try:
        if now - float(parts[1]) > ttl:
            return None
    except ValueError:
        return None
    return _OVERRIDE_MAP.get(parts[0])


def _synth(pane: str, raw: str, track: dict[str, dict], now: float,
           done_window: int, min_done: float = 0) -> str | None:
    """Fold a raw state (running|needs-input|idle|HOLD) into the per-pane state,
    synthesizing a transient 'done' on a running/needs-input -> idle edge.

    min_done debounces that edge: idle must persist that many seconds before we
    flash done, so a momentary quiet (between steps, or before the after-action
    report finishes printing) is held as the prior busy state instead of a
    premature green. A running/needs-input reading inside the window cancels it."""
    t = track.setdefault(pane, {"state": None, "done_until": None, "idle_since": None})
    if raw == HOLD:
        if t["state"] == "done" and t["done_until"] and now >= t["done_until"]:
            t["state"] = "idle"; t["done_until"] = None
        return t["state"]
    prev = t["state"]
    if raw in {"running", "needs-input"}:
        t["state"] = raw; t["done_until"] = None; t["idle_since"] = None
    else:  # idle
        if prev in {"running", "needs-input"}:
            if min_done <= 0:
                t["state"] = "done"; t["done_until"] = now + done_window
            elif t.get("idle_since") is None:
                t["idle_since"] = now                       # start the debounce; hold prev
            elif now - t["idle_since"] >= min_done:
                t["state"] = "done"; t["done_until"] = now + done_window
                t["idle_since"] = None
            # else: still debouncing, keep prev (running/needs-input)
        elif prev == "done" and t["done_until"] and now < t["done_until"]:
            t["state"] = "done"
        else:
            t["state"] = "idle"; t["done_until"] = None; t["idle_since"] = None
    return t["state"]


def _write_cache(path: str, states: dict[str, str]) -> None:
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            for pane, st in states.items():
                fh.write(f"{pane}\t{st}\n")
        os.replace(tmp, path)
    except OSError:
        pass


def _fire_notify(
    cmd: str,
    agent: str,
    state: str,
    session: str,
    window: str,
    notify_states: set[str],
) -> None:
    env = dict(os.environ)
    env.update(
        AGENT_NAME=agent,
        AGENT_STATE=state,
        AGENT_SESSION=session or "",
        AGENT_WINDOW=window or "",
        # keep the notify script's own state filter in step with ours, so a
        # daemon-fired needs-input isn't dropped by its default (done-only).
        AGENT_NTFY_STATES=",".join(sorted(notify_states)),
    )
    try:
        subprocess.Popen(
            cmd,
            shell=True,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def daemon_loop() -> None:
    lib = str(Path(__file__).resolve().parent / "agent-status-lib.sh")
    rd = runtime_dir()
    cachefile = str(rd / "state.tsv")
    pidfile = rd / "daemon.pid"
    try:
        with open(pidfile, "w") as fh:
            fh.write(str(os.getpid()))
    except OSError:
        pass

    manifests = load_manifests()
    track = {}            # pane -> {state, done_until}
    last_state = {}       # pane -> last state we notified on
    cfg_at = 0.0
    done_window = done_delay = notify_cmd = notify_states = marker_on = None
    interval, idle_backoff = 1.5, 5.0

    try:
        while True:
            now = time.time()
            if now - cfg_at > 20:       # pick up option changes without a restart
                done_window = _int_opt("@handlr-done-window", 120, "@agent-status-done-window")
                done_delay = _int_opt("@handlr-done-delay", 3)
                notify_cmd = tmux_opt("@handlr-notify-command", "")
                notify_states = set(s for s in tmux_opt("@handlr-notify-states", "done,needs-input").split(",") if s)
                marker_on = tmux_opt("@handlr-marker", "on") != "off"
                cfg_at = now

            rows = enum_agent_panes(lib)
            if rows is None:            # tmux server is gone
                break

            out = {}
            seen = set()
            for row in rows:
                pane, typ = row["pane"], row["type"]
                seen.add(pane)
                raw = read_override(pane, now, done_window)   # authoritative (e.g. dsh)
                if raw is None:
                    man = manifests.get(typ)
                    mk = bool(marker_on and typ == "claude" and marker_present(pane))
                    raw = resolve(man, row["title"], (lambda p=pane: capture_pane(p)), mk)
                    if man is None and raw is None:
                        continue        # no manifest, no verdict: the bash mtime fallback fills it
                    if raw is None:
                        raw = "idle"    # a manifest exists but nothing matched: idle
                # A user "dismiss" drops a held done flash straight to idle instead
                # of waiting out @handlr-done-window. Only acts when the pane reads
                # idle (i.e. actually in the flash); a live agent is left untouched,
                # and the one-shot marker is consumed either way.
                if take_dismiss(pane) and raw == "idle":
                    track[pane] = {"state": "idle", "done_until": None, "idle_since": None}
                final = _synth(pane, raw, track, now, done_window, done_delay)
                if final is not None:
                    out[pane] = final

            for p in list(track):       # forget panes that vanished
                if p not in seen:
                    track.pop(p, None); last_state.pop(p, None)

            _write_cache(cachefile, out)

            if notify_cmd:
                for pane, st in out.items():
                    if st != last_state.get(pane):
                        if st in notify_states:
                            row = next((r for r in rows if r["pane"] == pane), {})
                            _fire_notify(notify_cmd, row.get("type", "agent"), st,
                                         row.get("sname", ""), row.get("wname", ""), notify_states)
                        last_state[pane] = st

            time.sleep(interval if rows else idle_backoff)
    finally:
        try:
            if pidfile.exists() and pidfile.read_text().strip() == str(os.getpid()):
                pidfile.unlink()
        except OSError:
            pass

#####################
### CLI: one-shot ###
#####################

def _one_shot(pane: str, type_hint: str) -> None:
    manifests = load_manifests()
    title = pane_title(pane)
    if type_hint:
        man = manifests.get(type_hint)
    else:
        # Without a type we can only probe the title generically.
        man = None
    st = resolve(man, title, lambda: capture_pane(pane), marker_present(pane))
    print(st if st and st != HOLD else (st == HOLD and "hold" or "idle" if man else "—"))


################
### selftest ###
################

def demo() -> None:
    assert translate_regex(r"^[\x{2800}-\x{28FF}] ") == r"^[\u2800-\u28ff] "
    assert translate_regex(r"\x{1F600}") == r"\U0001f600"
    assert translate_regex(r"\u{fe0f}") == r"\ufe0f"          # the Rust \u{...} form too
    assert r"\p{Alphabetic}" not in translate_regex(r"\p{Alphabetic}")
    assert translate_regex(r"continue\s*\z") == r"continue\s*\Z"   # Rust end-anchor
    assert translate_regex(r"lit\\z") == r"lit\\z"                 # escaped \\z left alone

    m = load_manifests()
    assert "claude" in m and "codex" in m and "opencode" in m, "bundled manifests missing"

    def chk(desc: str, typ: str, title: str, screen: str, want: str) -> None:
        man = m.get(typ)
        got = resolve(man, title, lambda: screen, False)
        got = {None: "idle"}.get(got, got)   # None means the mtime fallback; treat it as idle here
        assert got == want, f"{desc}: got {got!r} want {want!r}"

    # claude: OSC title glyphs
    chk("claude working (braille title)", "claude", "\u2802 building", "", "running")
    chk("claude idle (star title)", "claude", "\u2733 done", "", "idle")
    # claude: permission prompt on the screen means needs-input
    perm = ("Some question\n"
            "──────────────────────────\n"
            "Do you want to proceed?\n"
            "❯ 1. Yes\n"
            "  2. No\n"
            "  esc to cancel")
    chk("claude permission prompt", "claude", "claude", perm, "needs-input")
    # Regression: an idle-looking OSC title (✳) must not mask a blocked screen.
    # Rung 1 may only short-circuit when the title rule outranks the screen rules.
    chk("claude idle title + blocked screen", "claude", "✳ done", perm, "needs-input")
    # claude: empty prompt box means idle
    idle = ("some output\n"
            "╭──────────────────────────╮\n"
            "❯                           \n"
            "╰──────────────────────────╯")
    chk("claude idle prompt box", "claude", "claude", idle, "idle")
    # codex: Action Required title means blocked
    chk("codex action required", "codex", "Action Required", "", "needs-input")
    # codex: braille spinner title means working
    chk("codex working", "codex", "\u280b thinking", "", "running")
    # opencode: permission required means blocked (no osc_title rules; reaches screen)
    chk("opencode permission", "opencode", "opencode",
        "\u25b3 Permission required\n↑↓ select   ⇆ tab   enter confirm   esc dismiss", "needs-input")
    # opencode: interrupt hint means working
    chk("opencode working", "opencode", "opencode", "thinking... esc to interrupt", "running")
    # dsh (deepseek-harness TUI): a braille-spinner title means working, a ✦ title
    # means idle; esc-to-interrupt on screen means working even when the title
    # carries no state glyph.
    chk("dsh working (braille title)", "dsh-tui","⠐ \U0001F40B Please run a long task", "", "running")
    chk("dsh idle (sparkle title)", "dsh-tui","✦ \U0001F40B ",
        "╭───╮\n  ❯            ⍟\n╰───╯\n qwen · max", "idle")
    chk("dsh working (screen esc-to-interrupt)", "dsh-tui","\U0001F40B no-state-glyph",
        "✻ Pinging the model… · total 18s\n╭───╮\n  ❯       ⍟\n╰───╯\n esc to interrupt", "running")

    # dismiss: a held "done" flash returns to idle once its tracked state is reset
    # (what take_dismiss + the daemon do), instead of waiting out the done window.
    tk: dict[str, dict] = {}
    assert _synth("%1", "running", tk, 1000.0, 120) == "running"
    assert _synth("%1", "idle", tk, 1001.0, 120) == "done"     # running -> idle flashes done
    assert _synth("%1", "idle", tk, 1002.0, 120) == "done"     # and stays held
    tk["%1"] = {"state": "idle", "done_until": None}           # the dismiss
    assert _synth("%1", "idle", tk, 1003.0, 120) == "idle"     # now idle

    # done-delay debounce: idle must persist min_done seconds before flashing done;
    # a blip back to running inside the window cancels it.
    tk = {}
    assert _synth("%2", "running", tk, 1000.0, 120, 3) == "running"
    assert _synth("%2", "idle", tk, 1001.0, 120, 3) == "running"   # held: 1s < 3s
    assert _synth("%2", "running", tk, 1002.0, 120, 3) == "running"  # blip cancels
    assert _synth("%2", "idle", tk, 1003.0, 120, 3) == "running"   # debounce restarts
    assert _synth("%2", "idle", tk, 1007.0, 120, 3) == "done"     # 4s >= 3s: now done

    print(f"detect.py selftest OK ({len(set(id(v) for v in m.values()))} manifests loaded)")


#############
### entry ###
#############

def main(argv: list[str]) -> int:
    if "--selftest" in argv or "--demo" in argv:
        demo()
        return 0
    if "--daemon" in argv:
        daemon_loop()
        return 0
    if "--pane" in argv:
        i = argv.index("--pane")
        pane = argv[i + 1]
        type_hint = ""
        if "--type" in argv:
            type_hint = argv[argv.index("--type") + 1]
        _one_shot(pane, type_hint)
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
