#!/usr/bin/env python3
"""track-corrections.py — update correction-tracker.json from a journal entry.

Called by writer.sh (section 17). The entry JSON arrives on STDIN — never via
shell substitution into source code (the old inline-heredoc approach crashed
json.loads on entries containing escaped quotes, silently discarding
correction data after the journal write, and was a latent code-exec vector).

Usage:
    printf '%s' "$ENTRY_JSON" | python3 track-corrections.py <tracker_path>

Exit codes:
    0  tracker updated (or entry had no corrections — no-op)
    1  bad input / tracker unreadable / write failure (writer treats as non-fatal)

The tracker file is written atomically (tmp + os.replace) so a concurrent
reader never sees a partial file. writer.sh holds the writer lock around this
call, so no two tracker updates race each other.
"""

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

# =============================================================================
# PATTERN MATCHING SECTION
#
# Everything between these markers is the correction->pattern matching logic.
# Corrections are classified against the CONTROLLED VOCABULARY in
# canonical/correction-patterns.json (sibling of the tracker file): ~10 named
# patterns with ordered regex/keyword matchers, plus an explicit
# 'uncategorized' catch-all. New slugs are NEVER minted automatically — the
# old auto-slugging produced ~180 one-off patterns that buried the real ones
# and killed repeat-detection. An unmatched correction goes to 'uncategorized'
# with its FULL text preserved so it can be manually reclassified later.
#
# If the vocabulary file is missing or unreadable, every correction falls back
# to 'uncategorized' (text preserved) — lossless, and the tracker can always
# be rebuilt from the journal once the vocabulary is restored.
# =============================================================================

VOCABULARY_RELPATH = os.path.join("canonical", "correction-patterns.json")
CATCH_ALL_SLUG = "uncategorized"

_FALLBACK_CATCH_ALL = {
    "slug": CATCH_ALL_SLUG,
    "definition": ("Explicit catch-all for corrections matching no named pattern — "
                   "text preserved in full; never escalates."),
    "aliases": [],
    "matchers": [],
    "escalate": False,
    "catch_all": True,
}

_VOCAB_CACHE = None


def _data_dir():
    """The scribe data dir is wherever the tracker file lives (argv[1])."""
    if len(sys.argv) >= 2 and sys.argv[1]:
        return os.path.dirname(os.path.abspath(sys.argv[1])) or "."
    return "."


def load_vocabulary():
    """Load the controlled vocabulary (cached). Always returns a non-empty
    ordered list of pattern dicts whose last resort is the catch-all."""
    global _VOCAB_CACHE
    if _VOCAB_CACHE is not None:
        return _VOCAB_CACHE

    path = os.path.join(_data_dir(), VOCABULARY_RELPATH)
    patterns = []
    try:
        with open(path) as f:
            doc = json.load(f)
        if isinstance(doc, dict) and isinstance(doc.get("patterns"), list):
            patterns = [p for p in doc["patterns"]
                        if isinstance(p, dict) and p.get("slug")]
        if not patterns:
            print(f"track-corrections: vocabulary at {path} has no usable patterns — "
                  f"all corrections will land in '{CATCH_ALL_SLUG}' (text preserved).",
                  file=sys.stderr)
    except FileNotFoundError:
        print(f"track-corrections: vocabulary not found at {path} — "
              f"all corrections will land in '{CATCH_ALL_SLUG}' (text preserved).",
              file=sys.stderr)
    except (json.JSONDecodeError, ValueError, OSError) as e:
        print(f"track-corrections: vocabulary at {path} unreadable ({e}) — "
              f"all corrections will land in '{CATCH_ALL_SLUG}' (text preserved).",
              file=sys.stderr)

    # Guarantee a catch-all exists even if the file omits it.
    if not any(p.get("slug") == CATCH_ALL_SLUG or p.get("catch_all") for p in patterns):
        patterns.append(dict(_FALLBACK_CATCH_ALL))

    _VOCAB_CACHE = patterns
    return patterns


def match_correction(text_lower):
    """Classify one correction against the controlled vocabulary.
    Returns the matched vocabulary pattern dict (never None).

    Pass 1: an explicit slug/alias named in the text wins outright
            (e.g. 'PATTERN RECURRENCE: act-before-research', including
            legacy slugs like 'shipping-before-verifying' kept as aliases).
    Pass 2: matchers tried pattern-by-pattern in vocabulary order — first
            match wins, so list order in the vocabulary file is semantic.
            Each matcher is a lowercase regex (substring fallback on
            re.error), searched against the lowercased correction text.
    Pass 3: the catch-all."""
    vocab = load_vocabulary()

    for p in vocab:
        if p.get("catch_all") or p.get("slug") == CATCH_ALL_SLUG:
            continue
        for alias in [p["slug"]] + list(p.get("aliases") or []):
            a = str(alias).lower()
            if a and (a in text_lower or a.replace("-", " ") in text_lower):
                return p

    for p in vocab:
        for m in p.get("matchers") or []:
            m = str(m).lower()
            if not m:
                continue
            try:
                if re.search(m, text_lower):
                    return p
            except re.error:
                if m in text_lower:
                    return p

    for p in vocab:
        if p.get("catch_all") or p.get("slug") == CATCH_ALL_SLUG:
            return p
    return dict(_FALLBACK_CATCH_ALL)  # unreachable: load_vocabulary guarantees one


