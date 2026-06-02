#!/usr/bin/env python3
"""
librarian.py — the Librarian apply-engine (NEXUS phase 2: the mind that grows itself).

The extraction (reading journal entries and proposing knowledge claims) is done by
librarian agents driven by core/librarian-prompt.md. THIS engine is the governed,
deterministic half: it takes their gated proposals and curates them into NEXUS.

Promotion gate: {key, content, proposed_domain, informant, confidence, salience, evidence[], parent_key?}
Per proposal: gate-validate -> reconcile (NEW / DUPLICATE-merge-evidence / SUPERSEDE+CONTRADICT+new-domain = TAP)
-> auto-apply safe, TAP risky. Idempotent (content-hash dedup). Dry-run by default; --commit writes.

Two storage backends, auto-selected:
  * Management API  — direct Supabase (SUPABASE_ACCESS_TOKEN + SUPABASE_PROJECT_REF / config.json).
  * Team REST       — a shared Supabase partition via your scoped JWT (team-config.json present).
                      Your NEXUS grows in team_rocksteady.* under your owner; RLS keeps it yours.

Modes: --status | --pending | --init (seed default domains/informants) | --prep [N] | --apply <file> [--commit]
"""
import json, os, re, sys, time, hashlib, datetime, urllib.request, urllib.error


def _data_path():
    p = os.environ.get("SCRIBE_DATA_PATH")
    if p:
        return os.path.expanduser(p)
    here = os.path.dirname(os.path.abspath(__file__))
    for ptr in (os.path.join(here, "..", "pointer.json"), os.path.join(here, "pointer.json")):
        if os.path.isfile(ptr):
            try:
                dp = json.load(open(ptr)).get("data_path")
                if dp:
                    return os.path.expanduser(dp)
            except Exception:
                pass
    return os.path.expanduser("~/Desktop/Scribe")


REPO = _data_path()
STATE = os.path.join(REPO, "librarian-state.json")
TAP_QUEUE = os.path.join(REPO, "librarian-tap-queue.jsonl")
CONF_OK = {"observed", "inferred", "hypothesis"}
HV_TYPES = {"decision_made", "learning", "feature_shipped", "milestone",
            "reflection", "process_created", "tool_discovered"}
SHORTID = re.compile(r"^[0-9a-f]{8}$")
DEFAULT_DOMAINS = [("system", "System — infrastructure, deployment, configuration, environment"),
                   ("product", "Product — user-facing behavior, features, interfaces, flows"),
                   ("process", "Process — workflows, decision rules, operational patterns"),
                   ("people", "People — collaborators, relationships, roles, communication"),
                   ("knowledge", "Knowledge — what is known, uncertain, or needs investigation")]
DEFAULT_INFORMANTS = [("scribe_journal", "Scribe journal", "agent", "high"),
                      ("self", "The user, directly", "human", "high")]


def esc(s):
    return str(s).replace("'", "''")


def norm(s):
    return re.sub(r"\s+", " ", (s or "").strip().lower())


def chash(s):
    return hashlib.sha256(norm(s).encode()).hexdigest()[:16]


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ============================ storage backends ============================

