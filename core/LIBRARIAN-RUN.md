# Running the Librarian (NEXUS phase 2)

The **Observer** (writer) records what happened. The **Librarian** curates what is durably *known* into **NEXUS** — a private knowledge graph that grows from the journal instead of being hand-maintained.

## Setup (once)
1. Apply the NEXUS schema to your Supabase project: `templates/nexus-schema.template.sql` (creates the RLS-private `nexus_*` tables; seed your domains + informants).
2. Configure access for the engine:
   - `SUPABASE_ACCESS_TOKEN` — a Supabase Management API token (env).
   - Project ref — `SUPABASE_PROJECT_REF` env, or `config.json` → `storage.supabase.url`.
3. (Optional) Install the scheduled cadence: apply `templates/librarian-schedule.template.sql` (needs `pg_cron`) — a free, no-LLM daily job that flags when a run is due.

## The cycle (on-demand / session-end)
Two deterministic engine steps around one agent step:
```
core/librarian.py --prep             # bundle pending high-value journal entries + write the shared context
   -> dispatch one extraction agent per batch (driven by core/librarian-prompt.md):
      each reads the context + its batch and writes gate proposals to out-NN.json
core/librarian.py --apply <merged out-*.json> --commit
```
`--apply` runs the promotion gate and reconciliation: **NEW** facts file into an existing domain (auto-safe), **DUPLICATE** content merges evidence (auto-safe), and **supersede / contradiction / new-domain / new-informant** go to `librarian-tap-queue.jsonl` for the user's one-tap review. Run without `--commit` first for a dry-run.

## Modes
- `--status` — node counts per domain, watermark, TAP-queue size, and any scheduler "RUN DUE" signal.
- `--pending` — high-value journal entries not yet ingested.

## Governance (anti-Babel)
- **Promotion gate:** every node needs `{content, proposed_domain, informant, confidence, salience, evidence[]}`. No provenance -> rejected.
- **Auto vs TAP:** filing into an existing domain + merging duplicate evidence apply automatically; anything structural or contradictory waits for the user.
- **Privacy:** `nexus_*` uses FORCE RLS with no anon/authenticated grant — private by default.
- **Provenance:** every node carries its informant + the source entry id (bidirectional traceability).

## Scheduled cadence (optional)
`librarian-schedule.template.sql` installs a `pg_cron` job that counts high-value entries since the last ingest and logs a "run due" signal when a threshold is crossed (deduped). It does **not** run the LLM extraction (that stays agent-triggered to control cost) — it just tells you when a run is worthwhile. `--apply` keeps the scheduler's watermark current; `--status` surfaces the signal.
