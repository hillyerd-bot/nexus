# AGENTS.md

Repo guidance for coding agents working on nexus. Source of truth for the
"why" behind these rules: `docs/plans/p2-verification.md`.

## Database schema naming (decided, follow it)

The persistence layer lives in `sql/schema.sql` + `src/nexus/store/sql/`.

- **Table names are singular** — `session`, `session_message`. Each row is
  one entity; this matches the Postgres system catalog's own convention
  (`pg_class`, `pg_proc`, `pg_type`). Do not pluralize new tables.
- **Child/link tables are named after their parent plus their role** —
  `session_message`, not `message`. A generic name hides the FK link as
  the schema grows; `session_message` makes it obvious.
- **Verify a name is unquoted-safe before using it.** `session` is a
  *non-reserved* keyword in Postgres and is used unquoted everywhere. Keep
  that property for new table/column names (check the keyword list, or
  just try it against a live database).
- **Indexes follow `<table>_<purpose>`** — `session_recency`,
  `session_tags`.
- **Foreign keys are `<parent>_id`** (`session_message.session_id`).
- Renaming after deployment requires a migration; renames while the schema
  has no deployed data (pre-merge) are just edits — that is how the
  `sessions`/`messages` → `session`/`session_message` rename landed.

## Schema invariants (hard constraints — do not break)

- **`session_message.tool_args` is `text`, never `jsonb`.** jsonb
  normalizes JSON (sorted keys, stripped whitespace); tool-call argument
  strings sit above the request tail, so normalized values would change
  request bytes and violate the KV-cache contract
  (`docs/plans/mvp-requirements.md`). Byte-stability beats queryability
  here.
- **Timestamps are `timestamptz`.** Read as `extract(epoch from x)::int8`
  (epoch seconds, the Phase 1 wire format), write via `to_timestamp($1)`
  or server-side `now()`. Never introduce naive `timestamp` columns —
  `now()` into one shifts by the session timezone under config drift
  (measured +9h; see `spikes/d_pg_roundtrip`).
- **`session.message_count` counts messages including the system prompt**
  (Phase 1 `SessionSummary` semantics) and doubles as the write-behind
  watermark: an assistant message with N tool calls is ONE message but N
  `session_message` rows, so a row count would undercount.
- **`seq` is the 0-based `session_message` row index**; inserts carry
  `on conflict (session_id, seq) do nothing` so crash-recovery replays are
  idempotent. An assistant message with N calls is N consecutive rows and
  the first row carries the message text (`''` on continuation rows).

## Changing the schema or queries

1. Edit `sql/schema.sql` idempotently (`IF NOT EXISTS`).
2. Re-apply: `gleam run -m nexus/store/migrate` (needs `DATABASE_URL`;
   `docker compose up -d` provides the local database on `127.0.0.1:5433`).
3. Edit the queries in `src/nexus/store/sql/*.sql` (one query per file,
   file name = generated function name), then regenerate:
   `gleam run -m squirrel` — the generated `sql.gleam` is committed.
4. CI runs `squirrel check` and fails on stale generated code.
5. `gleam test` must stay offline/network-free: persistence tests go
   through the mockable seam (`src/nexus/store.gleam`,
   `test/store_mock.gleam`), never a live database.

The runner's statement splitter (`statements` in `migrate.gleam`) is
quote-aware: single/double quotes, dollar quotes (`$$…$$`, `$tag$…$tag$`),
`--` lines, and nested `/* */` comments are understood, so a `;` inside a
`DO` block, `CREATE FUNCTION` body, or literal does not split a statement.
Unit tests: `test/migrate_test.gleam`.