class ManagementBackend:
    """Direct Supabase via the Management API (arbitrary SQL). For a self-hosted/owned project."""
    name = "management"

    def __init__(self, ref, token):
        self.url = f"https://api.supabase.com/v1/projects/{ref}/database/query"
        self.token = token

    def q(self, sql, _tries=6):
        body = json.dumps({"query": sql}).encode()
        for attempt in range(_tries):
            req = urllib.request.Request(self.url, data=body, headers={
                "Authorization": f"Bearer {self.token}", "Content-Type": "application/json", "User-Agent": "librarian/2.0"})
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    return json.loads(r.read())
            except urllib.error.HTTPError as ex:
                if ex.code == 429 and attempt < _tries - 1:
                    time.sleep(2 ** attempt); continue
                raise RuntimeError(f"HTTP {ex.code}: {ex.read().decode()[:300]}\nSQL: {sql[:120]}")

    def domains(self): return self.q("select slug,id from nexus_domains")
    def domains_named(self): return self.q("select slug,name from nexus_domains order by slug")
    def informants(self): return self.q("select slug,id from nexus_informants")
    def active_nodes(self): return self.q("select id, domain_id, key, content from nexus_nodes where status='active'")
    def node_total(self): return self.q("select count(*) c from nexus_nodes where status='active'")[0]["c"]

    def insert_domain(self, slug, name):
        self.q(f"insert into nexus_domains (slug,name) values ('{esc(slug)}','{esc(name)}') on conflict (slug) do nothing")

    def insert_informant(self, slug, name, kind, trust):
        self.q(f"insert into nexus_informants (slug,name,kind,trust_default) values "
               f"('{esc(slug)}','{esc(name)}','{esc(kind)}','{esc(trust)}') on conflict (slug) do nothing")

    def insert_nodes(self, rows):
        return self.q("insert into nexus_nodes (domain_id,parent_id,key,content,confidence,salience,informant_id,evidence,created_by) "
                      "select (v->>'domain_id')::uuid, nullif(v->>'parent_id','')::uuid, v->>'key', v->>'content', "
                      "v->>'confidence', (v->>'salience')::int, (v->>'informant_id')::uuid, (v->'evidence')::jsonb, v->>'created_by' "
                      f"from jsonb_array_elements('{esc(json.dumps(rows))}'::jsonb) v returning id, key, domain_id")

    def merge_evidence(self, node_id, evidence):
        add = esc(json.dumps(evidence))
        self.q("update nexus_nodes set evidence = (select jsonb_agg(distinct e) "
               f"from jsonb_array_elements(evidence || '{add}'::jsonb) e), updated_at=now() where id='{esc(node_id)}'")

    def update_watermark(self, total):
        self.q(f"update nexus_librarian_state set last_ingest_at=now(), last_node_count={total}, updated_at=now() where id=1")
        self.q("update nexus_librarian_due set acknowledged=true where not acknowledged")

    def get_due(self):
        return self.q("select pending_count, detected_at::text d from nexus_librarian_due "
                      "where not acknowledged order by detected_at desc limit 1")


class RestBackend:
    """Shared team partition via PostgREST + a scoped JWT. Writes land under your owner; RLS keeps it yours."""
    name = "team"

    def __init__(self, url, anon, jwt, owner):
        self.base = url.rstrip("/") + "/rest/v1"
        self.anon, self.jwt, self.owner = anon, jwt, owner

    def _call(self, method, path, body=None, count=False):
        hdr = {"apikey": self.anon, "Authorization": f"Bearer {self.jwt}", "Content-Type": "application/json",
               ("Content-Profile" if method != "GET" else "Accept-Profile"): "team_rocksteady"}
        if method == "POST":
            hdr["Prefer"] = "return=representation"
        if count:
            hdr["Prefer"] = "count=exact"; path += ("&" if "?" in path else "?") + "limit=1"
        req = urllib.request.Request(self.base + path,
                                     data=json.dumps(body).encode() if body is not None else None, headers=hdr, method=method)
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                if count:
                    cr = r.headers.get("Content-Range", "*/0"); return int(cr.rsplit("/", 1)[-1] or 0)
                raw = r.read(); return json.loads(raw) if raw.strip() else []
        except urllib.error.HTTPError as ex:
            raise RuntimeError(f"HTTP {ex.code} {method} {path}: {ex.read().decode()[:300]}")

    def domains(self): return self._call("GET", "/nexus_domains?select=slug,id")
    def domains_named(self): return self._call("GET", "/nexus_domains?select=slug,name&order=slug")
    def informants(self): return self._call("GET", "/nexus_informants?select=slug,id")
    def active_nodes(self): return self._call("GET", "/nexus_nodes?select=id,domain_id,key,content&status=eq.active")
    def node_total(self): return self._call("GET", "/nexus_nodes?status=eq.active&select=id", count=True)

    def insert_domain(self, slug, name):
        self._call("POST", "/nexus_domains", [{"owner": self.owner, "slug": slug, "name": name}])

    def insert_informant(self, slug, name, kind, trust):
        self._call("POST", "/nexus_informants", [{"owner": self.owner, "slug": slug, "name": name, "kind": kind, "trust_default": trust}])

    def insert_nodes(self, rows):
        rows = [{**r, "owner": self.owner} for r in rows]
        res = self._call("POST", "/nexus_nodes", rows)
        return [{"id": r["id"], "key": r["key"], "domain_id": r["domain_id"]} for r in res]

    def merge_evidence(self, node_id, evidence):
        cur = self._call("GET", f"/nexus_nodes?id=eq.{node_id}&select=evidence")
        existing = (cur[0]["evidence"] if cur else []) or []
        out = list(existing)
        for x in evidence:
            if x not in out:
                out.append(x)
        self._call("PATCH", f"/nexus_nodes?id=eq.{node_id}", {"evidence": out, "updated_at": now_iso()})

    def update_watermark(self, total):
        pass                                              # collaborators track the watermark in local librarian-state.json

    def get_due(self):
        return []                                         # pg_cron scheduler is owner-side only


