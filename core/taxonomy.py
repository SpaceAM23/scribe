#!/usr/bin/env python3
"""
taxonomy.py — deliberate minting and organizing of Scribe categories.

The problem this solves: there are moments you are creating and adding things
to Scribe that don't have a category yet — there should be the capability to
create and organize them. The writer normalizes unknown projects/types into
defaults (meta / milestone) and queues the ORIGINAL value to
canonical/taxonomy-suggestions.jsonl. This tool is how a human (or an agent
acting on explicit instruction — never automatically) turns those suggestions
into real categories, or files them under existing ones.

Where each category actually lives (the real gates):
  * projects  -> DATA_DIR/canonical/projects.json  projects[] + aliases{}
                 (writer.sh section 10/11 resolves aliases then validates)
  * types     -> DATA_DIR/schema.json .properties.type.enum
                 (writer.sh section 12b enum_valid reads THIS — the user's
                 DATA_DIR copy takes precedence over the install's
                 core/schema.json; add-type seeds the DATA_DIR copy from the
                 install if it doesn't exist yet. The CORE_TYPES string in
                 writer.sh is only a cosmetic stderr NOTE, not a gate — it is
                 deliberately not rewritten by this tool. The Supabase
                 journal_entries type CHECK is a remote gate: add-type prints
                 the SQL you must run, it cannot run it.)
  * patterns  -> canonical/correction-patterns.json patterns[]
                 (track-corrections.py; list order is semantic — first match
                 wins — so new patterns are inserted BEFORE the catch-all)

Subcommands:
  add-project <name> [--alias A ...]     mint a new canonical project
  add-type <name> --purpose "..."        mint a new entry type
  add-pattern <name> --keywords a,b,c --definition "..."
                                         mint a new correction pattern
  list                                   show current projects/types/patterns
  suggestions                            show pending taxonomy suggestions
  resolve <value> --as <existing>|--minted [--kind project|type]
                                         clear suggestion entries

Every mutation: backs up the target file first (.bak-<date>), validates the
JSON after writing, prints exactly what changed, and reminds you to log a
Scribe entry (it never auto-logs). Nothing is ever deleted: resolved
suggestions move to canonical/taxonomy-suggestions-resolved.jsonl.

stdlib only; honors --data-dir > $SCRIBE_DATA_PATH > pointer.json > default
(~/Desktop/Scribe — the same resolution order writer.sh uses).
"""

import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))   # core/ (writer.sh lives here)
INSTALL_ROOT = os.path.dirname(SCRIPT_DIR)                 # repo root (pointer.json lives here)

KEBAB_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SNAKE_RE = re.compile(r"^[a-z][a-z0-9_]*$")

SUGGESTIONS_BASENAME = "taxonomy-suggestions.jsonl"
RESOLVED_BASENAME = "taxonomy-suggestions-resolved.jsonl"

SCRIBE_REMINDER = (
    "Reminder: log a Scribe entry recording this taxonomy change "
    "(type decision_made, project scribe). This tool does NOT auto-log."
)


def die(msg, code=1):
    sys.stderr.write("taxonomy.py: ERROR: %s\n" % msg)
    sys.exit(code)


def note(msg):
    print("taxonomy.py: %s" % msg)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# data dir resolution — mirrors writer.sh resolve_data_path()
# ---------------------------------------------------------------------------

def resolve_data_dir(cli_value):
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


# ---------------------------------------------------------------------------
# safe file plumbing: backup first, atomic write, validate after
# ---------------------------------------------------------------------------

def backup_file(path):
    """Copy path to path.bak-YYYY-MM-DD (never overwrites an earlier backup).
    Returns the backup path, or None if the source doesn't exist."""
    if not os.path.exists(path):
        return None
    stamp = datetime.date.today().isoformat()
    bak = "%s.bak-%s" % (path, stamp)
    if os.path.exists(bak):
        bak = "%s.bak-%s-%s" % (
            path, stamp, datetime.datetime.now().strftime("%H%M%S")
        )
    shutil.copy2(path, bak)
    return bak


def atomic_write_json(path, obj):
    """Write JSON via tmp+rename in the destination dir, then re-load the
    written file to validate it parses. Raises on any failure."""
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".taxonomy-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, ensure_ascii=False)
            f.write("\n")
        with open(tmp, "r", encoding="utf-8") as f:
            json.load(f)  # validate before it can replace the real file
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise
    # validate the file that actually landed
    with open(path, "r", encoding="utf-8") as f:
        json.load(f)


