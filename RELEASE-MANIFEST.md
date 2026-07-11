# Release Manifest — Scribe 0.2.0

**Date:** 2026-07-01
**Version:** 0.1.0 → **0.2.0** (largest update since inception: write path, read path, and taxonomy rebuilt around no-data-loss; still pre-1.0, so a minor bump)
**Source:** ported from the live instance overhaul (paths, defaults, and identifying content generalized for the public layout: `core/` engine + pointer-resolved data dir).

## Files Added

| File | Reason |
|---|---|
| `core/track-corrections.py` | Vocabulary-driven correction tracker; entry piped over stdin (kills the inline-heredoc crash/code-exec vector); atomic tracker writes; regression re-escalation. Ported verbatim (no instance refs). |
| `core/doctor.py` | Derived-state doctor: rebuilds seen-hashes.txt with the exact writer hash recipe, recomputes index.json, validates/repairs entry ids; `--fix` runs under the writer lock and aborts on live-journal drift. De-Apollo'd: data-dir resolution now `--data-dir > $SCRIBE_DATA_PATH > pointer.json > ~/Desktop/Scribe`; repair log moved from `DATA_DIR/scripts/` to the data-dir root. |
| `core/brief.py` | The read path: per-project 60-line session briefs (LANDMINES/KNOWLEDGE/RECENT/OPEN THREADS/meta budget) + `_portfolio.md` rollup with taxonomy suggestions and doctor status. De-Apollo'd: pointer.json resolution added, `~/Desktop/Scribe` default, project-name examples in docstrings genericized, `scripts/` → `core/` path references. |
| `core/taxonomy.py` | Deliberate category minting (projects/types/correction patterns) + suggestion triage/resolution. De-Apollo'd: docstring quote and default path; `add-type` now seeds `DATA_DIR/schema.json` from `core/schema.json` when absent (public two-location layout); `add-project` creates the registry (seeded with `meta`) on first mint. |
| `templates/correction-patterns.template.json` | The 10-pattern controlled vocabulary (generic and valuable), installed to `DATA_DIR/canonical/`. Scrubbed: `voice-drift` definition de-Apollo'd; matchers naming Apollo/Bilal generalized to user/reviewer/teammate; brand-vocabulary matchers (`of-service`, `\bsoul\b`) removed; `act-before-research` definition no longer references the private Research Gate skill; calibration note genericized (no corpus specifics). |
| `templates/projects.template.json` | Empty-projects canonical registry template with a documented example. Empty `projects[]` = open mode (accept anything); first mint switches enforcement on. |
| `templates/.env.example` | The only place Supabase credentials are referenced: `SCRIBE_DB_PASSWORD` / `PGPASSWORD` / `PGCONNECT_TIMEOUT` / `SCRIBE_DATA_PATH`, all empty placeholders. |
| `tests/test_concurrent_writers.sh` | 10 parallel writers: all exit 0, exactly 10 journal lines, index total matches, ids unique, no torn JSON. Adapted to `core/writer.sh` + template-seeded scratch dir; instance mktemp path (`/Users/apollo/...`) replaced with `${TMPDIR:-/tmp}`. |
| `tests/test_tracker_hostile_input.sh` | Hostile correction text (escaped quotes, newlines, triple-quotes) survives writer + tracker losslessly. Same adaptations. |
| `tests/test_nexus_privacy.sh` | Anon-key-cannot-read-nexus proof with the fixed patterns (bash-3.2-safe `set +e` env sourcing, awk last-line helpers, 401-or-empty-array logic, 404 handling). Fully parameterized: project ref/anon key from env or config.json; SKIPs when unconfigured. Apollo's hardcoded project ref, `~/.apollo/.env`, and instance-specific seed-count test dropped. |
| `RELEASE-MANIFEST.md` | This file. |

## Files Changed