def select_backend():
    """team-config.json -> RestBackend ; else Management (token+ref) ; else error."""
    tc = os.path.join(REPO, "team-config.json")
    if os.path.isfile(tc):
        c = json.load(open(tc))
        return RestBackend(c["url"], c.get("anon_key", c["jwt"]), c["jwt"], c["owner"])
    token = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
    ref = os.environ.get("SUPABASE_PROJECT_REF", "")
    if not ref:
        cfgp = os.path.join(REPO, "config.json")
        if os.path.isfile(cfgp):
            sb = (json.load(open(cfgp)).get("storage", {}) or {}).get("supabase", {}) or {}
            ref = sb.get("project_ref") or (re.search(r"https?://([a-z0-9]+)\.supabase\.co", sb.get("url", "")) or [None, ""])[1]
    if token and ref:
        return ManagementBackend(ref, token)
    sys.exit("ERROR: no backend — set team-config.json (team) OR SUPABASE_ACCESS_TOKEN + SUPABASE_PROJECT_REF (direct).")


BACKEND = None


# ============================ engine ============================

def load_state():
    if os.path.isfile(STATE):
        return json.load(open(STATE))
    return {"watermark": None, "processed_entries": [], "last_run": None, "applied": 0, "tapped": 0}


def save_state(st):
    json.dump(st, open(STATE, "w"), indent=2)


def load_nexus():
    domains = {d["slug"]: d["id"] for d in BACKEND.domains()}
    id2slug = {v: k for k, v in domains.items()}
    informants = {i["slug"]: i["id"] for i in BACKEND.informants()}
    nodes = [{"id": n["id"], "dom": id2slug.get(n["domain_id"]), "key": n["key"], "content": n["content"]}
             for n in BACKEND.active_nodes()]
    by_key = {(n["dom"], n["key"]): n for n in nodes}
    by_chash = {(n["dom"], chash(n["content"])): n for n in nodes}
    return domains, informants, by_key, by_chash, nodes


def gate(p):
    for f in ("key", "content", "proposed_domain", "informant", "confidence", "salience"):
        if not p.get(f) and p.get(f) != 0:
            return False, f"missing {f}"
    if not p.get("evidence"):
        return False, "missing provenance (evidence[])"
    if p["confidence"] not in CONF_OK:
        return False, f"bad confidence '{p['confidence']}'"
    try:
        s = int(p["salience"])
    except (TypeError, ValueError):
        return False, "salience not an int"
    if not (1 <= s <= 5):
        return False, "salience out of 1..5"
    return True, ""


def cmd_init():
    domains = {d["slug"]: d["id"] for d in BACKEND.domains()}
    informants = {i["slug"]: i["id"] for i in BACKEND.informants()}
    dn = inn = 0
    for slug, name in DEFAULT_DOMAINS:
        if slug not in domains:
            BACKEND.insert_domain(slug, name); dn += 1
    for slug, name, kind, trust in DEFAULT_INFORMANTS:
        if slug not in informants:
            BACKEND.insert_informant(slug, name, kind, trust); inn += 1
    print(f"[{BACKEND.name}] seeded {dn} default domains, {inn} informants. "
          f"(domains now: {len(domains)+dn}, informants: {len(informants)+inn})")


def cmd_status():
    domains, informants, by_key, by_chash, nodes = load_nexus()
    st = load_state()
    tap = sum(1 for _ in open(TAP_QUEUE)) if os.path.isfile(TAP_QUEUE) else 0
    print(f"[{BACKEND.name}] NEXUS: {len(nodes)} active nodes across {len(domains)} domains, {len(informants)} informants")
    counts = {}
    for n in nodes:
        counts[n["dom"]] = counts.get(n["dom"], 0) + 1
    for slug, c in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"  {str(slug):16} {c}")
    print(f"watermark last_run: {st.get('last_run')}  ingested_entries: {len(st.get('processed_entries', []))}  "
          f"applied_total: {st.get('applied', 0)}  tap_queue: {tap}")
    try:
        due = BACKEND.get_due()
        if due:
            print(f"  RUN DUE — scheduler flagged {due[0]['pending_count']} pending entries at {due[0]['d'][:16]}")
    except Exception:
        pass


