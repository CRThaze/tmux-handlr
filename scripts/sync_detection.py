#!/usr/bin/env python3
"""Sync + validate tmux-handlr's agent-detection manifests: pull herdr's TOML,
convert to JSON, validate, and write the snapshot. NON-runtime; detect.py never imports this."""

import argparse
import datetime
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import detect  # noqa: E402  (translate_regex, compile_pat, region_supported, _KNOWN_RULE_KEYS)

HERDR_CDN = "https://herdr.dev/agent-detection/"
SUPPORTED_SCHEMA_VERSION = 1

# A few agents have id != path (the catalog path basename differs from the id).
# Saved files are always keyed by id; this only documents the quirk.


def _log(msg):
    sys.stderr.write(msg + "\n")


#####################
### fetch / parse ###
#####################

def _fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "tmux-handlr-sync"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()


def _load_toml(raw):
    import tomllib
    return tomllib.loads(raw.decode("utf-8"))


##################
### validation ###
##################

def _validate_structure(man, errors):
    """Structural check. Uses jsonschema when importable, else a minimal manual pass."""
    here = Path(__file__).resolve().parent / ".." / "detection"
    try:
        import jsonschema
        with open(here / "manifest.schema.json", encoding="utf-8") as fh:
            schema = json.load(fh)
        try:
            jsonschema.validate(man, schema)
        except jsonschema.ValidationError as e:
            errors.append(f"schema: {e.message}")
        return
    except ImportError:
        pass
    # Fallback for when jsonschema isn't installed.
    if not isinstance(man.get("id"), str) or not man["id"]:
        errors.append("missing/invalid id")
    if not isinstance(man.get("rules"), list):
        errors.append("missing rules array"); return
    for r in man["rules"]:
        if r.get("state") not in {"working", "blocked", "idle", "unknown"}:
            errors.append(f"rule {r.get('id')}: bad state {r.get('state')!r}")
        if not isinstance(r.get("region"), str) or not r.get("region"):
            errors.append(f"rule {r.get('id')}: missing region")


def _collect_patterns(obj):
    out = []
    for k in ("regex", "line_regex"):
        if k in obj:
            v = obj[k]
            out.extend(v if isinstance(v, list) else [v])
    for k in ("any", "all", "not"):
        for sub in obj.get(k, []) or []:
            out.extend(_collect_patterns(sub))
    return out


_REDOS_INPUTS = [
    "a" * 20000,
    " " * 20000,
    ("ab" * 100 + "! ") * 200,
    "⠀" * 20000,
    "✳ " + "x" * 20000,
]


def _redos_unsafe(pattern):
    """Run the translated pattern against adversarial inputs in a subprocess with a
    wall-clock timeout. True when it fails to finish (catastrophic backtracking)."""
    code = ("import re,sys\n"
            "p=re.compile(sys.argv[1])\n"
            "import json\n"
            "[p.search(s) for s in json.loads(sys.argv[2])]\n")
    try:
        subprocess.run(
            [sys.executable, "-c", code, pattern, json.dumps(_REDOS_INPUTS)],
            timeout=0.5,
            capture_output=True,
        )
        return False
    except subprocess.TimeoutExpired:
        return True
    except (subprocess.SubprocessError, OSError):
        return False


def validate_manifest(man, warnings, errors, seen_patterns):
    _validate_structure(man, errors)
    for rule in man.get("rules", []):
        rid = rule.get("id", "?")
        for key in rule:
            if key not in detect._KNOWN_RULE_KEYS:
                warnings.append(f"{man.get('id')}/{rid}: unknown rule key {key!r} (engine ignores it)")
        region = rule.get("region", "")
        if region and not detect.region_supported(region):
            warnings.append(f"{man.get('id')}/{rid}: unsupported region {region!r} (rule skipped at runtime)")
        for pat in _collect_patterns(rule):
            translated = detect.translate_regex(pat)
            if detect.compile_pat(pat) is None:
                errors.append(f"{man.get('id')}/{rid}: uncompilable regex {pat!r}")
                continue
            if translated in seen_patterns:
                continue
            seen_patterns.add(translated)
            if _redos_unsafe(translated):
                errors.append(f"{man.get('id')}/{rid}: regex fails ReDoS smoke test {pat!r}")