| File | Reason |
|---|---|
| `core/writer.sh` | Full port of the overhauled writer into the public conventions: mkdir writer lock with pid-owned stale-lock stealing (atomic rename-aside), UTF-8 `LC_ALL` pin (with locale-availability fallback chain) so cron and interactive hashes agree, post-append content-hash recording (crash-safe direction), jq-escaped normalization/duplicate logs (full entry payload preserved on duplicates), canonical/projects.json validation (normalize-to-meta, never reject; empty registry = open mode), taxonomy suggestion queue, atomic index.json writes with corrupt-quarantine, per-correction counting, tracker delegated to `core/track-corrections.py`, `PGCONNECT_TIMEOUT` bound on Supabase writes, post-write `core/brief.py` hook with `--data-dir`, `essence` core type. De-Apollo'd: no hardcoded Supabase fallback connection, no `jab-innovations` alias, no `apollo` default user_id (defaults to config.json owner, else `unknown`), default data dir `~/Desktop/Scribe`, error-log fallback `/tmp/scribe-errors.jsonl`. Kept the public repo's generalized `enforce_enum()` helper and DATA_DIR-schema-precedence resolution. |
| `core/reconcile.sh` | Hardened sync replay ported: dead-letter queue (`sync-dead-letter.jsonl`) for unparseable lines / permanent psql errors / max-attempts (5), `_sync_attempts`/`_last_error` bookkeeping stripped before send, SIGTERM/SIGINT-safe temp-file cleanup traps, queue snapshot + hardlink swap-guard + post-swap recovery so concurrent writer appends are never dropped, `ON_ERROR_STOP=1`, remote-count sanitization under `set -u`. De-Apollo'd: hardcoded fallback connection removed (errors if unconfigured), default `~/Desktop/Scribe`, "tap review" wording → "manual review". |
| `core/schema.json` | v1 → v2: `essence` type, `unspecified` enum values (complexity/autonomy/drive_state/energy/cognitive_load), `behavioral.professional_development` block, `behavioral.additionalProperties: true`, `user_id` no longer hard-required (writer defaults it). Scrubbed: Apollo's verbatim phrases removed from `language_markers` examples. |
| `scripts/install.sh` | Creates `briefs/` and `canonical/` in the data dir; seeds `canonical/correction-patterns.json` and `canonical/projects.json` (open mode) from templates without overwriting; correction-tracker init matches the new shape (`schema_version`/`last_updated`); Supabase step points at `templates/.env.example` and the full SQL file. |
| `adapters/claude-web/supabase-setup.sql` | `essence` added to the `type` CHECK constraint + note that `taxonomy.py add-type` requires updating the constraint. |
| `.gitignore` | New runtime/derived artifacts ignored: `briefs/`, `canonical/`, sync queues, dead-letter, seen-hashes, duplicates/normalizations/errors logs, taxonomy suggestions, doctor repair logs, `.writer.lock/`, backups (`*.bak-*`, `*.corrupt-*`), `handoff.md`, `nexus.json`, `team-config.json`, `correction-tracker.json`. |
| `VERSION` | 0.1.0 → 0.2.0. |
| `templates/config.template.json` | `scribe_version` → 0.2.0. |
| `README.md` | "What's New in 0.2.0" section (briefs read path, concurrency-safe writer, doctor, taxonomy minting, hardened sync, vocabulary tracker, schema v2, tests); architecture tree updated for the new core files and data-dir layout. |
| `DESIGN.md` | §2.1 data layout updated (canonical/, briefs/, queues, derived-state note); §2.2 core listing updated; §2.3 pipeline rewritten (lock, door repairs, dedup ordering, queueing, brief hook) + new §2.3b Doctor, §2.3c Session Briefs, §2.3d Taxonomy; §7.1 rewritten for the controlled vocabulary (no more auto-minted slugs). |

## Files Removed

None.

## Secret Scan

Scanned the full staged tree for: `PGPASSWORD`, `postgres://`, `sk-ant`, `eyJ` (JWT prefix), `*.supabase.co` project refs, the instance project ref, `Apollo`, `ninaancharski`, `.apollo` paths, and client names (CLB, NatureJab, Blackfin, M&B, JAB, Julian, Shawn, Bilal).

**Result: zero credentials, zero instance identifiers.** No connection strings, keys, tokens, JWTs, or Supabase project refs anywhere. Residual hits, each justified:

