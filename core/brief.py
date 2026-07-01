#!/usr/bin/env python3
"""
brief.py — compile per-project session briefs from the Scribe journal.

THE read path: agents read briefs/<project>.md at session start instead of
grepping the raw journal. Each brief is HARD-CAPPED at 60 lines and contains:

  1. Header        — generated <newest-journal-timestamp> from <N> entries
                     (timestamp comes from the journal, NOT wall clock, so
                     output is deterministic for a given journal state)
  2. LANDMINES     — this project's correction patterns (lifetime + 30-day
                     counts + most-recent example), sorted by 30-day count
  3. KNOWLEDGE     — NEXUS nodes mentioning the project (salience >= 4 first)
  4. RECENT        — last 3 session summaries (reflection/milestone/feature_shipped)
  5. OPEN THREADS  — project-relevant lines from handoff.md
  6. META BUDGET   — rolling-30-day meta+scribe share (WARNING if > 15%)

Also writes briefs/_portfolio.md: one line per project + meta budget +
doctor --check status.

Usage:
  python3 brief.py                    # regenerate all briefs + _portfolio.md
  python3 brief.py --project my-app   # regenerate one brief + _portfolio.md

Design constraints (do not break):
  * stdlib only, fast (<2s), idempotent (atomic tmp+rename, skip-if-unchanged).
  * Data dir resolution: --data-dir > $SCRIBE_DATA_PATH > pointer.json >
    default (~/Desktop/Scribe) — the same order writer.sh uses.
  * NEVER crashes on missing/corrupt inputs — this runs as a non-fatal
    post-write hook inside writer.sh. Missing data degrades to
    "none recorded" and the script exits 0.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile

HARD_CAP = 60          # max lines per brief file
MAX_LANDMINES = 6
MAX_KNOWLEDGE = 8
MAX_RECENT = 3
MAX_THREADS = 5
MAX_SUGGESTIONS = 5
META_WARN_PCT = 15.0
ROLLING_DAYS = 30
RECENT_TYPES = ("reflection", "milestone", "feature_shipped")
META_PROJECTS = ("meta", "scribe")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
INSTALL_ROOT = os.path.dirname(SCRIPT_DIR)  # repo root (this file lives in core/)


def warn(msg):
    sys.stderr.write("brief.py: %s\n" % msg)


def resolve_data_dir(cli_value):
    """--data-dir > $SCRIBE_DATA_PATH > pointer.json > ~/Desktop/Scribe."""
    if cli_value:
        return os.path.abspath(os.path.expanduser(cli_value))
    env = os.environ.get("SCRIBE_DATA_PATH")
    if env:
        return os.path.abspath(os.path.expanduser(env))
    for pointer in (
        os.path.join(INSTALL_ROOT, "pointer.json"),
        os.path.join(SCRIPT_DIR, "pointer.json"),
    ):
        try:
            with open(pointer, "r", encoding="utf-8") as f:
                ptr = json.load(f)
            p = ptr.get("data_path")
            if isinstance(p, str) and p:
                return os.path.abspath(os.path.expanduser(p))
        except Exception:
            continue
    return os.path.expanduser("~/Desktop/Scribe")


def load_json(path):
    """Return parsed JSON or None. Never raises."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def load_journal(path):
    """Return list of entry dicts; skips unparseable lines. Never raises."""
    entries = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if isinstance(e, dict):
                    entries.append(e)
    except Exception:
        pass
    return entries


TS_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})")


def parse_ts(value):
    """ISO-8601 string -> naive UTC datetime, or None. Never raises."""
    if not isinstance(value, str):
        return None
    s = value.strip()
    try:
        dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is not None:
            dt = dt.astimezone(datetime.timezone.utc).replace(tzinfo=None)
        return dt
    except Exception:
        pass
    m = TS_RE.match(s)
    if m:
        try:
            return datetime.datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except Exception:
            return None
    return None


def one_line(text, limit):
    """Collapse whitespace and truncate to limit chars."""
    s = re.sub(r"\s+", " ", str(text or "")).strip()
    if len(s) > limit:
        s = s[: limit - 1].rstrip() + "…"
    return s


