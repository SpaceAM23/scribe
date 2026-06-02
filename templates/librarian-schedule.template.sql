-- NEXUS Librarian — scheduled cadence (spec section 3.8: pg_cron trigger)
-- A free, no-LLM scheduler: detects when enough high-value journal entries have
-- accumulated since the last ingest and records a "run due" signal. The actual
-- (cost-incurring) extraction stays agent-triggered on-demand/session-end.
-- Additive + RLS-private, like all nexus_ objects. Idempotent.

create extension if not exists pg_cron;

-- watermark: when the Librarian last ingested (kept current by librarian.py --apply)
create table if not exists nexus_librarian_state (
  id             int primary key default 1,
  last_ingest_at timestamptz,
  last_node_count int,
  updated_at     timestamptz default now(),
  constraint single_row check (id = 1)
);
insert into nexus_librarian_state (id, last_ingest_at, last_node_count)
  values (1, now(), (select count(*) from nexus_nodes))
  on conflict (id) do nothing;

-- due log: one row each time the scheduler decides a run is warranted
create table if not exists nexus_librarian_due (
  id           uuid primary key default gen_random_uuid(),
  detected_at  timestamptz default now(),
  pending_count int,
  acknowledged boolean default false,
  message      text
);

-- privacy: private from anyone but us (matches nexus_* policy)
alter table nexus_librarian_state enable row level security;
alter table nexus_librarian_state force  row level security;
alter table nexus_librarian_due   enable row level security;
alter table nexus_librarian_due   force  row level security;
revoke all on nexus_librarian_state from anon, authenticated, public;
revoke all on nexus_librarian_due   from anon, authenticated, public;

-- the check: count high-value entries since the watermark; if >= threshold and no
-- unacknowledged signal in the last 3 days, log a due signal. SECURITY DEFINER so
-- the scheduled run can read journal_entries + write the signal under RLS.
create or replace function librarian_check_due(threshold int default 10)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  wm      timestamptz;
  pending int;
  recent  int;
begin
  select last_ingest_at into wm from nexus_librarian_state where id = 1;
  wm := coalesce(wm, 'epoch'::timestamptz);
  select count(*) into pending from journal_entries
   where type in ('decision_made','learning','feature_shipped','milestone',
                  'reflection','process_created','tool_discovered')
     and timestamp > wm;
  select count(*) into recent from nexus_librarian_due
   where not acknowledged and detected_at > now() - interval '3 days';
  if pending >= threshold and recent = 0 then
    insert into nexus_librarian_due (pending_count, message)
      values (pending, format('Librarian run due: %s high-value journal entries pending since last ingest', pending));
  end if;
  return pending;
end;
$$;

-- schedule: daily at 09:00 UTC (idempotent — unschedule any prior by jobid, then schedule)
select cron.unschedule(jobid) from cron.job where jobname = 'librarian-due-check';
select cron.schedule('librarian-due-check', '0 9 * * *', 'select librarian_check_due(10)');
