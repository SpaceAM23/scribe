-- nexus-schema.template.sql
-- Scribe Nexus — Generic knowledge-graph schema template
--
-- This file is install-ready. Copy it to your Supabase project and run it
-- directly via the SQL editor or psql. It is fully idempotent:
-- all CREATE TABLE statements use IF NOT EXISTS.
--
-- What this creates:
--   nexus_meta        — versioning and provenance of the mind itself
--   nexus_domains     — hierarchical knowledge taxonomy (the "wings")
--   nexus_informants  — extensible source registry
--   nexus_nodes       — knowledge claims with hierarchy, confidence, salience, provenance
--   nexus_edges       — typed relationships between nodes
--
-- After running this schema file, run the RLS lockdown block at the bottom
-- of this file (or apply it separately) to restrict access to service_role only.
--
-- Configuration:
--   All tables are prefixed nexus_ to namespace them away from other Scribe tables.
--   Never touches the journal_entries table.
--   Domain slugs, informant slugs, node keys, and edge relations are all
--   user-defined at runtime — no hardcoded values in this schema.
--
-- Compatibility:
--   PostgreSQL 14+ / Supabase.
-- ============================================================================


-- ============================================================================
-- TABLE: nexus_meta
-- Versioning and provenance of the knowledge graph itself.
-- One row per schema migration or major state change.
-- ============================================================================

