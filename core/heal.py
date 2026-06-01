#!/usr/bin/env python3
"""
heal.py — Self-healing loop: detect -> propose -> apply(auto/tap)

Reads correction-tracker.json and optional signal files to propose and
apply healing interventions.

Autonomy rule (spec §3.1):
  AUTO-apply (safe/reversible data-integrity):
    - add_alias: add a project alias to canonical/projects.json
    - requeue_sync: drain sync-queue.jsonl to Supabase via reconcile.sh (idempotent)
  TAP-queue (risky/behavioral/prompt/destructive — write to heal-queue.json):
    - prompt_change
    - behavioral (required-read gates, process changes)
    - rule_change
    - destructive

NEVER auto-applies prompt changes or destructive operations.

Data directory resolution (matches writer.sh priority order):
  1. --data CLI argument (explicit override)
  2. SCRIBE_DATA_PATH environment variable
  3. pointer.json (../pointer.json relative to this script, or ./pointer.json)
  4. Default: ~/Desktop/Scribe

Usage:
  python3 heal.py                            # resolve data dir automatically, analyze + propose
  python3 heal.py --data <path>              # explicit data dir, analyze + propose
  python3 heal.py --add-alias K=V            # auto-apply alias K -> V
  python3 heal.py --requeue-sync             # auto-apply sync requeue

Outputs:
  heal-queue.json   — tap-gated interventions for human review
  heal-log.jsonl    — auto-applied fixes (append-only audit log)

Python 3 standard library only. No destructive operations on live data.
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone


# -- constants -----------------------------------------------------------------

# Levels that warrant intervention (ordered by severity)
INTERVENTION_LEVELS = {"critical", "guardrail"}

# Which fix_kinds are auto-safe (reversible, data-integrity only)
AUTO_SAFE_FIX_KINDS = {"add_alias", "requeue_sync"}

# Which fix_kinds require a human tap
TAP_REQUIRED_FIX_KINDS = {"prompt_change", "behavioral", "rule_change", "destructive"}

# Default data directory (matches writer.sh default)
DEFAULT_DATA_DIR = os.path.join(os.path.expanduser("~"), "Desktop", "Scribe")


# -- data path resolution ------------------------------------------------------

def resolve_data_path(cli_arg=None):
    """
    Resolve the Scribe data directory using the same priority as writer.sh:
      1. CLI --data argument (explicit override)
      2. SCRIBE_DATA_PATH environment variable
      3. pointer.json (../pointer.json relative to this script, then ./pointer.json)
      4. Default: ~/Desktop/Scribe

    Returns an absolute path string.
    """
    # 1. CLI argument
    if cli_arg:
        return os.path.abspath(cli_arg)

    # 2. Environment variable
    env_path = os.environ.get("SCRIBE_DATA_PATH", "").strip()
    if env_path:
        return os.path.abspath(os.path.expanduser(env_path))

    # 3. pointer.json — check ../pointer.json then ./pointer.json
    script_dir = os.path.dirname(os.path.abspath(__file__))
    for pointer_candidate in (
        os.path.join(script_dir, "..", "pointer.json"),
        os.path.join(script_dir, "pointer.json"),
    ):
        pointer_candidate = os.path.normpath(pointer_candidate)
        if os.path.isfile(pointer_candidate):
            try:
                with open(pointer_candidate, "r") as f:
                    ptr = json.load(f)
                ptr_path = ptr.get("data_path", "").strip()
                if ptr_path:
                    return os.path.abspath(os.path.expanduser(ptr_path))
            except (json.JSONDecodeError, OSError):
                pass

    # 4. Default
    return DEFAULT_DATA_DIR


# -- helpers -------------------------------------------------------------------

def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def load_json(path):
    """Load JSON from path; return None if file doesn't exist."""
    if not os.path.isfile(path):
        return None
    with open(path, "r") as f:
        return json.load(f)


def save_json(path, obj, indent=2):
    with open(path, "w") as f:
        json.dump(obj, f, indent=indent)


def append_jsonl(path, obj):
    with open(path, "a") as f:
        f.write(json.dumps(obj) + "\n")


def read_jsonl(path):
    if not os.path.isfile(path):
        return []
    lines = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    lines.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return lines


# -- intervention catalogue ----------------------------------------------------

