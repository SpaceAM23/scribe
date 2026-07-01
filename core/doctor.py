#!/usr/bin/env python3
"""
doctor.py — Scribe derived-state doctor.

Regenerates ALL derived state from journal.jsonl in one pass:
  (a) rebuilds seen-hashes.txt using the exact writer.sh content-hash recipe
      (sha256 of "project|type|title|date10|summary-prefix-200", see writer.sh
      section 12c "CONTENT-HASH DEDUP");
  (b) recomputes index.json counters (totals, per-project, tag_cloud,
      growth_summary) preserving the existing schema and any extra fields;
  (c) validates every entry id is a well-formed, unique, lowercase UUID.

Modes:
  --check   report violations only; exit 1 if any found (default mode)
  --fix     repair what can be repaired (atomic writes), then report;
            exit 0 only if everything is clean afterwards

Safety:
  * Stdlib only. Bash not involved.
  * Data dir resolution: --data-dir > $SCRIBE_DATA_PATH > pointer.json >
    default (~/Desktop/Scribe) — the same order writer.sh uses.
  * The journal is LIVE: every rewrite goes to a tmp file in the same
    directory, the live file is re-checked for concurrent modification
    immediately before os.replace(); on any drift the run aborts (exit 2)
    without touching anything.
  * Journal rewrites verify the new line count equals the original count
    plus the intended delta before replacing.
  * Any id repair is recorded in DATA_DIR/doctor-repairs-<date>.json
    (old id, new id, action, reason) — never silently.

Exit codes: 0 clean, 1 violations found (check) or remain (fix), 2 aborted.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
import uuid
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INSTALL_ROOT = os.path.dirname(SCRIPT_DIR)  # repo root (this file lives in core/)


def default_data_dir():
    """$SCRIBE_DATA_PATH > pointer.json (repo root, then core/) > ~/Desktop/Scribe.
    Mirrors writer.sh resolve_data_path()."""
    env = os.environ.get('SCRIBE_DATA_PATH')
    if env:
        return env
    for pointer in (os.path.join(INSTALL_ROOT, 'pointer.json'),
                    os.path.join(SCRIPT_DIR, 'pointer.json')):
        try:
            with open(pointer, 'r', encoding='utf-8') as f:
                ptr = json.load(f)
            p = ptr.get('data_path')
            if isinstance(p, str) and p:
                return p
        except Exception:
            continue
    return '~/Desktop/Scribe'


UUID_RE = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
UUID_RE_ANYCASE = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')

INDEX_SKELETON = {
    "total_entries": 0,
    "projects": {},
    "tag_cloud": {},
    "growth_summary": {
        "total_features": 0,
        "total_bugs_fixed": 0,
        "total_learnings": 0,
        "total_corrections": 0,
        "skill_distribution": {},
    },
    "last_updated": None,
}


# ---------------------------------------------------------------------------
# Hash recipe — must match writer.sh section 12c exactly.
#
# writer.sh builds:
#   ENTRY_DATE=$(echo "$TIMESTAMP" | cut -c1-10)
#   SUMMARY_PREFIX=$(echo "$ENTRY" | jq -r '.summary // empty' | cut -c1-200)
#   HASH_INPUT="${PROJECT}|${TYPE}|${TITLE}|${ENTRY_DATE}|${SUMMARY_PREFIX}"
#   printf '%s' "$HASH_INPUT" | shasum -a 256 | cut -c1-64
#
# Semantics replicated here:
#   * jq -r prints strings raw; null prints "null" (for .project/.type/.title);
#     '.summary // empty' prints nothing for null/false.
#   * cut -c1-200 truncates EACH LINE to 200 characters (multibyte-aware
#     under a UTF-8 locale). writer.sh pins LC_ALL to a UTF-8 locale so
#     cron/launchd runs (LC_ALL=C default) can't fall back to a 200-BYTE
#     truncation that would diverge from the 200-character slice below.
#   * $( ... ) command substitution strips all trailing newlines.
#   * PROJECT/TYPE/TITLE/TIMESTAMP are the post-normalization values, which
#     are exactly what is stored in the journal entry.
# ---------------------------------------------------------------------------

def _jq_r(v):
    """Mimic `jq -r` output for a scalar path like .title."""
    if v is None:
        return "null"
    if isinstance(v, str):
        return v
    return json.dumps(v, ensure_ascii=False, separators=(',', ':'))


def _summary_prefix(s):
    """Mimic `jq -r '.summary // empty' | cut -c1-200` inside $(...)."""
    if s is None or s is False:
        return ""
    raw = s if isinstance(s, str) else json.dumps(s, ensure_ascii=False, separators=(',', ':'))
    cut = '\n'.join(line[:200] for line in raw.split('\n'))
    return cut.rstrip('\n')


def entry_hash(entry):
    project = _jq_r(entry.get('project')).rstrip('\n')
    etype = _jq_r(entry.get('type')).rstrip('\n')
    title = _jq_r(entry.get('title')).rstrip('\n')
    ts = _jq_r(entry.get('timestamp')).rstrip('\n')
    date10 = ts[:10]
    prefix = _summary_prefix(entry.get('summary'))
    hash_input = "%s|%s|%s|%s|%s" % (project, etype, title, date10, prefix)
    return hashlib.sha256(hash_input.encode('utf-8')).hexdigest()


# ---------------------------------------------------------------------------
# Index recompute — replays writer.sh section 16 over every journal entry.
# ---------------------------------------------------------------------------

def recompute_index(entries, existing):
    """Return a new index dict: counters rebuilt, everything else preserved."""
    new = json.loads(json.dumps(existing)) if existing else json.loads(json.dumps(INDEX_SKELETON))
    # Ensure counter containers exist
    for key, val in INDEX_SKELETON.items():
        if key not in new:
            new[key] = json.loads(json.dumps(val))
    gs = new.setdefault('growth_summary', {})
    for key in ("total_features", "total_bugs_fixed", "total_learnings", "total_corrections"):
        gs.setdefault(key, 0)
    gs.setdefault('skill_distribution', {})

    new['total_entries'] = len(entries)

    # projects: rebuild entries/last_session, preserve extra per-project keys
    # (e.g. current_version). Projects with no journal entries are removed
    # (they are stale derived state) — the caller reports them.
    counts = {}
    last_session = {}
    tag_cloud = {}
    features = bugs = learnings = corrections = 0
    skills = {}

    for e in entries:
        proj = _jq_r(e.get('project'))
        counts[proj] = counts.get(proj, 0) + 1
        ts = _jq_r(e.get('timestamp'))
        last_session[proj] = ts[:10]

        conns = e.get('connections')
        if isinstance(conns, dict):
            tags = conns.get('tags')
            if isinstance(tags, list):
                for tag in tags:
                    if not isinstance(tag, str) or tag == "":
                        continue
                    tag_cloud[tag] = tag_cloud.get(tag, 0) + 1

        etype = e.get('type')
        if etype == 'feature_shipped':
            features += 1
        elif etype == 'bug_fixed':
            bugs += 1
        elif etype == 'learning':
            learnings += 1

        corr = e.get('corrections')
        if isinstance(corr, list):
            corrections += len(corr)

        growth = e.get('growth')
        if isinstance(growth, dict):
            skill = growth.get('skill_area')
            if isinstance(skill, str) and skill:
                skills[skill] = skills.get(skill, 0) + 1

    old_projects = new.get('projects') or {}
    projects = {}
    for proj in counts:
        obj = dict(old_projects.get(proj) or {})
        obj['entries'] = counts[proj]
        obj['last_session'] = last_session[proj]
        projects[proj] = obj
    new['projects'] = projects

    new['tag_cloud'] = tag_cloud
    gs['total_features'] = features
    gs['total_bugs_fixed'] = bugs
    gs['total_learnings'] = learnings
    gs['total_corrections'] = corrections
    gs['skill_distribution'] = skills
    return new


def index_drift(old, new):
    """List human-readable differences between counter fields of old and new."""
    drifts = []
    if (old or {}).get('total_entries') != new['total_entries']:
        drifts.append("total_entries: %r -> %r" % ((old or {}).get('total_entries'), new['total_entries']))
    old_projects = (old or {}).get('projects') or {}
    for proj in sorted(set(list(old_projects) + list(new['projects']))):
        o, n = old_projects.get(proj), new['projects'].get(proj)
        if n is None:
            drifts.append("projects.%s: stale (no journal entries) -> removed" % proj)
        elif o is None:
            drifts.append("projects.%s: missing -> entries=%d" % (proj, n['entries']))
        else:
            if o.get('entries') != n['entries']:
                drifts.append("projects.%s.entries: %r -> %r" % (proj, o.get('entries'), n['entries']))
            if o.get('last_session') != n['last_session']:
                drifts.append("projects.%s.last_session: %r -> %r" % (proj, o.get('last_session'), n['last_session']))
    if ((old or {}).get('tag_cloud') or {}) != new['tag_cloud']:
        o_tags = (old or {}).get('tag_cloud') or {}
        changed = [t for t in set(list(o_tags) + list(new['tag_cloud'])) if o_tags.get(t) != new['tag_cloud'].get(t)]
        drifts.append("tag_cloud: %d tag count(s) differ" % len(changed))
    ogs = (old or {}).get('growth_summary') or {}
    for key in ("total_features", "total_bugs_fixed", "total_learnings", "total_corrections"):
        if ogs.get(key) != new['growth_summary'][key]:
            drifts.append("growth_summary.%s: %r -> %r" % (key, ogs.get(key), new['growth_summary'][key]))
    if (ogs.get('skill_distribution') or {}) != new['growth_summary']['skill_distribution']:
        drifts.append("growth_summary.skill_distribution: differs")
    return drifts


# ---------------------------------------------------------------------------
# Atomic write with live-journal guard
# ---------------------------------------------------------------------------

def journal_fingerprint(path):
    try:
        with open(path, 'rb') as f:
            data = f.read()
        return (len(data), data.count(b'\n'))
    except FileNotFoundError:
        return None


def atomic_replace(target_path, content, journal_path, journal_fp):
    """Write content to tmp, verify the live journal has not moved, replace."""
    tmp = "%s.doctor-tmp.%d" % (target_path, os.getpid())
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    if journal_fingerprint(journal_path) != journal_fp:
        os.unlink(tmp)
        raise ConcurrentModification(
            "journal.jsonl changed while doctor was running — aborting before "
            "replacing %s; re-run doctor." % os.path.basename(target_path))
    os.replace(tmp, target_path)


class ConcurrentModification(Exception):
    pass


# ---------------------------------------------------------------------------
# Writer lock (hardening b) — the SAME mkdir lock writer.sh uses.
#
# --fix rewrites the live journal; doing that while a writer.sh append is in
# flight can drop the append (the fingerprint guard narrows but does not close
# the window). Mirrors writer.sh semantics exactly: mkdir to acquire, pid file
# for ownership, stale locks (dead holder pid, or pid-less dir older than 60s)
# stolen by ATOMIC rename-aside, ownership re-verified before release.
# On timeout (~15s) the fix is ABORTED — never proceed unlocked.
# ---------------------------------------------------------------------------

LOCK_STALE_SECS = 60
LOCK_TIMEOUT_SECS = 15.0


def _steal_stale_lock(lock_dir):
    """Steal only if provably stale; atomic rename-aside so one stealer wins."""
    pid = None
    try:
        with open(os.path.join(lock_dir, 'pid'), 'r') as f:
            pid = int(f.read().strip() or '0') or None
    except (OSError, ValueError):
        pid = None
    stale = False
    if pid is not None:
        try:
            os.kill(pid, 0)          # signal 0: existence probe only
        except ProcessLookupError:
            stale = True             # holder is dead
        except OSError:
            pass                     # alive (or EPERM) — not ours to steal
    else:
        try:
            if time.time() - os.stat(lock_dir).st_mtime > LOCK_STALE_SECS:
                stale = True         # pid-less and old — crashed mid-acquire
        except OSError:
            pass
    if not stale:
        return
    graveyard = "%s.stale.%d.%d" % (lock_dir, os.getpid(), int(time.time()))
    try:
        os.rename(lock_dir, graveyard)
    except OSError:
        return                       # someone else won the steal — retry mkdir
    shutil.rmtree(graveyard, ignore_errors=True)


def acquire_writer_lock(data_dir, timeout=LOCK_TIMEOUT_SECS):
    """Return True with .writer.lock held, False on timeout (caller aborts)."""
    lock_dir = os.path.join(data_dir, '.writer.lock')
    deadline = time.time() + timeout
    while True:
        try:
            os.mkdir(lock_dir)
        except FileExistsError:
            _steal_stale_lock(lock_dir)
            if time.time() >= deadline:
                return False
            time.sleep(0.2)
            continue
        except OSError:
            return False
        try:
            with open(os.path.join(lock_dir, 'pid'), 'w') as f:
                f.write(str(os.getpid()))
        except OSError:
            pass
        return True


def release_writer_lock(data_dir):
    """Remove the lock only if this process still owns it."""
    lock_dir = os.path.join(data_dir, '.writer.lock')
    try:
        with open(os.path.join(lock_dir, 'pid'), 'r') as f:
            owner = f.read().strip()
    except OSError:
        owner = ''
    if owner == str(os.getpid()):
        shutil.rmtree(lock_dir, ignore_errors=True)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def main():
    ap = argparse.ArgumentParser(description="Regenerate Scribe derived state from journal.jsonl")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true', help="report only; exit 1 on violations (default)")
    mode.add_argument('--fix', action='store_true', help="repair violations atomically")
    ap.add_argument('--data-dir', default=default_data_dir(),
                    help="Scribe data dir (default: $SCRIBE_DATA_PATH > pointer.json > ~/Desktop/Scribe)")
    args = ap.parse_args()
    fix = bool(args.fix)

    data_dir = os.path.abspath(os.path.expanduser(args.data_dir))
    journal_path = os.path.join(data_dir, 'journal.jsonl')
    hashes_path = os.path.join(data_dir, 'seen-hashes.txt')
    index_path = os.path.join(data_dir, 'index.json')
    scripts_dir = data_dir  # repair logs live in the data dir root
    repair_log_path = os.path.join(
        scripts_dir, 'doctor-repairs-%s.json' % datetime.now(timezone.utc).strftime('%Y-%m-%d'))

    if not os.path.isfile(journal_path):
        print("doctor: no journal at %s" % journal_path, file=sys.stderr)
        return 2

    # Hardening (b): --fix mutates the live journal/derived state — take the
    # same .writer.lock writer.sh holds around its critical section. If a
    # writer is active and the lock cannot be acquired in ~15s, ABORT the fix
    # (exit 2); never rewrite the journal unlocked. --check stays lock-free.
    lock_held = False
    if fix:
        if not acquire_writer_lock(data_dir):
            print("doctor: ABORT — could not acquire %s within ~15s (a writer "
                  "is active). --fix not applied; re-run when the writer "
                  "finishes." % os.path.join(data_dir, '.writer.lock'),
                  file=sys.stderr)
            return 2
        lock_held = True
    try:
        return _run(fix, data_dir, journal_path, hashes_path, index_path,
                    scripts_dir, repair_log_path)
    finally:
        if lock_held:
            release_writer_lock(data_dir)


def _run(fix, data_dir, journal_path, hashes_path, index_path, scripts_dir,
         repair_log_path):
    journal_fp = journal_fingerprint(journal_path)
    with open(journal_path, 'r', encoding='utf-8') as f:
        raw_lines = f.read().split('\n')
    if raw_lines and raw_lines[-1] == '':
        raw_lines.pop()  # trailing newline
    original_count = len(raw_lines)

    violations = []          # strings describing every violation found
    unfixable = []           # violations --fix cannot repair
    repairs = []             # {old_id,new_id,action,reason,line,title}
    entries = []             # (line_no, entry_dict or None, raw_line)
    seen_ids = {}            # lowercase id -> first line_no
    journal_dirty = False
    blank_removed = 0

    for line_no, raw in enumerate(raw_lines, 1):
        if raw.strip() == '':
            violations.append("line %d: blank line in journal" % line_no)
            blank_removed += 1
            journal_dirty = True
            continue
        try:
            entry = json.loads(raw)
        except ValueError as exc:
            violations.append("line %d: unparseable JSON (%s)" % (line_no, exc))
            unfixable.append("line %d: unparseable JSON" % line_no)
            entries.append((line_no, None, raw))
            continue

        eid = entry.get('id')
        title = str(entry.get('title', ''))[:60]

        def re_id(reason, action):
            new_id = str(uuid.uuid4())
            while new_id in seen_ids:            # paranoia
                new_id = str(uuid.uuid4())
            repairs.append({
                "line": line_no, "old_id": eid, "new_id": new_id,
                "action": action, "reason": reason, "title": title,
            })
            entry['id'] = new_id
            return new_id

        if not isinstance(eid, str) or not UUID_RE_ANYCASE.match(eid):
            violations.append("line %d: malformed id %r (%s)" % (line_no, eid, title))
            if fix:
                eid = re_id("malformed id (not a UUID)", "minted_new_uuid")
                journal_dirty = True
        elif not UUID_RE.match(eid):
            violations.append("line %d: uppercase UUID %s (%s)" % (line_no, eid, title))
            if fix:
                lowered = eid.lower()
                if lowered in seen_ids:
                    eid = re_id("uppercase UUID; lowercase form collides with line %d"
                                % seen_ids[lowered], "minted_new_uuid")
                else:
                    repairs.append({
                        "line": line_no, "old_id": eid, "new_id": lowered,
                        "action": "lowercased", "reason": "uppercase UUID", "title": title,
                    })
                    entry['id'] = lowered
                    eid = lowered
                journal_dirty = True

        key = eid.lower() if isinstance(eid, str) else repr(eid)
        if key in seen_ids:
            violations.append("line %d: duplicate id %s (first seen line %d) (%s)"
                              % (line_no, eid, seen_ids[key], title))
            if fix:
                eid = re_id("duplicate id (first occurrence kept at line %d)"
                            % seen_ids[key], "minted_new_uuid")
                journal_dirty = True
                seen_ids[eid] = line_no
            # in check mode the duplicate stays; do not overwrite first-seen
        else:
            seen_ids[key] = line_no

        entries.append((line_no, entry, raw))

    parsed = [e for _, e, _ in entries if e is not None]

    # ---- seen-hashes.txt --------------------------------------------------
    expected_hashes, hset = [], set()
    for e in parsed:
        h = entry_hash(e)
        if h not in hset:
            hset.add(h)
            expected_hashes.append(h)
    try:
        with open(hashes_path, 'r', encoding='utf-8') as f:
            current_hashes = [l.strip() for l in f if l.strip()]
    except FileNotFoundError:
        current_hashes = []
    cur_set = set(current_hashes)
    missing_hashes = [h for h in expected_hashes if h not in cur_set]
    stale_hashes = [h for h in current_hashes if h not in hset]
    if missing_hashes or stale_hashes:
        violations.append("seen-hashes.txt: %d entry hash(es) missing, %d stale hash(es) "
                          "not derivable from the journal" % (len(missing_hashes), len(stale_hashes)))

    # ---- index.json -------------------------------------------------------
    try:
        with open(index_path, 'r', encoding='utf-8') as f:
            current_index = json.load(f)
    except (FileNotFoundError, ValueError):
        current_index = None
    new_index = recompute_index(parsed, current_index)
    drifts = index_drift(current_index, new_index)
    for d in drifts:
        violations.append("index.json: %s" % d)

    # ---- report: before ---------------------------------------------------
    print("=" * 72)
    print("SCRIBE DOCTOR — %s — mode: %s" % (data_dir, "FIX" if fix else "CHECK"))
    print("=" * 72)
    print("journal entries:        %d (%d line(s) unparseable, %d blank)"
          % (len(parsed), len(unfixable), blank_removed))
    id_viol = [v for v in violations if ': malformed id' in v or ': duplicate id' in v
               or ': uppercase UUID' in v]
    print("id violations:          %d" % len(id_viol))
    for v in id_viol:
        print("    - %s" % v)
    print("seen-hashes.txt:        %d line(s) now; %d expected (%d missing, %d stale)"
          % (len(current_hashes), len(expected_hashes), len(missing_hashes), len(stale_hashes)))
    print("index.json drift:       %d field(s)" % len(drifts))
    for d in drifts:
        print("    - %s" % d)

    if not fix:
        print("-" * 72)
        if violations:
            print("CHECK FAILED: %d violation(s). Run with --fix to repair." % len(violations))
            return 1
        print("CHECK PASSED: derived state is consistent with the journal.")
        return 0

    # ---- fix --------------------------------------------------------------
    try:
        if journal_dirty:
            repaired_lines = set(r['line'] for r in repairs)
            new_lines = []
            for line_no, entry, raw in entries:
                if entry is None or line_no not in repaired_lines:
                    new_lines.append(raw)  # untouched lines stay byte-identical
                else:
                    # jq -c compact style, matching how writer.sh emits lines
                    new_lines.append(json.dumps(entry, ensure_ascii=False, separators=(',', ':')))
            expected_count = original_count - blank_removed
            if len(new_lines) != expected_count:
                print("doctor: ABORT — rewrite would produce %d lines, expected %d"
                      % (len(new_lines), expected_count), file=sys.stderr)
                return 2
            atomic_replace(journal_path, '\n'.join(new_lines) + '\n', journal_path, journal_fp)
            journal_fp = journal_fingerprint(journal_path)
            # recompute hashes: re-idding does not change content hashes, but stay exact
            print("journal.jsonl:          rewritten (%d lines, %d id repair(s), %d blank line(s) removed)"
                  % (len(new_lines), len(repairs), blank_removed))
            if repairs:
                log = {"generated": now_iso(), "tool": "doctor.py", "repairs": []}
                if os.path.isfile(repair_log_path):
                    try:
                        with open(repair_log_path, 'r', encoding='utf-8') as f:
                            log = json.load(f)
                        log.setdefault('repairs', [])
                    except ValueError:
                        pass
                log['repairs'].extend(repairs)
                log['generated'] = now_iso()
                os.makedirs(scripts_dir, exist_ok=True)
                atomic_replace(repair_log_path, json.dumps(log, indent=2, ensure_ascii=False) + '\n',
                               journal_path, journal_fp)
                print("repair log:             %s (+%d)" % (repair_log_path, len(repairs)))

        if missing_hashes or stale_hashes or not os.path.isfile(hashes_path):
            atomic_replace(hashes_path, '\n'.join(expected_hashes) + ('\n' if expected_hashes else ''),
                           journal_path, journal_fp)
            print("seen-hashes.txt:        rebuilt -> %d hash(es)" % len(expected_hashes))
        else:
            print("seen-hashes.txt:        already consistent")

        if drifts or current_index is None:
            new_index['last_updated'] = now_iso()
            atomic_replace(index_path, json.dumps(new_index, indent=2, ensure_ascii=False) + '\n',
                           journal_path, journal_fp)
            print("index.json:             recomputed (%d field(s) corrected)" % len(drifts))
        else:
            print("index.json:             already consistent")
    except ConcurrentModification as exc:
        print("doctor: ABORT — %s" % exc, file=sys.stderr)
        return 2

    print("-" * 72)
    if unfixable:
        print("FIX INCOMPLETE: %d violation(s) could not be repaired automatically:" % len(unfixable))
        for u in unfixable:
            print("    - %s" % u)
        return 1
    print("FIX COMPLETE: %d violation(s) repaired. Re-run --check to verify." % len(violations))
    return 0


if __name__ == '__main__':
    sys.exit(main())