#############
### write ###
#############

def _dump(obj, path):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=1, sort_keys=True)


#############
### modes ###
#############

def do_sync(out_dir, ref, source):
    base = (f"https://raw.githubusercontent.com/herdrdev/herdr/{ref}/distribution/agent-detection/" if source == "github" else HERDR_CDN)
    try:
        index = _load_toml(_fetch(base + "index.toml"))
    except ImportError:
        _log("refresh needs Python 3.11+ (tomllib); the bundled JSON stays in use.")
        return 2
    except (urllib.error.URLError, OSError, ValueError) as e:
        _log(f"fetch/parse index failed: {e}"); return 2

    if index.get("schema_version") != SUPPORTED_SCHEMA_VERSION:
        _log(
            f"FATAL: index schema_version={index.get('schema_version')!r}, expected {SUPPORTED_SCHEMA_VERSION}: catalog shape may have "
            "changed; not consuming."
        )
        return 3

    warnings, errors, seen = [], [], set()
    converted = {}   # id -> manifest dict
    for entry in index.get("agents", []):
        mid, path = entry.get("id"), entry.get("path")
        if not mid or not path:
            errors.append(f"index entry missing id/path: {entry!r}"); continue
        try:
            man = _load_toml(_fetch(base + path))
        except (urllib.error.URLError, OSError, ValueError) as e:
            errors.append(f"{mid}: fetch/parse failed ({e})"); continue
        man.setdefault("id", mid)
        validate_manifest(man, warnings, errors, seen)
        converted[mid] = man

    for w in warnings:
        _log("WARN: " + w)
    if errors:
        for e in errors:
            _log("ERROR: " + e)
        _log(f"FATAL: {len(errors)} validation error(s); nothing written.")
        return 3

    Path(out_dir).mkdir(parents=True, exist_ok=True)
    for mid, man in converted.items():
        _dump(man, Path(out_dir) / (mid + ".json"))
    _dump(index, Path(out_dir) / "index.json")
    _dump({
        "source": "herdrdev/herdr" if source == "github" else "herdr.dev",
        "ref": ref,
        "url": base,
        "schema_version": index.get("schema_version"),
        "synced_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "count": len(converted),
        "ids": sorted(converted),
    }, Path(out_dir) / "UPSTREAM.json")
    _log(f"OK: wrote {len(converted)} manifests to {out_dir} ({len(warnings)} warning(s))")
    return 0


def do_check(out_dir):
    warnings, errors, seen = [], [], set()
    n = 0
    idx_path = Path(out_dir) / "index.json"
    if idx_path.exists():
        with open(idx_path, encoding="utf-8") as fh:
            idx = json.load(fh)
        if idx.get("schema_version") != SUPPORTED_SCHEMA_VERSION:
            errors.append(f"index.json schema_version={idx.get('schema_version')!r}, expected {SUPPORTED_SCHEMA_VERSION}")
    for f in sorted(p.name for p in Path(out_dir).iterdir()):
        if not f.endswith(".json") or f in {"index.json", "UPSTREAM.json",
                                            "manifest.schema.json", "index.schema.json"}:
            continue
        with open(Path(out_dir) / f, encoding="utf-8") as fh:
            man = json.load(fh)
        validate_manifest(man, warnings, errors, seen)
        n += 1
    for w in warnings:
        _log("WARN: " + w)
    if errors:
        for e in errors:
            _log("ERROR: " + e)
        _log(f"FATAL: {len(errors)} validation error(s) in committed JSON.")
        return 3
    _log(f"OK: {n} committed manifests valid ({len(warnings)} warning(s))")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(
        description="Sync/validate agent-detection manifests (non-runtime).",
        epilog="Exit: 0 ok; 2 usage/network; 3 validation failure.",
    )
    ap.add_argument("--out", required=True)
    ap.add_argument("--ref", default="master")
    ap.add_argument("--source", choices=["github", "herdr"], default="github")
    ap.add_argument("--check-only", action="store_true")
    args = ap.parse_args(argv)
    if args.check_only:
        return do_check(args.out)
    return do_sync(args.out, args.ref, args.source)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