def interventions_for_pattern(pattern_name, pattern_data):
    """
    Derive proposed interventions for a pattern based on its level and occurrences.
    Returns a list of intervention dicts.

    Intervention record shape (spec §7 contract):
      {
        pattern:         str,
        fix_kind:        str,   # one of AUTO_SAFE_FIX_KINDS | TAP_REQUIRED_FIX_KINDS
        risk:            str,   # 'low'|'medium'|'high'
        auto_applicable: bool,
        rationale:       str,
        proposed_at:     str,   # ISO timestamp
      }
    """
    level = pattern_data.get("level", "observation")
    occurrences = pattern_data.get("occurrences", [])
    escalated_at = pattern_data.get("escalated_at")
    n = len(occurrences)

    interventions = []

    # Only intervene on escalated/guardrail/critical patterns with enough signal
    if level not in INTERVENTION_LEVELS:
        return []
    if not escalated_at and n < 3:
        return []

    # 1. Behavioral intervention — always tap-gated
    interventions.append({
        "pattern": pattern_name,
        "fix_kind": "behavioral",
        "risk": "medium",
        "auto_applicable": False,
        "rationale": (
            f"Pattern '{pattern_name}' is at level={level} with {n} occurrences "
            f"(escalated: {escalated_at}). Propose adding a required-read gate or "
            "reinforcement in the agent contract. Human review required before applying."
        ),
        "proposed_at": now_iso(),
    })

    # 2. For very high-frequency critical patterns, propose a prompt/rule change
    if level == "critical" and n >= 5:
        interventions.append({
            "pattern": pattern_name,
            "fix_kind": "prompt_change",
            "risk": "high",
            "auto_applicable": False,
            "rationale": (
                f"Pattern '{pattern_name}' has {n} occurrences at critical level. "
                "Propose updating the agent prompt or observer-prompt.md to include "
                "an explicit enforcement rule. Requires human review and tap to apply."
            ),
            "proposed_at": now_iso(),
        })

    return interventions


def should_intervene(pattern_name, pattern_data):
    """Return True if this pattern warrants any intervention."""
    level = pattern_data.get("level", "observation")
    occurrences = pattern_data.get("occurrences", [])
    escalated_at = pattern_data.get("escalated_at")
    n = len(occurrences)
    return level in INTERVENTION_LEVELS and (escalated_at or n >= 3)


# -- auto-apply actions --------------------------------------------------------

def auto_add_alias(data_path, key, value):
    """
    Auto-safe: add an alias entry to canonical/projects.json.
    Logs the action to heal-log.jsonl.
    Returns True on success, raises on failure.
    """
    projects_path = os.path.join(data_path, "canonical", "projects.json")
    projects = load_json(projects_path)
    if projects is None:
        raise FileNotFoundError(f"canonical/projects.json not found at {projects_path}")

    aliases = projects.get("aliases", {})
    if key in aliases and aliases[key] == value:
        # Already present — idempotent, just log
        append_jsonl(os.path.join(data_path, "heal-log.jsonl"), {
            "ts": now_iso(),
            "fix_kind": "add_alias",
            "key": key,
            "value": value,
            "status": "already_present",
            "auto_applied": True,
        })
        return True

    aliases[key] = value
    projects["aliases"] = aliases
    save_json(projects_path, projects)

    append_jsonl(os.path.join(data_path, "heal-log.jsonl"), {
        "ts": now_iso(),
        "fix_kind": "add_alias",
        "key": key,
        "value": value,
        "status": "applied",
        "auto_applied": True,
    })
    return True


