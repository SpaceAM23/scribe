#!/usr/bin/env python3
"""
heal-trend.py — Recurrence-trend (ROI) metric for the self-healing loop.

For each escalated pattern in correction-tracker.json, computes:
  before_per_week  — occurrences-per-week in the window BEFORE escalated_at
  after_per_week   — occurrences-per-week in the window AFTER escalated_at
  improved         — True when after_per_week < before_per_week

Also incorporates signals from normalizations.jsonl and sync-queue.jsonl
(produced by the normalization track) when they carry a 'pattern' field
matching the correction-tracker key.

Data directory resolution (matches writer.sh priority order):
  1. --data CLI argument (explicit override)
  2. SCRIBE_DATA_PATH environment variable
  3. pointer.json (../pointer.json relative to this script, or ./pointer.json)
  4. Default: ~/Desktop/Scribe

Usage:
  python3 heal-trend.py --pattern <name> [--no-signals]
  python3 heal-trend.py --all [--no-signals]
  python3 heal-trend.py --data <path> --pattern <name> [--no-signals]
  python3 heal-trend.py --data <path> --all [--no-signals]

Outputs JSON to stdout.

Python 3 standard library only. Bash 3.2-safe (no shell features used here).
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone


# -- constants -----------------------------------------------------------------

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


# -- date parsing --------------------------------------------------------------

def parse_date(s):
    """Return UTC-aware datetime from ISO date string, or None."""
    if not s:
        return None
    s = s.strip()
    # Normalize trailing Z
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    for fmt in (
        "%Y-%m-%dT%H:%M:%S+00:00",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d",
    ):
        try:
            dt = datetime.strptime(s, fmt)
            return dt.replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    # Last resort: date portion only
    try:
        dt = datetime.strptime(s[:10], "%Y-%m-%d")
        return dt.replace(tzinfo=timezone.utc)
    except ValueError:
        pass
    return None


def weeks_between(a, b):
    """
    Return the number of weeks between two UTC datetimes (b >= a).
    Returns at least 1.0 to avoid division by zero.
    """
    if a is None or b is None:
        return 1.0
    diff = (b - a).total_seconds()
    weeks = diff / (7 * 86400)
    return max(weeks, 1.0)


# -- signal loading ------------------------------------------------------------

def load_signal_dates(data_path, pattern_name, no_signals):
    """
    Load extra occurrence dates from normalizations.jsonl and sync-queue.jsonl.
    Only include lines where 'pattern' == pattern_name (if the field is present).
    Returns a list of UTC-aware datetimes.
    """
    if no_signals:
        return []

    dates = []
    for filename in ("normalizations.jsonl", "sync-queue.jsonl"):
        fpath = os.path.join(data_path, filename)
        if not os.path.isfile(fpath):
            continue
        with open(fpath, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Only count if it explicitly matches this pattern (opt-in)
                if obj.get("pattern") != pattern_name:
                    continue
                ts_str = obj.get("ts") or obj.get("timestamp")
                dt = parse_date(ts_str)
                if dt:
                    dates.append(dt)
    return dates


# -- core computation ----------------------------------------------------------

def compute_trend(pattern_name, pattern_data, data_path, no_signals, today=None):
    """
    Compute before/after trend for a single pattern.
    Returns a dict with keys:
      pattern, before_count, after_count, before_per_week, after_per_week,
      improved, escalated_at
    """
    escalated_at_str = pattern_data.get("escalated_at")
    escalated_dt = parse_date(escalated_at_str)

    if today is None:
        today = datetime.now(timezone.utc)

    # Collect occurrence datetimes from correction-tracker
    occurrences = pattern_data.get("occurrences", [])
    occ_dates = []
    for occ in occurrences:
        dt = parse_date(occ.get("date"))
        if dt:
            occ_dates.append(dt)

    # Add signal dates (normalizations / sync-queue)
    signal_dates = load_signal_dates(data_path, pattern_name, no_signals)
    all_dates = sorted(occ_dates + signal_dates)

    # Baseline result (returned when we lack an escalation anchor)
    result = {
        "pattern": pattern_name,
        "escalated_at": escalated_at_str,
        "before_count": None,
        "after_count": None,
        "before_per_week": None,
        "after_per_week": None,
        "improved": None,
    }

    if escalated_dt is None:
        # Cannot compute without an escalation anchor
        return result

    before_dates = [d for d in all_dates if d < escalated_dt]
    after_dates  = [d for d in all_dates if d >= escalated_dt]

    # BEFORE window: from earliest occurrence to escalated_at
    if before_dates:
        earliest = min(before_dates)
        before_weeks = weeks_between(earliest, escalated_dt)
        before_per_week = len(before_dates) / before_weeks
    else:
        before_per_week = 0.0

    # AFTER window: from escalated_at to today (or last after-occurrence)
    after_weeks = weeks_between(escalated_dt, today)
    after_per_week = len(after_dates) / after_weeks

    improved = after_per_week < before_per_week

    result.update({
        "before_count": len(before_dates),
        "after_count":  len(after_dates),
        "before_per_week": round(before_per_week, 4),
        "after_per_week":  round(after_per_week, 4),
        "improved": improved,
    })
    return result


# -- CLI -----------------------------------------------------------------------

def load_tracker(data_path):
    fpath = os.path.join(data_path, "correction-tracker.json")
    if not os.path.isfile(fpath):
        sys.exit(f"ERROR: correction-tracker.json not found at {fpath}")
    with open(fpath, "r") as f:
        return json.load(f)


def main():
    parser = argparse.ArgumentParser(description="Recurrence-trend metric for self-healing loop")
    parser.add_argument(
        "--data",
        default=None,
        help=(
            "Path to directory containing correction-tracker.json (and optional signals). "
            "When omitted, resolution order: SCRIBE_DATA_PATH env -> pointer.json -> "
            "~/Desktop/Scribe"
        ),
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--pattern", help="Compute trend for a single named pattern")
    group.add_argument("--all", action="store_true", help="Compute trend for all patterns")
    parser.add_argument("--no-signals", action="store_true",
                        help="Ignore normalizations.jsonl and sync-queue.jsonl signals")
    parser.add_argument("--today",
                        help="Override today's date (ISO YYYY-MM-DD) for deterministic testing")
    args = parser.parse_args()

    data_path = resolve_data_path(args.data)
    tracker = load_tracker(data_path)
    patterns = tracker.get("patterns", {})

    today = None
    if args.today:
        today = parse_date(args.today)
        if today is None:
            sys.exit(f"ERROR: could not parse --today value '{args.today}'")

    if args.all:
        results = []
        for name, data in patterns.items():
            results.append(compute_trend(name, data, data_path, args.no_signals, today=today))
        print(json.dumps(results, indent=2))
    else:
        if args.pattern not in patterns:
            sys.exit(f"ERROR: pattern '{args.pattern}' not found in correction-tracker.json")
        result = compute_trend(args.pattern, patterns[args.pattern], data_path,
                               args.no_signals, today=today)
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