def apply_correction(tracker, text, short_id, entry_date, now):
    """Record one correction in the tracker: classify it against the
    controlled vocabulary, append the occurrence (creating the canonical
    pattern entry on first sight), and run regression detection + escalation.
    'uncategorized' keeps the full correction text and never escalates."""
    text_lower = text.lower()
    vocab_pattern = match_correction(text_lower)
    slug = str(vocab_pattern.get("slug") or CATCH_ALL_SLUG)
    is_catch_all = bool(vocab_pattern.get("catch_all")) or slug == CATCH_ALL_SLUG

    patterns = tracker.setdefault("patterns", {})
    if slug not in patterns:
        patterns[slug] = {
            "description": vocab_pattern.get("definition") or text[:300],
            "occurrences": [],
            "level": "observation",
            "escalated_at": None,
            "resolved": False,
            "resolved_at": None,
            "resolution_method": None,
            "last_updated": now,
        }
    pattern = patterns[slug]

    # Preserve full text for the catch-all (needed for later manual
    # reclassification); matched patterns keep the historical 300-char context.
    context = text if is_catch_all else text[:300]
    pattern.setdefault("occurrences", []).append(
        {"entry_id": short_id, "date": entry_date, "context": context})
    pattern["last_updated"] = now
    occ_count = len(pattern["occurrences"])

    if vocab_pattern.get("escalate", True) is False:
        return

    # Regression detection: if pattern was resolved, re-escalate
    if pattern.get("resolved"):
        regression_count = sum(1 for o in pattern["occurrences"]
                               if o.get("date", "") > (pattern.get("resolved_at", "") or ""))
        if regression_count >= 2:
            pattern["resolved"] = False
            pattern["resolved_at"] = None
            pattern["level"] = "guardrail"
            pattern["escalated_at"] = now
            print(f"SCRIBE REGRESSION: Pattern '{slug}' was resolved but recurred "
                  f"{regression_count} times. Re-escalated to guardrail.", file=sys.stderr)

    # Normal escalation
    if occ_count >= 5 and pattern.get("level") != "critical":
        pattern["level"] = "critical"
        pattern["escalated_at"] = now
    elif occ_count >= 3 and pattern.get("level") == "observation":
        pattern["level"] = "guardrail"
        pattern["escalated_at"] = now

# =============================================================================
# END PATTERN MATCHING SECTION
# =============================================================================


def main():
    if len(sys.argv) != 2:
        print("usage: printf '%s' \"$ENTRY_JSON\" | track-corrections.py <tracker_path>",
              file=sys.stderr)
        return 1
    tracker_path = sys.argv[1]

    raw = sys.stdin.read()
    try:
        entry = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as e:
        print(f"track-corrections: entry JSON on stdin is invalid: {e}", file=sys.stderr)
        return 1
    if not isinstance(entry, dict):
        print("track-corrections: entry JSON must be an object", file=sys.stderr)
        return 1

    corrections = entry.get("corrections", []) or []
    if not corrections:
        return 0  # nothing to do

    try:
        with open(tracker_path) as f:
            tracker = json.load(f)
    except FileNotFoundError:
        tracker = {"schema_version": 1, "patterns": {}, "last_updated": ""}
    except (json.JSONDecodeError, ValueError) as e:
        print(f"track-corrections: tracker file is corrupt, refusing to overwrite: {e}",
              file=sys.stderr)
        return 1
    if not isinstance(tracker, dict):
        print("track-corrections: tracker file is not a JSON object, refusing to overwrite",
              file=sys.stderr)
        return 1

    entry_id = str(entry.get("id", ""))
    short_id = entry_id[:8]
    entry_date = str(entry.get("timestamp", ""))[:10]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for correction in corrections:
        text = correction if isinstance(correction, str) else json.dumps(correction)
        apply_correction(tracker, text, short_id, entry_date, now)

    tracker["last_updated"] = now

    # Atomic write: tmp file in the same directory + os.replace (rename).
    tracker_dir = os.path.dirname(os.path.abspath(tracker_path)) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=".correction-tracker.", suffix=".tmp",
                                    dir=tracker_dir)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(tracker, f, indent=2)
        os.replace(tmp_path, tracker_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