def cmd_pending():
    done = set(load_state().get("processed_entries", []))
    rows = []
    for line in open(os.path.join(REPO, "journal.jsonl")):
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        sid = (e.get("file", "").split("/")[-1].replace(".json", "")) or e["id"][:8]
        if e.get("type") in HV_TYPES and sid not in done:
            rows.append((sid, e.get("type"), e.get("project"), (e.get("title") or "")[:60]))
    print(f"pending high-value entries (not yet ingested): {len(rows)}")
    for sid, t, proj, title in rows[:60]:
        print(f"  {sid}  {t:16} {str(proj):10} {title}")


def cmd_apply(path, commit):
    proposals = json.load(open(path))
    if isinstance(proposals, dict):
        proposals = proposals.get("proposals", [])
    domains, informants, by_key, by_chash, _ = load_nexus()
    st = load_state()
    plan = {"new": [], "dup": [], "tap": [], "reject": []}
    seen, new_keys = set(), set()
    for p in proposals:
        ok, why = gate(p)
        if not ok:
            plan["reject"].append((p, why)); continue
        dom, key = p["proposed_domain"], p["key"]
        bk = (dom, key, chash(p["content"]))
        if bk in seen:
            continue
        seen.add(bk)
        if dom not in domains:
            plan["tap"].append((p, f"new domain '{dom}'")); continue
        if p["informant"] not in informants:
            plan["tap"].append((p, f"new informant '{p['informant']}'")); continue
        if (dom, chash(p["content"])) in by_chash:
            plan["dup"].append((p, by_chash[(dom, chash(p["content"]))])); continue
        if (dom, key) in by_key:
            plan["tap"].append((p, f"key '{key}' exists with different content -> supersede/contradiction")); continue
        if (dom, key) in new_keys:
            plan["tap"].append((p, f"key '{key}' duplicated across batches (different content)")); continue
        new_keys.add((dom, key))
        plan["new"].append(p)

    print(f"[{BACKEND.name}] proposals={len(proposals)}  NEW={len(plan['new'])}  DUP(merge)={len(plan['dup'])}  "
          f"TAP={len(plan['tap'])}  REJECT={len(plan['reject'])}")
    for p, why in plan["reject"]:
        print(f"  REJECT {p.get('proposed_domain', '?')}/{p.get('key', '?')}: {why}")
    for p, why in plan["tap"]:
        print(f"  TAP    {p['proposed_domain']}/{p['key']}: {why}")
    if not commit:
        print("\nDRY-RUN — nothing written. Re-run with --commit to apply NEW + DUP merges; TAP items get queued.")
        return

    keyid = {(dom, k): v["id"] for (dom, k), v in by_key.items()}
    keyglobal = {k: v["id"] for (dom, k), v in by_key.items()}
    dom_by_id = {v: k for k, v in domains.items()}

    def parent_of(dom, pk):
        return keyid.get((dom, pk)) or keyglobal.get(pk) if pk else None

    inserted = 0
    pending = list(plan["new"])
    for _ in range(10):
        ready, still = [], []
        for p in pending:
            pk, dom = p.get("parent_key"), p["proposed_domain"]
            (still if (pk and parent_of(dom, pk) is None) else ready).append(p)
        if not ready:
            break
        for i in range(0, len(ready), 100):
            chunk = ready[i:i + 100]
            rows = [{"domain_id": domains[p["proposed_domain"]],
                     "parent_id": parent_of(p["proposed_domain"], p.get("parent_key")),
                     "key": p["key"], "content": p["content"], "confidence": p["confidence"],
                     "salience": int(p["salience"]), "informant_id": informants[p["informant"]],
                     "evidence": p["evidence"], "created_by": "librarian"} for p in chunk]
            for r in BACKEND.insert_nodes(rows):
                slug = dom_by_id.get(r["domain_id"])
                keyid[(slug, r["key"])] = r["id"]; keyglobal[r["key"]] = r["id"]
                inserted += 1
        pending = still
        if not pending:
            break
    if pending:
        for p in pending:
            plan["tap"].append((p, f"parent_key '{p.get('parent_key')}' not found"))

    merged = 0
    for p, existing in plan["dup"]:
        BACKEND.merge_evidence(existing["id"], p["evidence"]); merged += 1

    if plan["tap"]:
        with open(TAP_QUEUE, "a") as f:
            for p, why in plan["tap"]:
                f.write(json.dumps({"ts": now_iso(), "reason": why, "proposal": p}) + "\n")

    ev = set()
    for p in proposals:
        for e in (p.get("evidence") or []):
            if isinstance(e, str) and SHORTID.match(e):
                ev.add(e)
    st["processed_entries"] = sorted(set(st.get("processed_entries", [])) | ev)
    st["last_run"] = now_iso()
    st["applied"] = st.get("applied", 0) + inserted
    st["tapped"] = st.get("tapped", 0) + len(plan["tap"])
    save_state(st)
    total = BACKEND.node_total()
    try:
        BACKEND.update_watermark(total)
    except Exception:
        pass
    print(f"\nCOMMITTED: inserted={inserted} new nodes  merged_evidence={merged}  tap_queued={len(plan['tap'])}")
    print(f"NEXUS nodes now: {total}  (ingested journal entries: {len(st['processed_entries'])})")


