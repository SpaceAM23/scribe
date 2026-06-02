#!/usr/bin/env python3
"""
librarian.py — the Librarian apply-engine (NEXUS phase 2: the mind that grows itself).

The extraction (reading journal entries and proposing knowledge claims) is done by
librarian agents driven by core/librarian-prompt.md. THIS engine is the governed,
deterministic half: it takes their gated proposals and curates them into NEXUS.

Promotion gate (spec section 6.4):
  {key, content, proposed_domain, informant, confidence, salience, evidence[], parent_key?}

Per proposal:  gate-validate -> reconcile -> apply
  reconcile outcomes (librarian-prompt section 3):
    NEW          content not shelved, domain exists      -> insert (auto-safe: filing into an existing domain)
    DUPLICATE    same content already shelved            -> merge evidence into the existing node (auto-safe)
    SUPERSEDE/   same key, different content              -> TAP (judgment; queued for Apollo)
    CONTRADICT
  gate TAPs:    new domain / new informant               -> TAP (autonomy rule section 3.4: structural = tap)
  gate REJECT:  missing provenance / bad enum / no domain match handled above

Auto-safe writes apply immediately; risky items go to librarian-tap-queue.jsonl for one-tap review.
Idempotent: content-hash dedup means re-running the same proposals merges evidence, never duplicates.
Dry-run by default; --commit writes. Provenance (informant + evidence) is mandatory — the gate rejects unsourced claims.

Modes:
  --status                    NEXUS counts + watermark + tap-queue size
  --pending                   journal entries not yet ingested (extraction candidates), high-value types
  --apply <proposals.json>    reconcile + dry-run report; add --commit to write

Run: set SUPABASE_ACCESS_TOKEN + SUPABASE_PROJECT_REF (or config.json storage.supabase.url).
"""
import json, os, re, sys, time, hashlib, datetime, urllib.request, urllib.error


def _data_path():
    """Resolve the Scribe data dir like writer.sh: SCRIBE_DATA_PATH > pointer.json > default."""
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


def _project_ref(data_dir):
    """Supabase project ref from SUPABASE_PROJECT_REF or config.json storage.supabase (project_ref/url)."""
    r = os.environ.get("SUPABASE_PROJECT_REF")
    if r:
        return r
    cfg = os.path.join(data_dir, "config.json")
    if os.path.isfile(cfg):
        try:
            sb = (json.load(open(cfg)).get("storage", {}) or {}).get("supabase", {}) or {}
            if sb.get("project_ref"):
                return sb["project_ref"]
            m = re.search(r"https?://([a-z0-9]+)\.supabase\.co", sb.get("url", ""))
            if m:
                return m.group(1)
        except Exception:
            pass
    return ""


REPO = _data_path()
REF = _project_ref(REPO)
TOKEN = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
URL = f"https://api.supabase.com/v1/projects/{REF}/database/query"
STATE = os.path.join(REPO, "librarian-state.json")
TAP_QUEUE = os.path.join(REPO, "librarian-tap-queue.jsonl")
CONF_OK = {"observed", "inferred", "hypothesis"}
# high-density durable-claim types (librarian-prompt section 6)
HV_TYPES = {"decision_made", "learning", "feature_shipped", "milestone",
            "reflection", "process_created", "tool_discovered"}
SHORTID = re.compile(r"^[0-9a-f]{8}$")


