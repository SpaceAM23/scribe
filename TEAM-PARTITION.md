# Team partition — shared Scribe/NEXUS on one Supabase, isolated per person

A team can share **one** Supabase project while each member writes to **only their own partition** — no member can read or write anyone else's rows, and the owner's private data stays separate. This is how Rocksteady runs it.

## How it works
- A dedicated schema (e.g. `team_rocksteady`) holds the multi-tenant tables: `scribe_journal`, `nexus_*`, `librarian_*`, each with an `owner` column.
- **RLS** scopes every read/write to `owner = your JWT's owner claim`. The owner mints each member a personal, scoped JWT (authenticated role — never service-role).
- You keep journaling **locally** as always; `team-sync.py` pushes your local journal up to your partition through your JWT.

## Setup (per member)
1. Pull the latest product: `cd "$HOME/scribe-product" && git pull origin main`.
2. Create `team-config.json` in your Scribe data dir from `templates/team-config.template.json`:
   ```json
   { "url": "https://<ref>.supabase.co", "anon_key": "<team anon key>",
     "jwt": "<your personal team JWT>", "owner": "<your id>" }
   ```
   (The owner sends you the `url`, `jwt`, and `owner` privately.)
3. Sync: `python3 scripts/team-sync.py` — pushes any new local entries to your partition. Idempotent; run it on-demand or at session end.

## Guarantees
- You can write **only** your own `owner` rows (RLS `with check`). Trying to write as someone else is rejected.
- You **cannot** read other members' partitions or the owner's private schema.
- The owner (service role) sees everything for oversight; rotation is a re-mint with a new secret if a JWT ever leaks.

The NEXUS/Librarian tables exist in the same partition for when your mind-building runs against the shared backend; until then your journal sync is the live path.