CREATE TABLE IF NOT EXISTS nexus_meta (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  version    text        NOT NULL,
  notes      text,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  nexus_meta         IS 'Version history and provenance of the Nexus knowledge graph.';
COMMENT ON COLUMN nexus_meta.version IS 'Semantic version string (e.g. "1.0.0") set by the installer or migration script.';
COMMENT ON COLUMN nexus_meta.notes   IS 'Free-text description of what changed in this version.';


-- ============================================================================
-- TABLE: nexus_domains
-- The knowledge taxonomy — a hierarchical set of named knowledge areas.
-- Domains are structural; they should be created deliberately.
-- Supports arbitrary depth via self-referential parent_id.
-- ============================================================================

CREATE TABLE IF NOT EXISTS nexus_domains (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug       text        UNIQUE NOT NULL,
  name       text        NOT NULL,
  parent_id  uuid        REFERENCES nexus_domains(id) ON DELETE RESTRICT,
  created_by text        NOT NULL DEFAULT 'librarian',
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  nexus_domains           IS 'Hierarchical knowledge taxonomy. Each domain scopes a set of related knowledge nodes.';
COMMENT ON COLUMN nexus_domains.slug      IS 'Unique, lowercase-hyphenated identifier used in code and queries (e.g. "system", "product-auth").';
COMMENT ON COLUMN nexus_domains.name      IS 'Human-readable label for the domain.';
COMMENT ON COLUMN nexus_domains.parent_id IS 'Self-referential FK for hierarchy. NULL = top-level domain.';
COMMENT ON COLUMN nexus_domains.created_by IS 'Who created this domain: "librarian" (automated) or a user/agent identifier.';


-- ============================================================================
-- TABLE: nexus_informants
-- Source registry — the named sources that contribute knowledge claims.
-- Every node must reference an informant.
-- ============================================================================

CREATE TABLE IF NOT EXISTS nexus_informants (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          text        UNIQUE NOT NULL,
  name          text        NOT NULL,
  kind          text        NOT NULL
                              CHECK (kind IN ('agent', 'human', 'packet', 'document', 'observation')),
  trust_default text        NOT NULL DEFAULT 'medium'
                              CHECK (trust_default IN ('high', 'medium', 'low')),
  created_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  nexus_informants               IS 'Registry of named sources that contribute knowledge claims to the graph.';
COMMENT ON COLUMN nexus_informants.slug          IS 'Unique identifier for the informant, used in receipts and queries.';
COMMENT ON COLUMN nexus_informants.kind          IS 'Category: agent | human | packet | document | observation.';
COMMENT ON COLUMN nexus_informants.trust_default IS 'Default trust level applied to claims from this informant: high | medium | low.';


-- ============================================================================
-- TABLE: nexus_nodes
-- The knowledge claims — discrete, atomic facts about the world.
-- Each node belongs to exactly one domain and references exactly one informant.
--
-- Hierarchy:
--   parent_id enables decomposition: a high-level claim can have child nodes
--   that refine or constrain it. depth is an advisory integer (0 = root claim).
--
-- Lifecycle:
--   status = 'active'     — current, trusted claim
--   status = 'superseded' — replaced by a newer node (supersedes points to old)
--   status = 'retired'    — no longer relevant; not superseded, just inactive
--
-- Confidence:
--   'observed'  — directly witnessed or stated
--   'inferred'  — derived from patterns; reasonable but not directly confirmed
--   'hypothesis' — proposed or conflicting; requires confirmation
--
-- Salience (1–5):
--   5 = architecture-level; high cost to be wrong
--   4 = feature-level; correction is expensive
--   3 = implementation-level; correction is moderate
--   2 = detail-level; easily changed
--   1 = ephemeral or low-stakes
--
-- Provenance:
--   evidence is a JSONB array of source references:
--   [{"entry_id": "abc12345", "note": "from session decision"}, ...]
-- ============================================================================

CREATE TABLE IF NOT EXISTS nexus_nodes (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  domain_id    uuid        NOT NULL REFERENCES nexus_domains(id) ON DELETE RESTRICT,
  parent_id    uuid        REFERENCES nexus_nodes(id) ON DELETE RESTRICT,
  depth        int         NOT NULL DEFAULT 0 CHECK (depth >= 0),
  key          text        NOT NULL,
  content      text        NOT NULL,
  confidence   text        NOT NULL DEFAULT 'hypothesis'
                             CHECK (confidence IN ('observed', 'inferred', 'hypothesis')),
  salience     int         NOT NULL DEFAULT 2
                             CHECK (salience BETWEEN 1 AND 5),
  informant_id uuid        NOT NULL REFERENCES nexus_informants(id) ON DELETE RESTRICT,
  evidence     jsonb       NOT NULL DEFAULT '[]',
  status       text        NOT NULL DEFAULT 'active'
                             CHECK (status IN ('active', 'superseded', 'retired')),
  supersedes   uuid        REFERENCES nexus_nodes(id),
  created_by   text        NOT NULL DEFAULT 'librarian',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  nexus_nodes            IS 'Atomic knowledge claims. Each row is one discrete fact with confidence, salience, and full provenance.';
COMMENT ON COLUMN nexus_nodes.domain_id  IS 'FK to nexus_domains. Every node belongs to exactly one domain.';
COMMENT ON COLUMN nexus_nodes.parent_id  IS 'Optional self-reference for hierarchical decomposition of a claim.';
COMMENT ON COLUMN nexus_nodes.depth      IS 'Advisory depth in the node hierarchy (0 = root claim, no parent).';
COMMENT ON COLUMN nexus_nodes.key        IS 'Short, lowercase-hyphenated identifier unique within a domain (e.g. "cache-ttl-policy").';
COMMENT ON COLUMN nexus_nodes.content    IS 'The knowledge claim, written as a complete, self-contained statement.';
COMMENT ON COLUMN nexus_nodes.confidence IS 'observed | inferred | hypothesis — how well-established this claim is.';
COMMENT ON COLUMN nexus_nodes.salience   IS '1 (low) to 5 (architecture-critical) — how much it matters if this is wrong.';
COMMENT ON COLUMN nexus_nodes.informant_id IS 'FK to nexus_informants. The source that contributed this claim.';
COMMENT ON COLUMN nexus_nodes.evidence   IS 'JSONB array of provenance references: entry short_ids, packet IDs, document names, etc.';
COMMENT ON COLUMN nexus_nodes.status     IS 'active | superseded | retired — lifecycle state. Never delete rows.';
COMMENT ON COLUMN nexus_nodes.supersedes IS 'Points to the node this one replaces. Set when status becomes superseded on the old node.';

-- Index for common query patterns
CREATE INDEX IF NOT EXISTS nexus_nodes_domain_status  ON nexus_nodes (domain_id, status);
CREATE INDEX IF NOT EXISTS nexus_nodes_confidence     ON nexus_nodes (confidence);
CREATE INDEX IF NOT EXISTS nexus_nodes_salience       ON nexus_nodes (salience DESC);
CREATE INDEX IF NOT EXISTS nexus_nodes_informant      ON nexus_nodes (informant_id);
CREATE INDEX IF NOT EXISTS nexus_nodes_updated        ON nexus_nodes (updated_at DESC);


-- ============================================================================
-- TABLE: nexus_edges
-- The connective tissue — typed relationships between nodes.
--
-- Relation vocabulary (configure via your Librarian):
--   requires     — this node depends on the target being true or in place
--   enables      — this node makes the target possible
--   contradicts  — this node is in tension with the target
--   supersedes   — this node replaces the target (mirrors node.supersedes FK)
--   derived_from — this node is inferred from the target
--   scopes       — this node applies only within the context of the target
--
-- Additional relation types may be defined for specific deployments.
-- Keep the vocabulary small — a sprawling edge vocabulary degrades query precision.
-- ============================================================================

CREATE TABLE IF NOT EXISTS nexus_edges (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  from_node  uuid        NOT NULL REFERENCES nexus_nodes(id) ON DELETE CASCADE,
  to_node    uuid        NOT NULL REFERENCES nexus_nodes(id) ON DELETE CASCADE,
  relation   text        NOT NULL,
  created_by text        NOT NULL DEFAULT 'librarian',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT nexus_edges_no_self_loop CHECK (from_node <> to_node)
);

COMMENT ON TABLE  nexus_edges          IS 'Typed relationships between knowledge nodes.';
COMMENT ON COLUMN nexus_edges.relation IS 'Edge type from the governed vocabulary: requires, enables, contradicts, supersedes, derived_from, scopes.';
COMMENT ON COLUMN nexus_edges.from_node IS 'The source node of the directed relationship.';
COMMENT ON COLUMN nexus_edges.to_node   IS 'The target node of the directed relationship.';

CREATE INDEX IF NOT EXISTS nexus_edges_from_node ON nexus_edges (from_node);
CREATE INDEX IF NOT EXISTS nexus_edges_to_node   ON nexus_edges (to_node);
CREATE INDEX IF NOT EXISTS nexus_edges_relation  ON nexus_edges (relation);


-- ============================================================================
-- TRIGGER: auto-update updated_at on nexus_nodes
-- ============================================================================

CREATE OR REPLACE FUNCTION nexus_nodes_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS nexus_nodes_updated_at ON nexus_nodes;
CREATE TRIGGER nexus_nodes_updated_at
  BEFORE UPDATE ON nexus_nodes
  FOR EACH ROW EXECUTE FUNCTION nexus_nodes_set_updated_at();


-- ============================================================================
-- INITIAL META ROW
-- Insert a version record so the schema version is always queryable.
-- Replace "1.0.0" with your installed version if running a migration.
-- ============================================================================

INSERT INTO nexus_meta (version, notes)
VALUES ('1.0.0', 'Initial schema install from nexus-schema.template.sql')
ON CONFLICT DO NOTHING;


-- ============================================================================
-- RLS LOCKDOWN
-- ============================================================================
--
-- IMPORTANT: Apply this block AFTER the tables exist.
-- It is safe to re-run (ENABLE and FORCE are idempotent).
--
-- Policy: NO permissive policies are defined. Only service_role and postgres
-- can read or write any nexus_* table. All other roles — including anon and
-- authenticated — are explicitly revoked.
--
-- This is intentional. The knowledge graph is a private internal structure.
-- It should never be accessible via the Supabase public API (anon key) or
-- authenticated user JWTs. All access goes through the server-side service_role.
--
-- To apply the lockdown:
--   1. Run the ALTER TABLE statements below to enable and force RLS.
--   2. Run the REVOKE statements to strip anon/authenticated/public access.
--   3. Run the GRANT statements to restore service_role access.
--   4. Confirm: no permissive SELECT/INSERT/UPDATE/DELETE policies exist on
--      any nexus_* table (policy absence with RLS enabled = default-deny).
-- ============================================================================

ALTER TABLE nexus_meta        ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexus_domains     ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexus_informants  ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexus_nodes       ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexus_edges       ENABLE ROW LEVEL SECURITY;

ALTER TABLE nexus_meta        FORCE ROW LEVEL SECURITY;
ALTER TABLE nexus_domains     FORCE ROW LEVEL SECURITY;
ALTER TABLE nexus_informants  FORCE ROW LEVEL SECURITY;
ALTER TABLE nexus_nodes       FORCE ROW LEVEL SECURITY;
ALTER TABLE nexus_edges       FORCE ROW LEVEL SECURITY;

REVOKE ALL ON nexus_meta        FROM anon, authenticated, public;
REVOKE ALL ON nexus_domains     FROM anon, authenticated, public;
REVOKE ALL ON nexus_informants  FROM anon, authenticated, public;
REVOKE ALL ON nexus_nodes       FROM anon, authenticated, public;
REVOKE ALL ON nexus_edges       FROM anon, authenticated, public;

-- Restore service_role access so the Scribe writer pipeline can operate.
GRANT ALL ON nexus_meta        TO service_role;
GRANT ALL ON nexus_domains     TO service_role;
GRANT ALL ON nexus_informants  TO service_role;
GRANT ALL ON nexus_nodes       TO service_role;
GRANT ALL ON nexus_edges       TO service_role;

-- ============================================================================
-- END OF nexus-schema.template.sql
-- ============================================================================