def cmd_prep(nbatches=12, outdir="/tmp/librarian"):
    os.makedirs(outdir, exist_ok=True)
    domains, informants, by_key, by_chash, nodes = load_nexus()
    done = set(load_state().get("processed_entries", []))
    doms = BACKEND.domains_named()
    C = ["# Librarian extraction — shared context", "",
         "You are the LIBRARIAN. From the journal entries in your batch file, extract durable, ATOMIC knowledge "
         "CLAIMS about the user as promotion-gate proposals. Curate what is durably KNOWN, not a log of events.", "",
         "## Domains — classify each claim into exactly ONE existing slug (do not invent domains)"]
    for d in doms:
        C.append(f"- `{d['slug']}` — {d['name']}")
    C += ["", "## Existing nodes — do NOT restate; add new/more-specific facts, or extend via parent_key"]
    cur = None
    for n in sorted(nodes, key=lambda x: (str(x["dom"]), x["key"])):
        if n["dom"] != cur:
            C.append(f"\n**{n['dom']}**"); cur = n["dom"]
        C.append(f"- `{n['key']}`: {n['content'][:140]}")
    C += ["", "## Rules",
          "- ATOMIC: one claim per node; use `parent_key` to nest under an existing key.",
          "- classify into the most specific existing domain slug; `key` lowercase-hyphenated, unique in domain.",
          "- `confidence`: observed|inferred|hypothesis. `salience` 1-5, honest (most 2-3).",
          "- `informant`: `scribe_journal`. `evidence`: array with the entry `_short_id`.",
          "- Do NOT extract corrections as positive nodes (extract the FIX). Skip ephemera. No personal data, no emojis.", "",
          "## Output", 'Write a JSON array to your out path: '
          '{"key","content","proposed_domain","informant":"scribe_journal","confidence","salience","evidence":["<short_id>"],"parent_key"(optional)}']
    open(os.path.join(outdir, "context.md"), "w").write("\n".join(C))
    entries = []
    for line in open(os.path.join(REPO, "journal.jsonl")):
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        if e.get("type") not in HV_TYPES:
            continue
        sid = (e.get("file", "").split("/")[-1].replace(".json", "")) or e["id"][:8]
        if sid in done:
            continue
        ef = os.path.join(REPO, "entries", sid + ".json")
        full = json.load(open(ef)) if os.path.isfile(ef) else e
        full["_short_id"] = sid
        entries.append(full)
    if not entries:
        print("nothing pending — NEXUS is current with the journal.")
        return
    nbatches = min(nbatches, len(entries))
    for i, b in enumerate([entries[j::nbatches] for j in range(nbatches)], 1):
        json.dump(b, open(os.path.join(outdir, f"in-{i:02d}.json"), "w"))
    print(f"prepped {len(entries)} pending entries -> {nbatches} batches in {outdir}/  (context: {outdir}/context.md)")
    print(f"NEXT: dispatch one extraction agent per in-NN.json (reads context.md + its batch -> out-NN.json), then librarian.py --apply <merged> --commit")


def main():
    global BACKEND
    BACKEND = select_backend()
    a = sys.argv[1:]
    if not a or a[0] == "--status":
        cmd_status()
    elif a[0] == "--init":
        cmd_init()
    elif a[0] == "--pending":
        cmd_pending()
    elif a[0] == "--prep":
        cmd_prep(int(a[1]) if len(a) > 1 and a[1].isdigit() else 12)
    elif a[0] == "--apply" and len(a) >= 2:
        cmd_apply(a[1], "--commit" in a)
    else:
        sys.exit("usage: librarian.py [--status | --init | --pending | --prep [N] | --apply <proposals.json> [--commit]]")


if __name__ == "__main__":
    main()