def q(sql, _tries=6):
    body = json.dumps({"query": sql}).encode()
    for attempt in range(_tries):
        req = urllib.request.Request(URL, data=body, headers={
            "Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json", "User-Agent": "librarian/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as ex:
            if ex.code == 429 and attempt < _tries - 1:
                time.sleep(2 ** attempt)            # backoff: 1,2,4,8,16s on management-API throttle
                continue
            raise RuntimeError(f"HTTP {ex.code}: {ex.read().decode()[:300]}\nSQL: {sql[:120]}")


def esc(s):
    return str(s).replace("'", "''")


def norm(s):
    return re.sub(r"\s+", " ", (s or "").strip().lower())


def chash(s):
    return hashlib.sha256(norm(s).encode()).hexdigest()[:16]


def load_state():
    if os.path.isfile(STATE):
        return json.load(open(STATE))
    return {"watermark": None, "processed_entries": [], "last_run": None, "applied": 0, "tapped": 0}


def save_state(st):
    json.dump(st, open(STATE, "w"), indent=2)


def load_nexus():
    domains = {d["slug"]: d["id"] for d in q("select slug,id from nexus_domains")}
    informants = {i["slug"]: i["id"] for i in q("select slug,id from nexus_informants")}
    nodes = q("select n.id, d.slug dom, n.key, n.content from nexus_nodes n "
              "join nexus_domains d on d.id=n.domain_id where n.status='active'")
    by_key = {(n["dom"], n["key"]): n for n in nodes}
    by_chash = {(n["dom"], chash(n["content"])): n for n in nodes}
    return domains, informants, by_key, by_chash, nodes


def gate(p):
    """Validate a proposal against the promotion gate. Returns (ok, reason)."""
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


def cmd_status():
    domains, informants, by_key, by_chash, nodes = load_nexus()
    st = load_state()
    tap = sum(1 for _ in open(TAP_QUEUE)) if os.path.isfile(TAP_QUEUE) else 0
    print(f"NEXUS: {len(nodes)} active nodes across {len(domains)} domains, {len(informants)} informants")
    for r in q("select d.slug, count(*) c from nexus_nodes n join nexus_domains d on d.id=n.domain_id "
               "where n.status='active' group by d.slug order by c desc"):
        print(f"  {r['slug']:16} {r['c']}")
    print(f"watermark last_run: {st.get('last_run')}  ingested_entries: {len(st.get('processed_entries', []))}  "
          f"applied_total: {st.get('applied', 0)}  tap_queue: {tap}")
    try:                                              # pg_cron scheduler signal (optional)
        due = q("select pending_count, detected_at::text d from nexus_librarian_due "
                "where not acknowledged order by detected_at desc limit 1")
        if due:
            print(f"  RUN DUE — scheduler flagged {due[0]['pending_count']} pending entries "
                  f"at {due[0]['d'][:16]} (run: librarian.py --prep)")
    except Exception:
        pass


def cmd_pending():
    st = load_state()
    done = set(st.get("processed_entries", []))
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
        print(f"  {sid}  {t:16} {proj:10} {title}")


def cmd_apply(path, commit):
    proposals = json.load(open(path))
    if isinstance(proposals, dict):
        proposals = proposals.get("proposals", [])
    domains, informants, by_key, by_chash, _ = load_nexus()
    st = load_state()
    plan = {"new": [], "dup": [], "tap": [], "reject": []}
    seen = set()
    new_keys = set()
    for p in proposals:
        ok, why = gate(p)
        if not ok:
            plan["reject"].append((p, why)); continue
        dom, key = p["proposed_domain"], p["key"]
        bk = (dom, key, chash(p["content"]))
        if bk in seen:
            continue                                  # intra-batch dup (two agents, same claim)
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

    print(f"proposals={len(proposals)}  NEW={len(plan['new'])}  DUP(merge-evidence)={len(plan['dup'])}  "
          f"TAP={len(plan['tap'])}  REJECT={len(plan['reject'])}")
    for p, why in plan["reject"]:
        print(f"  REJECT {p.get('proposed_domain', '?')}/{p.get('key', '?')}: {why}")
    for p, why in plan["tap"]:
        print(f"  TAP    {p['proposed_domain']}/{p['key']}: {why}")

    if not commit:
        print("\nDRY-RUN — nothing written. Re-run with --commit to apply NEW + DUP merges; TAP items get queued.")
        return

    keyid = {(dom, k): v["id"] for (dom, k), v in by_key.items()}
    keyglobal = {k: v["id"] for (dom, k), v in by_key.items()}   # cross-domain parent fallback
    dom_by_id = {v: k for k, v in domains.items()}

    def parent_of(dom, pk):                           # parent_id is valid cross-domain (schema)
        return keyid.get((dom, pk)) or keyglobal.get(pk) if pk else None

    inserted = 0
    pending = list(plan["new"])
    for _ in range(10):                               # depth passes for parent_key chains
        ready, still = [], []
        for p in pending:
            pk, dom = p.get("parent_key"), p["proposed_domain"]
            (still if (pk and parent_of(dom, pk) is None) else ready).append(p)
        if not ready:
            break                                     # remaining have unresolvable parents
        for i in range(0, len(ready), 100):           # chunk to keep payloads + rate sane
            chunk = ready[i:i + 100]
            rows = [{"domain_id": domains[p["proposed_domain"]],
                     "parent_id": parent_of(p["proposed_domain"], p.get("parent_key")),
                     "key": p["key"], "content": p["content"], "confidence": p["confidence"],
                     "salience": int(p["salience"]), "informant_id": informants[p["informant"]],
                     "evidence": p["evidence"], "created_by": "librarian"} for p in chunk]
            res = q("insert into nexus_nodes (domain_id,parent_id,key,content,confidence,salience,informant_id,evidence,created_by) "
                    "select (v->>'domain_id')::uuid, nullif(v->>'parent_id','')::uuid, v->>'key', v->>'content', "
                    "v->>'confidence', (v->>'salience')::int, (v->>'informant_id')::uuid, (v->'evidence')::jsonb, v->>'created_by' "
                    f"from jsonb_array_elements('{esc(json.dumps(rows))}'::jsonb) v returning id, key, domain_id")
            for r in res:
                slug = dom_by_id[r["domain_id"]]
                keyid[(slug, r["key"])] = r["id"]; keyglobal[r["key"]] = r["id"]
            inserted += len(res)
        pending = still
        if not pending:
            break
    if pending:
        for p in pending:                             # parent never resolved -> TAP rather than orphan
            plan["tap"].append((p, f"parent_key '{p.get('parent_key')}' not found"))

    merged = 0
    for p, existing in plan["dup"]:
        addition = esc(json.dumps(p["evidence"]))
        q("update nexus_nodes set evidence = (select jsonb_agg(distinct e) "
          f"from jsonb_array_elements(evidence || '{addition}'::jsonb) e), updated_at=now() where id='{existing['id']}'")
        merged += 1

    now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    if plan["tap"]:
        with open(TAP_QUEUE, "a") as f:
            for p, why in plan["tap"]:
                f.write(json.dumps({"ts": now, "reason": why, "proposal": p}) + "\n")

    ev = set()
    for p in proposals:
        for e in (p.get("evidence") or []):
            if isinstance(e, str) and SHORTID.match(e):
                ev.add(e)
    st["processed_entries"] = sorted(set(st.get("processed_entries", [])) | ev)
    st["last_run"] = now
    st["applied"] = st.get("applied", 0) + inserted
    st["tapped"] = st.get("tapped", 0) + len(plan["tap"])
    save_state(st)
    total = q("select count(*) c from nexus_nodes")[0]["c"]
    # keep the pg_cron scheduler's watermark current + clear any outstanding "run due" signal
    try:
        q(f"update nexus_librarian_state set last_ingest_at=now(), last_node_count={total}, updated_at=now() where id=1")
        q("update nexus_librarian_due set acknowledged=true where not acknowledged")
    except Exception:
        pass                                          # scheduler not installed (optional) — ignore
    print(f"\nCOMMITTED: inserted={inserted} new nodes  merged_evidence={merged}  tap_queued={len(plan['tap'])}")
    print(f"NEXUS nodes now: {total}  (ingested journal entries: {len(st['processed_entries'])})")


def cmd_prep(nbatches=12, outdir="/tmp/librarian"):
    """Build extraction batches + shared context for the Librarian agents (the repeatable cycle).
    NEXT after prep: dispatch one extraction agent per in-NN.json, then --apply the merged proposals."""
    os.makedirs(outdir, exist_ok=True)
    domains, informants, by_key, by_chash, nodes = load_nexus()
    done = set(load_state().get("processed_entries", []))
    doms = q("select slug,name from nexus_domains order by slug")
    C = ["# Librarian extraction — shared context", "",
         "You are the LIBRARIAN. From the journal entries in your batch file, extract durable, ATOMIC knowledge "
         "CLAIMS about the user as promotion-gate proposals. Curate what is durably KNOWN, not a log of events.", "",
         "## Domains — classify each claim into exactly ONE existing slug (do not invent domains)"]
    for d in doms:
        C.append(f"- `{d['slug']}` — {d['name']}")
    C += ["", "## Existing nodes — do NOT restate; add new/more-specific facts, or extend via parent_key"]
    cur = None
    for n in sorted(nodes, key=lambda x: (x["dom"], x["key"])):
        if n["dom"] != cur:
            C.append(f"\n**{n['dom']}**"); cur = n["dom"]
        C.append(f"- `{n['key']}`: {n['content'][:140]}")
    C += ["", "## Rules",
          "- ATOMIC: one claim per node; use `parent_key` to nest under an existing key.",
          "- classify into the most specific existing domain slug; `key` lowercase-hyphenated, unique in domain.",
          "- `confidence`: observed|inferred|hypothesis. `salience` 1-5, honest (most 2-3).",
          "- `informant`: always `scribe_journal`. `evidence`: array with the entry `_short_id`.",
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
    batches = [entries[i::nbatches] for i in range(nbatches)]
    for i, b in enumerate(batches, 1):
        json.dump(b, open(os.path.join(outdir, f"in-{i:02d}.json"), "w"))
    print(f"prepped {len(entries)} pending entries -> {nbatches} batches in {outdir}/")
    print(f"context: {outdir}/context.md")
    print(f"NEXT: dispatch one librarian extraction agent per {outdir}/in-NN.json "
          f"(reads context.md + its batch, writes {outdir}/out-NN.json), then: "
          f"librarian.py --apply <merged> --commit")


def main():
    if not TOKEN:
        sys.exit("ERROR: SUPABASE_ACCESS_TOKEN not set")
    if not REF:
        sys.exit("ERROR: Supabase project ref not configured (set SUPABASE_PROJECT_REF or config.json storage.supabase.url)")
    a = sys.argv[1:]
    if not a or a[0] == "--status":
        cmd_status()
    elif a[0] == "--pending":
        cmd_pending()
    elif a[0] == "--prep":
        cmd_prep(int(a[1]) if len(a) > 1 and a[1].isdigit() else 12)
    elif a[0] == "--apply" and len(a) >= 2:
        cmd_apply(a[1], "--commit" in a)
    else:
        sys.exit("usage: librarian.py [--status | --pending | --prep [N] | --apply <proposals.json> [--commit]]")


if __name__ == "__main__":
    main()