def build_project_terms(projects_cfg, journal_entries, forced_project):
    """canonical project -> set of match terms (slug + aliases)."""
    projects = []
    aliases = {}
    if isinstance(projects_cfg, dict):
        projects = [p for p in projects_cfg.get("projects", []) if isinstance(p, str)]
        raw_aliases = projects_cfg.get("aliases", {})
        if isinstance(raw_aliases, dict):
            aliases = raw_aliases
    if not projects:
        # Degraded mode (scratch dirs): derive projects from the journal.
        seen = []
        for e in journal_entries:
            p = e.get("project")
            if isinstance(p, str) and p and p not in seen:
                seen.append(p)
        projects = sorted(seen)
    if forced_project and forced_project not in projects:
        projects = projects + [forced_project]
    terms = {}
    for p in projects:
        terms[p] = {p}
    for alias, canon in aliases.items():
        if isinstance(alias, str) and canon in terms:
            terms[canon].add(alias)
    return projects, terms


def compile_matchers(terms):
    """
    project -> (negatives_regex_or_None, match_regex).
    Negatives: terms of OTHER projects that contain one of this project's
    terms as a substring (e.g. 'my-app-mobile' vs project 'my-app', 'acme-wms'
    vs 'acme'). They are stripped from text before matching so a mention of
    'my-app-mobile' does not land in the my-app brief.
    """
    matchers = {}
    lowered = {p: {t.lower() for t in ts} for p, ts in terms.items()}
    for p, ts in terms.items():
        own = lowered[p]
        negatives = set()
        for other, other_ts in terms.items():
            if other == p:
                continue
            for ot in other_ts:
                ol = ot.lower()
                if ol in own:
                    continue
                if any(t in ol for t in own):
                    negatives.add(ot)
        neg_re = None
        if negatives:
            neg_re = re.compile(
                "|".join(re.escape(n) for n in sorted(negatives, key=len, reverse=True)),
                re.IGNORECASE,
            )
        pos_re = re.compile(
            r"\b(?:" + "|".join(re.escape(t) for t in sorted(ts, key=len, reverse=True)) + r")\b",
            re.IGNORECASE,
        )
        matchers[p] = (neg_re, pos_re)
    return matchers


def text_mentions(project, text, matchers):
    neg_re, pos_re = matchers[project]
    if neg_re is not None:
        text = neg_re.sub(" ", text)
    return bool(pos_re.search(text))


def occurrence_project(occ, id_to_project):
    """
    Resolve a tracker occurrence (8-char entry_id prefix) to a project.
    Journal id prefixes can collide (legacy doc-example ids); when they do,
    prefer the journal entry whose date matches the occurrence date, else
    the oldest candidate. Deterministic per journal state.
    """
    candidates = id_to_project.get(str(occ.get("entry_id", ""))[:8])
    if not candidates:
        return None
    if len(candidates) == 1:
        return candidates[0][1]
    occ_date = str(occ.get("date", ""))[:10]
    for date, proj in candidates:
        if date == occ_date:
            return proj
    return candidates[0][1]


def landmines_for(project, tracker, id_to_project, window_start_date):
    """[(pattern, lifetime, last30, example_context)] sorted by 30d desc."""
    if not isinstance(tracker, dict):
        return []
    patterns = tracker.get("patterns")
    if not isinstance(patterns, dict):
        return []
    rows = []
    for name, pdata in patterns.items():
        if not isinstance(pdata, dict):
            continue
        occs = pdata.get("occurrences")
        if not isinstance(occs, list):
            continue
        mine = []
        for o in occs:
            if not isinstance(o, dict):
                continue
            if occurrence_project(o, id_to_project) == project:
                mine.append(o)
        if not mine:
            continue
        lifetime = len(mine)
        last30 = 0
        for o in mine:
            m = TS_RE.match(str(o.get("date", "")))
            if m and window_start_date is not None and m.group(0) >= window_start_date:
                last30 += 1
        # most recent example: occurrences are appended chronologically;
        # sort by date string as a stable tie-break, keep the last.
        example = sorted(mine, key=lambda o: str(o.get("date", "")))[-1]
        rows.append((name, lifetime, last30, str(example.get("context", ""))))
    rows.sort(key=lambda r: (-r[2], -r[1], r[0]))
    return rows[:MAX_LANDMINES]


def knowledge_for(project, nexus, matchers):
    """[(key, content)] — active nodes mentioning the project, salience>=4 first."""
    if not isinstance(nexus, dict):
        return []
    nodes = nexus.get("nodes")
    if not isinstance(nodes, list):
        return []
    hits = []
    for node in nodes:
        if not isinstance(node, dict):
            continue
        if node.get("status", "active") != "active":
            continue
        text = " ".join(
            str(node.get(k) or "") for k in ("domain", "key", "content")
        )
        if not text_mentions(project, text, matchers):
            continue
        try:
            sal = int(node.get("salience") or 0)
        except Exception:
            sal = 0
        hits.append((sal, str(node.get("key") or "?"), str(node.get("content") or "")))
    # salience >= 4 first, then by salience desc; key as deterministic tie-break
    hits.sort(key=lambda h: (0 if h[0] >= 4 else 1, -h[0], h[1]))
    return [(k, c) for _, k, c in hits[:MAX_KNOWLEDGE]]


