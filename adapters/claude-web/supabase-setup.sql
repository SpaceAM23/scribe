-- Scribe -- Supabase Backup Schema
-- Run this in your Supabase SQL Editor to set up the journal_entries table.
-- This is an optional backup target for Claude Web App users.
-- Google Drive remains the primary source of truth.

-- =============================================================================
-- Table: journal_entries
-- =============================================================================

CREATE TABLE journal_entries (
  id UUID PRIMARY KEY,
  timestamp TIMESTAMPTZ NOT NULL,
  session_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  project TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN (
    'session_open',
    'feature_shipped',
    'bug_fixed',
    'decision_made',
    'learning',
    'correction',
    'process_created',
    'tool_discovered',
    'feedback_received',
    'milestone',
    'reflection',
    'essence'
  )),
  -- NOTE: if you mint a new type with core/taxonomy.py add-type, this CHECK
  -- constraint must be updated too (add-type prints the SQL to run). Until
  -- then, remote inserts of the new type fail and sit in sync-queue.jsonl;
  -- core/reconcile.sh replays them once the constraint is fixed.
  title TEXT NOT NULL CHECK (char_length(title) <= 120),
  summary TEXT NOT NULL,
  decisions JSONB DEFAULT '[]'::jsonb,
  learnings JSONB DEFAULT '[]'::jsonb,
  corrections JSONB DEFAULT '[]'::jsonb,
  metrics JSONB DEFAULT '{}'::jsonb,
  connections JSONB DEFAULT '{}'::jsonb,
  growth JSONB DEFAULT '{}'::jsonb,
  behavioral JSONB DEFAULT '{}'::jsonb,
  learning_story JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add a comment for documentation
COMMENT ON TABLE journal_entries IS 'Scribe session journal entries. Backup target for web users; primary storage is Google Drive.';

-- =============================================================================
-- Indexes for common query patterns
-- =============================================================================

-- Filter by project
CREATE INDEX idx_journal_project ON journal_entries (project);

-- Filter by entry type
CREATE INDEX idx_journal_type ON journal_entries (type);

-- Filter by user (required for RLS and multi-user scenarios)
CREATE INDEX idx_journal_user ON journal_entries (user_id);

-- Sort by timestamp (most recent first)
CREATE INDEX idx_journal_timestamp ON journal_entries (timestamp DESC);

-- Filter by session
CREATE INDEX idx_journal_session ON journal_entries (session_id);

-- Composite: user + project (common query path)
CREATE INDEX idx_journal_user_project ON journal_entries (user_id, project);

-- =============================================================================
-- Row Level Security (RLS)
-- =============================================================================
-- Ensures each user can only read and write their own entries.
-- Required when multiple users share the same Supabase project.

ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;

-- Users can read their own entries only.
-- The user_id in the entry must match the 'scribe_user_id' claim in the JWT,
-- or -- for anon key access -- the user_id passed as a request header.
-- For simplicity with anon key usage, this policy uses a request header approach:
-- the client sets x-scribe-user-id in the request headers.

-- Policy: SELECT -- users read their own entries
CREATE POLICY "Users can read own entries"
  ON journal_entries
  FOR SELECT
  USING (
    user_id = current_setting('request.headers', true)::json->>'x-scribe-user-id'
    OR user_id = (auth.jwt()->>'scribe_user_id')
  );

-- Policy: INSERT -- users create entries with their own user_id
CREATE POLICY "Users can insert own entries"
  ON journal_entries
  FOR INSERT
  WITH CHECK (
    user_id = current_setting('request.headers', true)::json->>'x-scribe-user-id'
    OR user_id = (auth.jwt()->>'scribe_user_id')
  );

-- Policy: UPDATE -- users update their own entries only
CREATE POLICY "Users can update own entries"
  ON journal_entries
  FOR UPDATE
  USING (
    user_id = current_setting('request.headers', true)::json->>'x-scribe-user-id'
    OR user_id = (auth.jwt()->>'scribe_user_id')
  );

-- Policy: DELETE -- users delete their own entries only
CREATE POLICY "Users can delete own entries"
  ON journal_entries
  FOR DELETE
  USING (
    user_id = current_setting('request.headers', true)::json->>'x-scribe-user-id'
    OR user_id = (auth.jwt()->>'scribe_user_id')
  );

-- =============================================================================
-- Alternative: Simple anon-key policy (single user, no auth)
-- =============================================================================
-- If you are the only user and do not need RLS isolation, you can replace
-- the policies above with a single permissive policy. Uncomment below and
-- drop the policies above if desired.
--
-- DROP POLICY "Users can read own entries" ON journal_entries;
-- DROP POLICY "Users can insert own entries" ON journal_entries;
-- DROP POLICY "Users can update own entries" ON journal_entries;
-- DROP POLICY "Users can delete own entries" ON journal_entries;
--
-- CREATE POLICY "Allow all for anon"
--   ON journal_entries
--   FOR ALL
--   USING (true)
--   WITH CHECK (true);

-- =============================================================================
-- Scribe packets table (optional, for storing received packets)
-- =============================================================================

CREATE TABLE scribe_packets (
  packet_id UUID PRIMARY KEY,
  generated TIMESTAMPTZ NOT NULL,
  sender_name TEXT NOT NULL,
  sender_scribe_id TEXT NOT NULL,
  receiver_user_id TEXT NOT NULL,
  project TEXT NOT NULL,
  packet_data JSONB NOT NULL,
  accepted BOOLEAN DEFAULT FALSE,
  accepted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE scribe_packets IS 'Scribe-to-Scribe packets received from collaborators.';

CREATE INDEX idx_packets_receiver ON scribe_packets (receiver_user_id);
CREATE INDEX idx_packets_project ON scribe_packets (project);

ALTER TABLE scribe_packets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own packets"
  ON scribe_packets
  FOR SELECT
  USING (
    receiver_user_id = current_setting('request.headers', true)::json->>'x-scribe-user-id'
    OR receiver_user_id = (auth.jwt()->>'scribe_user_id')
  );

CREATE POLICY "Users can insert packets addressed to them"
  ON scribe_packets
  FOR INSERT
  WITH CHECK (
    receiver_user_id = current_setting('request.headers', true)::json->>'x-scribe-user-id'
    OR receiver_user_id = (auth.jwt()->>'scribe_user_id')
  );

CREATE POLICY "Users can update own packets"
  ON scribe_packets
  FOR UPDATE
  USING (
    receiver_user_id = current_setting('request.headers', true)::json->>'x-scribe-user-id'
    OR receiver_user_id = (auth.jwt()->>'scribe_user_id')
  );