- `PGPASSWORD` — env-var *name* only, in the code that reads it (`core/writer.sh`, `core/reconcile.sh`) and as an empty placeholder in `templates/.env.example`. Required functionality.
- `Apollo Mondesir / Rocksteady Consulting` — author attribution in `LICENSE`, `README.md`, `DESIGN.md` header, MCP `package.json`, install banner. Intentional.
- Apollo/Shawn/Bilal/Julian + blackfin/naturejab/awg-wms in `DESIGN.md` §10, command docs (`scribe-list/inbox/share/import/errors`), `core/intake-scan.md`, `adapters/claude-web/project-instructions.md`, `README.md` packet example — pre-existing 0.1.0 illustrative documentation examples, already public in this repo; unchanged by this release (no data, no credentials). Flagged for a future docs pass if the examples should be fictionalized.
- `team_rocksteady` / "Team Rocksteady" in `core/librarian.py`, `scripts/team-sync.py`, `TEAM-PARTITION.md`, `templates/team-config.template.json` ("e.g. mason") — pre-existing team-partition feature shipped in an earlier commit; the vendor's own deployment is the documented reference. No credentials.
- `/Users/username/Desktop/Scribe` in the MCP adapter docs — generic placeholder.

## Tests Run

Environment: macOS, `/bin/bash 3.2.57`, scratch data dirs via `SCRIBE_DATA_PATH` (real data never touched). All against the PUBLIC layout (`core/writer.sh`, template-seeded `canonical/`).

| Test | Result |
|---|---|
| `bash -n` on all shell scripts; `py_compile` on all 4 core Python tools; `jq empty` on all shipped JSON | PASS |
| `tests/test_concurrent_writers.sh` (10 parallel writers) | PASS (4/4 cases) |
| `tests/test_tracker_hostile_input.sh` | PASS (4/4 cases) |
| `tests/test_nexus_privacy.sh` | SKIP as designed (no Supabase configured in scratch); network paths not exercisable here |
| Smoke: alias resolution (`MyApp`→`my-app`), unknown project→`meta` + suggestion queued, unknown type→`milestone` + suggestion queued, duplicate refused with full payload preserved, briefs regenerated per write | PASS |
| Smoke: `taxonomy.py suggestions` → `add-project` (with alias, auto-resolves suggestion) → `add-type` (seeds DATA_DIR schema from core) → suggestions cleared | PASS |
| Smoke: `doctor.py --check` clean journal (exit 0) → corrupted journal (uppercase id, duplicate id, blank line, deleted seen-hashes) detected (exit 1) → `--fix` repaired with logged repairs → re-check exit 0 | PASS |
| Supabase write/queue/reconcile against a live database | NOT RUN (no credentials in this environment by design); queue/dead-letter logic is exercised only by code review + the instance's production use |

## Deliberately NOT Ported

- **All instance data**: journal/entries/index/briefs/correction-tracker/handoff/nexus.json/NEXUS renders/librarian state/.env/sync queues/seen-hashes/normalizations/duplicates/errors/backups/quarantine/`_retired`/`_backup-*`. Data never ships.
- **`canonical/projects.json` contents** — replaced by the empty template; Apollo's 13 projects and 23 aliases are data.
- **`scripts/backfill.sh`, `reconcile-ids.py`, `reconcile-worksheet.py`, `lowercase-ids.py`, `heal-trend`/`heal` updates, `sync-targets.py`** — instance migration/one-shot tooling written against Apollo's journal history; `doctor.py` supersedes the id/derived-state repairs generically. Not in scope per the port list.
- **`nexus-*.py` scripts, `NEXUS-apollo-mind.md`, nexus/ renders** — the instance knowledge-graph build-out; the public product already has its own Librarian/NEXUS layer (`core/librarian.py`, `templates/nexus-schema.template.sql`). Only the privacy *test pattern* was ported.
- **Instance `config.json`/`tuning.json`/`error-handler` errors log** — data/config.
- **Instance writer's no-config Supabase fallback block** — was Apollo's connection string; the public writer requires config.
- **`tests/test_backfill_dryrun.sh`, `test_dedup.sh`, `test_enum_enforcement.sh`, `test_project_taxonomy.sh`, `test_sync_queue.sh`, `test_heal.py`, `test_trend.py`** — not in the requested port list; several target instance-only tooling (backfill) or predate the overhaul. Candidates for a follow-up test-suite port.
- **Claude Desktop MCP adapter update for schema v2** (`essence` type awareness in `index.ts`) — the adapter validates loosely and continues to work; noting as follow-up rather than making untested TypeScript changes.

## Addendum — 2026-07-11

- `core/writer.sh` section 20: post-write **doctor `--check`** hook (parity with the live instance). Read-only integrity verification on every write — silent when clean, one-line nudge on drift; repairs stay a deliberate human `--fix`. Without this, `doctor.py` shipped but never ran. Validated: `bash -n` clean, `tests/test_concurrent_writers.sh` ALL PASS.
