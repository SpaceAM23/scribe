#!/usr/bin/env python3
"""
team-sync.py — push this Scribe's local journal into your Team Rocksteady partition.

You journal locally as always; this syncs new entries up to the shared Supabase partition
through your personal scoped JWT — you can only write your own `owner` rows (RLS-enforced).
Idempotent (skips entries already in your partition). Run on-demand or at session end.

Setup: drop a `team-config.json` in your Scribe data dir:
  { "url": "https://<ref>.supabase.co", "anon_key": "<team anon key>",
    "jwt": "<your personal team JWT>", "owner": "<your id>" }
Then: python3 scripts/team-sync.py
"""
import json, os, sys, urllib.request, urllib.error


def data_path():
    p = os.environ.get("SCRIBE_DATA_PATH")
    if p:
        return os.path.expanduser(p)
    here = os.path.dirname(os.path.abspath(__file__))
    for ptr in (os.path.join(here, "..", "pointer.json"), os.path.join(here, "pointer.json")):
        if os.path.isfile(ptr):
            try:
                d = json.load(open(ptr)).get("data_path")
                if d:
                    return os.path.expanduser(d)
            except Exception:
                pass
    return os.path.expanduser("~/Desktop/Scribe")


DD = data_path()
cfg_path = os.path.join(DD, "team-config.json")
if not os.path.isfile(cfg_path):
    sys.exit("no team-config.json in %s — add {url, anon_key, jwt, owner} to enable team sync" % DD)
cfg = json.load(open(cfg_path))
URL = cfg["url"].rstrip("/"); JWT = cfg["jwt"]; OWNER = cfg["owner"]; ANON = cfg.get("anon_key", JWT)
FIELDS = ("id", "timestamp", "session_id", "project", "type", "title", "summary",
          "decisions", "learnings", "corrections", "metrics", "connections", "growth", "behavioral")


def call(method, path, body=None):
    hdr = {"apikey": ANON, "Authorization": f"Bearer {JWT}", "Content-Type": "application/json",
           ("Content-Profile" if method != "GET" else "Accept-Profile"): "team_rocksteady"}
    if method == "POST":
        hdr["Prefer"] = "resolution=ignore-duplicates,return=minimal"
    r = urllib.request.Request(f"{URL}/rest/v1{path}",
                               data=json.dumps(body).encode() if body is not None else None,
                               headers=hdr, method=method)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    s, b = call("GET", "/scribe_journal?select=id")
    if s != 200:
        sys.exit(f"cannot reach your team partition ({s}): {b[:200]}")
    have = set(r["id"] for r in (json.loads(b) if b else []))
    rows = []
    jp = os.path.join(DD, "journal.jsonl")
    if not os.path.isfile(jp):
        sys.exit("no journal.jsonl yet — nothing to sync")
    for line in open(jp):
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        if not e.get("id") or e["id"] in have:
            continue
        ef = os.path.join(DD, e.get("file") or f"entries/{e['id'][:8]}.json")
        full = json.load(open(ef)) if os.path.isfile(ef) else e
        rows.append({"owner": OWNER, **{f: full.get(f) for f in FIELDS}})
    if not rows:
        print("team partition already current — nothing to sync.")
        return
    for i in range(0, len(rows), 100):
        st, bd = call("POST", "/scribe_journal", rows[i:i + 100])
        if st not in (200, 201, 204):
            sys.exit(f"sync failed ({st}): {bd[:200]}")
    print(f"synced {len(rows)} entries to your Team Rocksteady partition (owner={OWNER}).")


if __name__ == "__main__":
    main()