def recent_for(project, entries_sorted):
    """[(date, title)] — newest reflection/milestone/feature_shipped, max 3."""
    out = []
    for e, dt in entries_sorted:  # entries_sorted is newest-first
        if e.get("project") != project or e.get("type") not in RECENT_TYPES:
            continue
        date = dt.strftime("%Y-%m-%d") if dt else str(e.get("timestamp", "?"))[:10]
        out.append((date, str(e.get("title") or e.get("summary") or "?")))
        if len(out) >= MAX_RECENT:
            break
    return out


def threads_for(project, handoff_lines, matchers):
    out = []
    in_fence = False
    for line in handoff_lines:
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or not stripped or set(stripped) <= {"#", "-", "=", "`", "*"}:
            continue
        if text_mentions(project, stripped, matchers):
            out.append(stripped.lstrip("#-* ").strip())
        if len(out) >= MAX_THREADS:
            break
    return out


def meta_budget_line(entries_with_dt, window_start):
    if window_start is None:
        return "meta budget: no dated journal entries — share not computable"
    recent = [e for e, dt in entries_with_dt if dt is not None and dt >= window_start]
    total = len(recent)
    if total == 0:
        return "meta budget: 0 entries in the last %dd — share not computable" % ROLLING_DAYS
    meta_n = sum(1 for e in recent if e.get("project") in META_PROJECTS)
    pct = 100.0 * meta_n / total
    status = "WARNING >%g%%" % META_WARN_PCT if pct > META_WARN_PCT else "OK"
    return "meta budget: meta+scribe = %d/%d last-%dd entries (%.1f%%) — %s" % (
        meta_n, total, ROLLING_DAYS, pct, status
    )