def load_json_or_die(path, what):
    if not os.path.isfile(path):
        die("%s not found at %s" % (what, path))
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as exc:
        die("%s is not valid JSON (%s): %s" % (what, path, exc))


def load_json_optional(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# canon lookups
# ---------------------------------------------------------------------------

def projects_path(data_dir):
    return os.path.join(data_dir, "canonical", "projects.json")


def schema_path(data_dir):
    return os.path.join(data_dir, "schema.json")


def patterns_path(data_dir):
    return os.path.join(data_dir, "canonical", "correction-patterns.json")


def suggestions_path(data_dir):
    return os.path.join(data_dir, "canonical", SUGGESTIONS_BASENAME)


def resolved_path(data_dir):
    return os.path.join(data_dir, "canonical", RESOLVED_BASENAME)


def known_projects(data_dir):
    """(projects_list, aliases_dict) — empty on missing/corrupt file."""
    cfg = load_json_optional(projects_path(data_dir))
    if not isinstance(cfg, dict):
        return [], {}
    projs = [p for p in cfg.get("projects", []) if isinstance(p, str)]
    aliases = cfg.get("aliases", {})
    if not isinstance(aliases, dict):
        aliases = {}
    return projs, aliases


def known_types(data_dir):
    schema = load_json_optional(schema_path(data_dir))
    if schema is None:
        # No user copy in DATA_DIR yet — read the install's core/schema.json
        schema = load_json_optional(os.path.join(SCRIPT_DIR, "schema.json"))
    try:
        enum = schema["properties"]["type"]["enum"]
        return [t for t in enum if isinstance(t, str)]
    except Exception:
        return []


def value_is_known(kind, value, data_dir):
    if kind == "project":
        projs, aliases = known_projects(data_dir)
        return value in projs or value in aliases
    if kind == "type":
        return value in known_types(data_dir)
    return False


# ---------------------------------------------------------------------------
# suggestions queue
# ---------------------------------------------------------------------------

def load_suggestions(data_dir):
    """Returns (parsed_rows, unparseable_count). Each row keeps its raw line
    so resolve can move it verbatim. Never raises."""
    rows = []
    bad = 0
    try:
        with open(suggestions_path(data_dir), "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    bad += 1
                    rows.append({"_raw": line, "_parsed": None})
                    continue
                if isinstance(obj, dict):
                    rows.append({"_raw": line, "_parsed": obj})
                else:
                    bad += 1
                    rows.append({"_raw": line, "_parsed": None})
    except FileNotFoundError:
        pass
    except Exception:
        pass
    return rows, bad


def clear_suggestions(data_dir, kind, values, resolution):
    """Move pending suggestion lines whose kind+value match into the resolved
    file (annotated), rewriting the queue atomically. Nothing is deleted.
    Returns the number of lines moved."""
    rows, _bad = load_suggestions(data_dir)
    if not rows:
        return 0
    values = set(values)
    keep, move = [], []
    for row in rows:
        obj = row["_parsed"]
        if (
            isinstance(obj, dict)
            and obj.get("kind") == kind
            and obj.get("value") in values
        ):
            move.append(row)
        else:
            keep.append(row)
    if not move:
        return 0

    spath = suggestions_path(data_dir)
    bak = backup_file(spath)
    if bak:
        note("backed up %s -> %s" % (os.path.basename(spath), os.path.basename(bak)))

    resolved_at = now_iso()
    # append to the resolved file FIRST (crash between the two steps leaves a
    # duplicate in both files — recoverable; the reverse order loses data)
    with open(resolved_path(data_dir), "a", encoding="utf-8") as f:
        for row in move:
            obj = dict(row["_parsed"])
            obj["resolved_at"] = resolved_at
            obj["resolution"] = resolution
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")

    d = os.path.dirname(spath) or "."
    fd, tmp = tempfile.mkstemp(prefix=".taxonomy-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            for row in keep:
                f.write(row["_raw"] + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, spath)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise
    return len(move)


def pending_by_value(data_dir):
    """{(kind, value): [suggestion_dict, ...]} for still-unknown values."""
    rows, _bad = load_suggestions(data_dir)
    grouped = {}
    for row in rows:
        obj = row["_parsed"]
        if not isinstance(obj, dict):
            continue
        kind = obj.get("kind")
        value = obj.get("value")
        if kind not in ("project", "type") or not isinstance(value, str):
            continue
        if value_is_known(kind, value, data_dir):
            continue  # already minted/aliased — brief filters these too
        grouped.setdefault((kind, value), []).append(obj)
    return grouped


# ---------------------------------------------------------------------------
# subcommand: add-project
# ---------------------------------------------------------------------------

def cmd_add_project(args, data_dir):
    name = args.name
    if not KEBAB_RE.match(name):
        die(
            "project name %r is not kebab-case (lowercase letters/digits "
            "separated by single hyphens, e.g. 'my-new-app')" % name
        )
    ppath = projects_path(data_dir)
    if not os.path.isfile(ppath):
        # First mint: create the registry. 'meta' is always included because
        # it is the writer's normalization target for unknown projects.
        # NOTE: an empty projects[] is "open mode" (writer accepts anything);
        # the first mint switches enforcement ON — unknown projects will be
        # normalized to 'meta' and queued as suggestions from now on.
        os.makedirs(os.path.dirname(ppath), exist_ok=True)
        atomic_write_json(ppath, {"projects": ["meta"], "aliases": {}})
        note("created %s (registry enforcement is now ON: mint every project you use)" % ppath)
    cfg = load_json_or_die(ppath, "canonical/projects.json")
    projs = cfg.get("projects")
    aliases = cfg.get("aliases")
    if not isinstance(projs, list) or not isinstance(aliases, dict):
        die("canonical/projects.json has an unexpected shape (need projects[] and aliases{})")

    if name in projs:
        die("project %r is already canonical — nothing to mint" % name)
    if name in aliases:
        die(
            "%r is already an alias of %r. If it deserves to be its own "
            "project, remove the alias first (deliberately, with a backup)."
            % (name, aliases[name])
        )

    new_aliases = []
    for alias in args.alias or []:
        if alias == name:
            note("skipping alias %r (same as the project name)" % alias)
            continue
        if alias in projs:
            die("alias %r is already a canonical project name" % alias)
        if alias in aliases:
            if aliases[alias] == name:
                note("alias %r already maps to %r — skipping" % (alias, name))
                continue
            die("alias %r already maps to %r" % (alias, aliases[alias]))
        if alias in new_aliases:
            continue
        new_aliases.append(alias)

    bak = backup_file(ppath)
    note("backed up projects.json -> %s" % os.path.basename(bak))
    cfg["projects"] = projs + [name]
    for alias in new_aliases:
        cfg["aliases"][alias] = name
    atomic_write_json(ppath, cfg)

    print("MINTED project %r in %s" % (name, ppath))
    print("  projects: %d -> %d" % (len(projs), len(projs) + 1))
    for alias in new_aliases:
        print("  alias added: %r -> %r" % (alias, name))

    cleared = clear_suggestions(
        data_dir, "project", [name] + new_aliases, "minted"
    )
    if cleared:
        print(
            "  resolved %d pending suggestion line(s) -> %s"
            % (cleared, RESOLVED_BASENAME)
        )
    print(SCRIBE_REMINDER)
    return 0


# ---------------------------------------------------------------------------
# subcommand: add-type
# ---------------------------------------------------------------------------

def cmd_add_type(args, data_dir):
    name = args.name
    if not SNAKE_RE.match(name):
        die(
            "type name %r is not snake_case (existing types: feature_shipped, "
            "bug_fixed, ...) — use lowercase letters/digits/underscores" % name
        )
    spath = schema_path(data_dir)
    if not os.path.isfile(spath):
        # Seed the user's DATA_DIR copy from the install's core/schema.json —
        # the writer gives the DATA_DIR copy precedence, so minting into it
        # never touches (and is never clobbered by) the version-controlled core.
        install_schema = os.path.join(SCRIPT_DIR, "schema.json")
        if os.path.isfile(install_schema):
            shutil.copy2(install_schema, spath)
            note("seeded %s from the install's core/schema.json (your copy now takes precedence)" % spath)
    schema = load_json_or_die(spath, "schema.json")
    try:
        enum = schema["properties"]["type"]["enum"]
        assert isinstance(enum, list)
    except Exception:
        die("schema.json has no .properties.type.enum array — wrong schema file?")

    if name in enum:
        die("type %r is already in the schema enum — nothing to mint" % name)

    bak = backup_file(spath)
    note("backed up schema.json -> %s" % os.path.basename(bak))
    schema["properties"]["type"]["enum"] = enum + [name]
    desc = schema["properties"]["type"].get("description", "")
    purpose = " ".join(args.purpose.split())
    schema["properties"]["type"]["description"] = (
        "%s '%s' = %s" % (desc.rstrip(), name, purpose)
    ).strip()
    atomic_write_json(spath, schema)

    print("MINTED type %r in %s" % (name, spath))
    print("  enum: %d -> %d values" % (len(enum), len(enum) + 1))
    print("  purpose recorded in the type description: %s" % purpose)
    print("")
    print("  NOTE (cosmetic): writer.sh will still print \"Custom entry type\"")
    print("  on stderr for %r — CORE_TYPES there is a soft note, not a gate;" % name)
    print("  the entry is accepted un-normalized now that schema.json has it.")
    print("")
    print("  REQUIRED MANUAL STEP — Supabase gate: journal_entries has a type")
    print("  CHECK constraint. Until it includes %r, remote inserts of this" % name)
    print("  type FAIL and sit in sync-queue.jsonl (reconcile.sh replays them")
    print("  once the constraint is fixed). In the Supabase SQL editor:")
    print("    -- inspect the current constraint:")
    print("    SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint")
    print("      WHERE conrelid = 'journal_entries'::regclass AND contype = 'c';")
    print("    -- then drop and re-add it with %r included in the IN (...) list." % name)

    cleared = clear_suggestions(data_dir, "type", [name], "minted")
    if cleared:
        print(
            "  resolved %d pending suggestion line(s) -> %s"
            % (cleared, RESOLVED_BASENAME)
        )
    print(SCRIBE_REMINDER)
    return 0


# ---------------------------------------------------------------------------
# subcommand: add-pattern
# ---------------------------------------------------------------------------

def cmd_add_pattern(args, data_dir):
    name = args.name
    if not KEBAB_RE.match(name):
        die("pattern slug %r is not kebab-case (e.g. 'ship-before-verify')" % name)
    keywords = [k.strip() for k in (args.keywords or "").split(",") if k.strip()]
    if not keywords:
        die("--keywords must supply at least one comma-separated matcher")
    definition = " ".join(args.definition.split())
    if not definition:
        die("--definition must not be empty")

    cpath = patterns_path(data_dir)
    vocab = load_json_or_die(cpath, "canonical/correction-patterns.json")
    patterns = vocab.get("patterns")
    if not isinstance(patterns, list):
        die("correction-patterns.json has no patterns[] list — unexpected shape")

    for p in patterns:
        if not isinstance(p, dict):
            continue
        if p.get("slug") == name:
            die("pattern slug %r already exists" % name)
        if name in (p.get("aliases") or []):
            die("%r is already an alias of pattern %r" % (name, p.get("slug")))

    for kw in keywords:
        try:
            re.compile(kw)
        except re.error as exc:
            note(
                "keyword %r does not compile as a regex (%s) — "
                "track-corrections.py will fall back to substring matching" % (kw, exc)
            )

    new_pattern = {
        "slug": name,
        "definition": definition,
        "aliases": [name],
        "matchers": keywords,
        "escalate": True,
    }

    # order is semantic (first match wins): insert BEFORE the catch-all
    insert_at = len(patterns)
    for i, p in enumerate(patterns):
        if isinstance(p, dict) and p.get("catch_all"):
            insert_at = i
            break

    bak = backup_file(cpath)
    note("backed up correction-patterns.json -> %s" % os.path.basename(bak))
    patterns.insert(insert_at, new_pattern)
    old_vv = vocab.get("vocabulary_version")
    if isinstance(old_vv, int):
        vocab["vocabulary_version"] = old_vv + 1
    atomic_write_json(cpath, vocab)

    print("MINTED correction pattern %r in %s" % (name, cpath))
    print("  inserted at position %d (before the catch-all)" % insert_at)
    print("  matchers: %s" % ", ".join(repr(k) for k in keywords))
    print("  definition: %s" % definition)
    if isinstance(old_vv, int):
        print("  vocabulary_version: %d -> %d" % (old_vv, old_vv + 1))
    print(
        "  Existing 'uncategorized' occurrences are NOT reclassified "
        "automatically — rerun classification deliberately if needed."
    )
    print(SCRIBE_REMINDER)
    return 0


# ---------------------------------------------------------------------------
# subcommand: list
# ---------------------------------------------------------------------------

def cmd_list(_args, data_dir):
    projs, aliases = known_projects(data_dir)
    print("PROJECTS (%d) — canonical/projects.json" % len(projs))
    for p in projs:
        also = sorted(a for a, c in aliases.items() if c == p)
        if also:
            print("  %s  (aliases: %s)" % (p, ", ".join(also)))
        else:
            print("  %s" % p)
    orphan = sorted(a for a, c in aliases.items() if c not in projs)
    for a in orphan:
        print("  WARNING: alias %r -> %r (target not canonical)" % (a, aliases[a]))

    types = known_types(data_dir)
    print("")
    print("TYPES (%d) — schema.json .properties.type.enum" % len(types))
    for t in types:
        print("  %s" % t)

    vocab = load_json_optional(patterns_path(data_dir))
    patterns = (vocab or {}).get("patterns") if isinstance(vocab, dict) else None
    print("")
    if isinstance(patterns, list):
        print(
            "CORRECTION PATTERNS (%d) — canonical/correction-patterns.json"
            % len(patterns)
        )
        for p in patterns:
            if not isinstance(p, dict):
                continue
            flags = []
            if p.get("catch_all"):
                flags.append("catch-all")
            if not p.get("escalate", True):
                flags.append("no-escalate")
            suffix = (" [%s]" % ", ".join(flags)) if flags else ""
            print(
                "  %s — %d matcher(s)%s"
                % (p.get("slug", "?"), len(p.get("matchers") or []), suffix)
            )
    else:
        print("CORRECTION PATTERNS — canonical/correction-patterns.json not found")
    return 0


# ---------------------------------------------------------------------------
# subcommand: suggestions
# ---------------------------------------------------------------------------

def cmd_suggestions(_args, data_dir):
    rows, bad = load_suggestions(data_dir)
    grouped = pending_by_value(data_dir)
    if not rows and not grouped:
        print("No taxonomy suggestions queued (%s absent or empty)." % SUGGESTIONS_BASENAME)
        return 0
    if not grouped:
        print("No PENDING taxonomy suggestions — all queued values are now known.")
        if bad:
            print("  (%d unparseable line(s) left in place in %s)" % (bad, SUGGESTIONS_BASENAME))
        return 0

    print("PENDING TAXONOMY SUGGESTIONS — %s" % suggestions_path(data_dir))
    ordered = sorted(grouped.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    me = os.path.join(SCRIPT_DIR, "taxonomy.py")
    for (kind, value), items in ordered:
        first = min(str(i.get("ts", "")) for i in items)
        last = max(str(i.get("ts", "")) for i in items)
        print("")
        print("  unknown %s %r — seen %dx (first %s, last %s)" % (kind, value, len(items), first or "?", last or "?"))
        for i in items[-3:]:
            title = re.sub(r"\s+", " ", str(i.get("title", "?")))
            print("    - entry %s: %s" % (str(i.get("entry_id", "?"))[:8], title))
        # shell-quote the EXACT queued value so the printed command matches it
        # (a multi-line single-quoted string is legal shell); only offer a
        # mint command the validator would actually accept
        quoted = shlex.quote(value)
        if kind == "project" and KEBAB_RE.match(value):
            print("    mint : python3 %s add-project %s" % (me, quoted))
        elif kind == "type" and SNAKE_RE.match(value):
            print("    mint : python3 %s add-type %s --purpose \"...\"" % (me, quoted))
        else:
            print("    mint : (value is not a valid %s name — alias it under an existing one instead)" % kind)
        print("    file : python3 %s resolve %s --as <existing-%s>   (or --minted after minting)" % (me, quoted, kind))
    if bad:
        print("")
        print("  (%d unparseable line(s) left in place — inspect %s manually)" % (bad, SUGGESTIONS_BASENAME))
    return 0


# ---------------------------------------------------------------------------
# subcommand: resolve
# ---------------------------------------------------------------------------

def cmd_resolve(args, data_dir):
    value = args.value
    if bool(args.as_name) == bool(args.minted):
        die("resolve needs exactly one of --as <existing-name> or --minted")

    rows, _bad = load_suggestions(data_dir)
    kinds = sorted(
        {
            r["_parsed"].get("kind")
            for r in rows
            if isinstance(r["_parsed"], dict)
            and r["_parsed"].get("value") == value
            and r["_parsed"].get("kind") in ("project", "type")
        }
    )
    if not kinds:
        die("no queued suggestion has value %r (see: taxonomy.py suggestions)" % value)
    if args.kind:
        if args.kind not in kinds:
            die("no queued %r suggestion has value %r (queued kinds: %s)" % (args.kind, value, ", ".join(kinds)))
        kind = args.kind
    elif len(kinds) > 1:
        die("value %r is queued as both project and type — pass --kind" % value)
    else:
        kind = kinds[0]

    if args.minted:
        if not value_is_known(kind, value, data_dir):
            die(
                "%r is not a known %s yet — mint it first (add-%s) or use --as"
                % (value, kind, kind)
            )
        resolution = "minted"
    else:
        target = args.as_name
        if not value_is_known(kind, target, data_dir):
            die("--as target %r is not a known %s" % (target, kind))
        if kind == "project":
            projs, aliases = known_projects(data_dir)
            canon = aliases.get(target, target)  # resolve alias target to canon
            if value in projs or value in aliases:
                note("%r already resolves to a known project — no alias needed" % value)
            else:
                ppath = projects_path(data_dir)
                cfg = load_json_or_die(ppath, "canonical/projects.json")
                bak = backup_file(ppath)
                note("backed up projects.json -> %s" % os.path.basename(bak))
                cfg.setdefault("aliases", {})[value] = canon
                atomic_write_json(ppath, cfg)
                print("ALIAS added: %r -> %r (future submissions resolve cleanly)" % (value, canon))
            resolution = "alias-of:%s" % canon
        else:
            print(
                "NOTE: types have no alias map — the writer will keep "
                "normalizing %r. If agents keep sending it, either fix the "
                "prompt that produces it or mint it with add-type." % value
            )
            resolution = "existing:%s" % target

    cleared = clear_suggestions(data_dir, kind, [value], resolution)
    print(
        "RESOLVED %d suggestion line(s) for %s %r -> %s (resolution=%s)"
        % (cleared, kind, value, RESOLVED_BASENAME, resolution)
    )
    print(SCRIBE_REMINDER)
    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Deliberate minting and organizing of Scribe categories."
    )
    ap.add_argument(
        "--data-dir",
        default=None,
        help="Scribe data dir (default: $SCRIBE_DATA_PATH > pointer.json > ~/Desktop/Scribe)",
    )
    sub = ap.add_subparsers(dest="cmd")

    p = sub.add_parser("add-project", help="mint a new canonical project")
    p.add_argument("name")
    p.add_argument("--alias", action="append", default=[], help="alias mapping to the new project (repeatable)")

    p = sub.add_parser("add-type", help="mint a new entry type")
    p.add_argument("name")
    p.add_argument("--purpose", required=True, help="what this type records")

    p = sub.add_parser("add-pattern", help="mint a new correction pattern")
    p.add_argument("name")
    p.add_argument("--keywords", required=True, help="comma-separated matcher regexes/substrings")
    p.add_argument("--definition", required=True, help="what the pattern means")

    sub.add_parser("list", help="show current projects/types/patterns")
    sub.add_parser("suggestions", help="show pending taxonomy suggestions")

    p = sub.add_parser("resolve", help="clear suggestion entries for a value")
    p.add_argument("value")
    p.add_argument("--as", dest="as_name", default=None, help="file the value under this existing name")
    p.add_argument("--minted", action="store_true", help="the value was minted — verify and clear")
    p.add_argument("--kind", choices=("project", "type"), default=None, help="disambiguate when a value is queued under both kinds")

    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 1

    data_dir = resolve_data_dir(args.data_dir)
    if not os.path.isdir(data_dir):
        die("data dir does not exist: %s" % data_dir)

    handlers = {
        "add-project": cmd_add_project,
        "add-type": cmd_add_type,
        "add-pattern": cmd_add_pattern,
        "list": cmd_list,
        "suggestions": cmd_suggestions,
        "resolve": cmd_resolve,
    }
    return handlers[args.cmd](args, data_dir)


if __name__ == "__main__":
    sys.exit(main())
