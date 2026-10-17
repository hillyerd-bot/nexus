-- Nexus session persistence (Phase 2).
--
-- Tables are singular and explicit (`session`, `session_message`): each
-- row is one entity, and the messages table's link to its session stays
-- obvious as the schema grows.
--
-- The schema maps 1:1 onto the Phase 1 `SessionSummary` field set
-- (src/nexus/session.gleam): id, title, title_source, model, system_prompt,
-- pinned, archived, tags, created_at, last_active_at, message_count.
--
-- Timestamps are `timestamptz` (see docs/plans/p2-verification.md for the
-- spike outcome): the app reads them as epoch seconds via
-- `extract(epoch from x)::int8` (matching Phase 1's wire format) and writes
-- them through server-side `now()`; explicit params are rare and cast
-- `$1::timestamptz` from text.
--
-- Design notes (approved plan):
-- - tags as text[] + GIN — no join table.
-- - delete is a hard DELETE cascading to session_message; `archived_at`
--   is the only soft state.
-- - message bodies stay plain text so FTS can be added later as a
--   tsvector generated column + index — no FTS now.
-- - MetricSample history stays in memory; persisting it is out of scope.

CREATE TABLE IF NOT EXISTS session (
  id             text PRIMARY KEY,             -- existing user-visible session id
  title          text NOT NULL,
  title_source   text NOT NULL DEFAULT 'auto', -- 'auto' | 'manual'
  model          text NOT NULL,                -- frozen alias (contract rule 2)
  system_prompt  text NOT NULL,                -- frozen at creation (contract rule 2); stored so hydration rebuilds the frozen prefix byte-identically
  pinned         boolean NOT NULL DEFAULT false,
  archived_at    timestamptz,                  -- NULL = active
  tags           text[] NOT NULL DEFAULT '{}',
  created_at     timestamptz NOT NULL,
  last_active_at timestamptz NOT NULL,         -- bumped on turn commit; drives recency + buckets
  message_count  int NOT NULL DEFAULT 0        -- denormalized for list queries
);

CREATE INDEX IF NOT EXISTS session_recency ON session (archived_at, last_active_at DESC);
CREATE INDEX IF NOT EXISTS session_tags ON session USING gin (tags);

CREATE TABLE IF NOT EXISTS session_message (
  id           bigserial PRIMARY KEY,
  session_id   text NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  seq          int NOT NULL,                   -- append-only order
  role         text NOT NULL,                  -- 'user' | 'assistant' | 'tool' (transcript roles)
  content      text NOT NULL,                  -- exact transcript content, never mutated
  tool_call_id text,
  tool_name    text,
  tool_args    text,                           -- raw argument JSON as the model emitted it. NOTE: deliberately text, not jsonb: jsonb normalizes (sorts keys, strips whitespace, dedupes), which would break the byte-identical hydration contract for tool-call arguments that sit above the request tail (see docs/plans/p2-verification.md)
  tool_ok      boolean,
  UNIQUE (session_id, seq)
);