def auto_requeue_sync(data_path):
    """
    Auto-safe: drain the sync backlog by invoking reconcile.sh, which replays
    sync-queue.jsonl to Supabase (idempotent: ON CONFLICT (id) DO NOTHING) and
    removes ONLY the entries that succeed. Entries that cannot sync REMAIN in
    sync-queue.jsonl — they are never moved to an unconsumed file, so nothing is
    ever stranded. Logs the action to heal-log.jsonl. Returns the number of
    entries still queued after the reconcile attempt.
    """
    sync_path = os.path.join(data_path, "sync-queue.jsonl")
    log_path = os.path.join(data_path, "heal-log.jsonl")

    before = len(read_jsonl(sync_path))
    if before == 0:
        return 0

    # Look for reconcile.sh alongside this script (core/) then in data_path
    script_dir = os.path.dirname(os.path.abspath(__file__))
    reconcile = os.path.join(script_dir, "reconcile.sh")
    if not os.path.isfile(reconcile):
        # Fallback: data_path sibling
        reconcile = os.path.join(data_path, "reconcile.sh")

    if not os.path.isfile(reconcile):
        status = "reconcile_unavailable"
    else:
        env = dict(os.environ)
        env["SCRIBE_DATA_PATH"] = data_path
        try:
            result = subprocess.run(
                ["bash", reconcile], env=env, capture_output=True, timeout=120,
            )
            status = "reconciled" if result.returncode == 0 else "reconcile_incomplete"
        except Exception:
            status = "reconcile_error"

    after = len(read_jsonl(sync_path))
    append_jsonl(log_path, {
        "ts": now_iso(),
        "fix_kind": "requeue_sync",
        "queued_before": before,
        "queued_after": after,
        "drained": before - after,
        "status": status,
        "auto_applied": True,
    })
    return after


# -- queue management ----------------------------------------------------------

def load_heal_queue(data_path):
    path = os.path.join(data_path, "heal-queue.json")
    existing = load_json(path)
    if existing is None:
        return []
    if isinstance(existing, list):
        return existing
    return []


def save_heal_queue(data_path, queue):
    path = os.path.join(data_path, "heal-queue.json")
    save_json(path, queue)


def enqueue_interventions(data_path, interventions):
    """Append new interventions to heal-queue.json (deduplicated by pattern+fix_kind)."""
    queue = load_heal_queue(data_path)
    existing_keys = {(e.get("pattern"), e.get("fix_kind")) for e in queue}
    added = 0
    for item in interventions:
        key = (item.get("pattern"), item.get("fix_kind"))
        if key not in existing_keys:
            queue.append(item)
            existing_keys.add(key)
            added += 1
    save_heal_queue(data_path, queue)
    return added


# -- main analysis -------------------------------------------------------------

def analyze_and_propose(data_path):
    """
    Read correction-tracker.json, derive interventions, write heal-queue.json.
    Auto-applies zero ops (analyze-only pass).
    """
    tracker_path = os.path.join(data_path, "correction-tracker.json")
    tracker = load_json(tracker_path)
    if tracker is None:
        # Empty tracker is fine — nothing to heal
        tracker = {"patterns": {}}

    patterns = tracker.get("patterns", {})
    all_interventions = []
    for name, data in patterns.items():
        if should_intervene(name, data):
            all_interventions.extend(interventions_for_pattern(name, data))

    if all_interventions:
        added = enqueue_interventions(data_path, all_interventions)
        print(f"heal.py: proposed {added} new intervention(s) -> heal-queue.json")
    else:
        print("heal.py: no new interventions required")

    return all_interventions


# -- CLI -----------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Self-healing loop: detect -> propose -> apply(auto/tap)"
    )
    parser.add_argument(
        "--data",
        default=None,
        help=(
            "Path to Scribe data directory (contains correction-tracker.json). "
            "When omitted, resolution order: SCRIBE_DATA_PATH env -> pointer.json -> "
            "~/Desktop/Scribe"
        ),
    )
    parser.add_argument("--add-alias", metavar="KEY=VALUE",
                        help="Auto-apply: add project alias (e.g. 'My Project=my-project')")
    parser.add_argument("--requeue-sync", action="store_true",
                        help="Auto-apply: drain sync-queue.jsonl to Supabase via reconcile.sh")
    args = parser.parse_args()

    data_path = resolve_data_path(args.data)

    # -- Auto-apply: alias -----------------------------------------------------
    if args.add_alias:
        if "=" not in args.add_alias:
            sys.exit("ERROR: --add-alias requires KEY=VALUE format (e.g. 'My Project=my-project')")
        key, value = args.add_alias.split("=", 1)
        key, value = key.strip(), value.strip()
        auto_add_alias(data_path, key, value)
        print(f"heal.py: auto-applied alias '{key}' -> '{value}'")
        return

    # -- Auto-apply: requeue sync ----------------------------------------------
    if args.requeue_sync:
        remaining = auto_requeue_sync(data_path)
        print(f"heal.py: ran reconcile; {remaining} entry(ies) still queued in sync-queue.jsonl")
        return

    # -- Default: analyze + propose (tap-queue risky fixes) -------------------
    analyze_and_propose(data_path)


if __name__ == "__main__":
    main()