def atomic_write(path, content):
    """tmp + rename in the destination dir; skip write if content unchanged."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            if f.read() == content:
                try:
                    os.chmod(path, 0o644)
                except Exception:
                    pass
                return False
    except Exception:
        pass
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".brief-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp, 0o644)  # mkstemp defaults to 0600; briefs are meant to be read
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise
    return True


def cap_lines(lines):
    if len(lines) <= HARD_CAP:
        return lines
    return lines[: HARD_CAP - 1] + ["(truncated at %d-line cap)" % HARD_CAP]


def render_brief(project, ctx):
    lines = []
    proj_entries = [e for e, _ in ctx["entries_with_dt"] if e.get("project") == project]
    lines.append("# %s — session brief" % project)
    lines.append(
        "generated %s from %d journal entries (%d tagged %s)"
        % (ctx["generated"], len(ctx["entries_with_dt"]), len(proj_entries), project)
    )
    lines.append("")
    lines.append("## LANDMINES — correction patterns to not repeat")
    mines = landmines_for(project, ctx["tracker"], ctx["id_to_project"], ctx["window_start_date"])
    if mines:
        for name, lifetime, last30, example in mines:
            lines.append(
                "- %s — %d lifetime, %d in last %dd — e.g. \"%s\""
                % (one_line(name, 60), lifetime, last30, ROLLING_DAYS, one_line(example, 90))
            )
    else:
        lines.append("- none recorded")
    lines.append("")
    lines.append("## KNOWLEDGE — NEXUS nodes for this project")
    nodes = knowledge_for(project, ctx["nexus"], ctx["matchers"])
    if nodes:
        for key, content in nodes:
            lines.append("- %s: %s" % (one_line(key, 60), one_line(content, 100)))
    else:
        lines.append("- none recorded")
    lines.append("")
    lines.append("## RECENT — last session summaries")
    recents = recent_for(project, ctx["entries_with_dt"])
    if recents:
        for date, title in recents:
            lines.append("- %s: %s" % (date, one_line(title, 140)))
    else:
        lines.append("- none recorded")
    lines.append("")
    lines.append("## OPEN THREADS — from handoff.md")
    threads = threads_for(project, ctx["handoff_lines"], ctx["matchers"])
    if threads:
        for t in threads:
            lines.append("- %s" % one_line(t, 140))
    else:
        lines.append("- none recorded")
    lines.append("")
    lines.append(ctx["meta_line"])
    return "\n".join(cap_lines(lines)) + "\n"


def taxonomy_suggestion_lines(data_dir, projects_cfg):
    """
    Render pending taxonomy-suggestion lines for _portfolio.md, or [].

    canonical/taxonomy-suggestions.jsonl is appended by writer.sh whenever an
    unknown project/type gets normalized away. A value counts as UNRESOLVED
    only while it is still unknown to the canon (projects.json / schema.json
    type enum) — minting via scripts/taxonomy.py clears it from the brief even
    before `taxonomy.py resolve` moves the queue lines aside. Graceful when
    the file is absent/corrupt: returns []. Never raises.
    """
    try:
        path = os.path.join(data_dir, "canonical", "taxonomy-suggestions.jsonl")
        counts = {}
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue
                kind = obj.get("kind")
                value = obj.get("value")
                if kind not in ("project", "type") or not isinstance(value, str) or not value:
                    continue
                counts[(kind, value)] = counts.get((kind, value), 0) + 1
        if not counts:
            return []

        known_projects = set()
        if isinstance(projects_cfg, dict):
            known_projects.update(
                p for p in projects_cfg.get("projects", []) if isinstance(p, str)
            )
            aliases = projects_cfg.get("aliases", {})
            if isinstance(aliases, dict):
                known_projects.update(a for a in aliases if isinstance(a, str))
        schema = load_json(os.path.join(data_dir, "schema.json"))
        known_types = set()
        try:
            known_types.update(
                t for t in schema["properties"]["type"]["enum"] if isinstance(t, str)
            )
        except Exception:
            pass

        taxonomy = os.path.join(SCRIPT_DIR, "taxonomy.py")
        rows = []
        for (kind, value), n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
            if kind == "project" and value in known_projects:
                continue
            if kind == "type" and value in known_types:
                continue
            # Brief lines must stay single-line and copy-paste safe. Values
            # taxonomy.py would reject (non-kebab project / non-snake type)
            # get pointed at `taxonomy.py suggestions` instead of an unusable
            # mint command.
            if kind == "project" and re.match(r"^[a-z0-9]+(-[a-z0-9]+)*$", value):
                mint = "mint: python3 %s add-project %s" % (taxonomy, value)
            elif kind == "type" and re.match(r"^[a-z][a-z0-9_]*$", value):
                mint = "mint: python3 %s add-type %s --purpose \"...\"" % (taxonomy, value)
            else:
                mint = "triage: python3 %s suggestions" % taxonomy
            rows.append(
                "- seen %dx: unknown %s '%s' — %s"
                % (n, kind, one_line(value, 60), mint)
            )
        if len(rows) > MAX_SUGGESTIONS:
            hidden = len(rows) - MAX_SUGGESTIONS
            rows = rows[:MAX_SUGGESTIONS] + [
                "- (and %d more — run: python3 %s suggestions)" % (hidden, taxonomy)
            ]
        return rows
    except Exception:
        return []


def doctor_status(data_dir):
    doctor = os.path.join(SCRIPT_DIR, "doctor.py")
    if not os.path.isfile(doctor):
        return "doctor --check: not available (doctor.py not found)"
    try:
        env = dict(os.environ)
        env["SCRIBE_DATA_PATH"] = data_dir
        r = subprocess.run(
            [sys.executable, doctor, "--check"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=30,
        )
        if r.returncode == 0:
            return "doctor --check: OK (exit 0)"
        return "doctor --check: ISSUES FOUND (exit %d) — run core/doctor.py --check" % r.returncode
    except Exception as exc:
        return "doctor --check: could not run (%s)" % one_line(exc, 60)


def render_portfolio(projects, ctx, data_dir):
    lines = []
    lines.append("# portfolio — session brief rollup")
    lines.append(
        "generated %s from %d journal entries"
        % (ctx["generated"], len(ctx["entries_with_dt"]))
    )
    lines.append("")
    for project in projects:
        proj = [(e, dt) for e, dt in ctx["entries_with_dt"] if e.get("project") == project]
        n = len(proj)
        dts = [dt for _, dt in proj if dt is not None]
        last = max(dts).strftime("%Y-%m-%d") if dts else "never"
        mines = landmines_for(
            project, ctx["tracker"], ctx["id_to_project"], ctx["window_start_date"]
        )
        if mines:
            name, lifetime, last30, _ = mines[0]
            top = "%s (%d lifetime, %d/30d)" % (one_line(name, 60), lifetime, last30)
        else:
            top = "none"
        lines.append(
            "- %s: %d entries, last %s, top landmine: %s" % (project, n, last, top)
        )
    suggestions = ctx.get("suggestion_lines") or []
    if suggestions:
        lines.append("")
        lines.append("## SUGGESTIONS — categories waiting to be minted (core/taxonomy.py)")
        lines.extend(suggestions)
    lines.append("")
    lines.append(ctx["meta_line"])
    lines.append(doctor_status(data_dir))
    return "\n".join(cap_lines(lines)) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Compile per-project Scribe session briefs.")
    ap.add_argument("--project", help="regenerate only this project's brief (plus _portfolio.md)")
    ap.add_argument(
        "--data-dir",
        default=None,
        help="Scribe data dir (default: $SCRIBE_DATA_PATH > pointer.json > ~/Desktop/Scribe)",
    )
    args = ap.parse_args(argv)

    data_dir = resolve_data_dir(args.data_dir)
    briefs_dir = os.path.join(data_dir, "briefs")
    try:
        os.makedirs(briefs_dir, exist_ok=True)
    except Exception as exc:
        warn("cannot create %s (%s) — nothing to do" % (briefs_dir, exc))
        return 0

    entries = load_journal(os.path.join(data_dir, "journal.jsonl"))
    tracker = load_json(os.path.join(data_dir, "correction-tracker.json"))
    nexus = load_json(os.path.join(data_dir, "nexus.json"))
    projects_cfg = load_json(os.path.join(data_dir, "canonical", "projects.json"))

    handoff_lines = []
    try:
        with open(os.path.join(data_dir, "handoff.md"), "r", encoding="utf-8") as f:
            handoff_lines = f.read().splitlines()
    except Exception:
        pass

    forced = None
    if args.project:
        forced = re.sub(r"[^A-Za-z0-9._-]", "-", args.project.strip()).lstrip(".") or None
        if forced != args.project:
            warn("sanitized --project %r -> %r" % (args.project, forced))

    projects, terms = build_project_terms(projects_cfg, entries, forced)
    matchers = compile_matchers(terms)

    entries_with_dt = [(e, parse_ts(e.get("timestamp"))) for e in entries]
    # newest first; undated entries sink to the bottom deterministically
    entries_with_dt.sort(
        key=lambda p: (p[1] is not None, p[1] or datetime.datetime.min),
        reverse=True,
    )
    dated = [dt for _, dt in entries_with_dt if dt is not None]
    if dated:
        newest = max(dated)
        generated = newest.strftime("%Y-%m-%dT%H:%M:%SZ")
        window_start = newest - datetime.timedelta(days=ROLLING_DAYS)
        window_start_date = window_start.strftime("%Y-%m-%d")
    else:
        generated = "unknown (no dated journal entries)"
        window_start = None
        window_start_date = None

    # prefix -> [(date, project)] oldest-first, so prefix collisions can be
    # resolved by occurrence date (see occurrence_project()).
    id_to_project = {}
    for e, dt in reversed(entries_with_dt):  # oldest first
        eid = str(e.get("id", ""))
        if not eid:
            continue
        date = dt.strftime("%Y-%m-%d") if dt else str(e.get("timestamp", ""))[:10]
        id_to_project.setdefault(eid[:8], []).append((date, e.get("project")))

    ctx = {
        "entries_with_dt": entries_with_dt,
        "tracker": tracker,
        "nexus": nexus,
        "matchers": matchers,
        "handoff_lines": handoff_lines,
        "generated": generated,
        "window_start_date": window_start_date,
        "id_to_project": id_to_project,
        "meta_line": meta_budget_line(entries_with_dt, window_start),
        "suggestion_lines": taxonomy_suggestion_lines(data_dir, projects_cfg),
    }

    targets = [forced] if forced else projects
    for project in targets:
        try:
            content = render_brief(project, ctx)
            atomic_write(os.path.join(briefs_dir, "%s.md" % project), content)
        except Exception as exc:
            warn("failed to write brief for %s: %s" % (project, exc))

    try:
        content = render_portfolio(projects, ctx, data_dir)
        atomic_write(os.path.join(briefs_dir, "_portfolio.md"), content)
    except Exception as exc:
        warn("failed to write _portfolio.md: %s" % exc)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # never crash the writer hook
        warn("unexpected error: %s" % exc)
        sys.exit(0)
