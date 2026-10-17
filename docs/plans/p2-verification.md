# Phase 2 verification report — durable session persistence in Postgres

Phase 2 of session organization (PRD §State v1: external Postgres via
`pog`). Verifies the approved plan end-to-end: the storage spike
(squirrel vs pog, timestamptz vs naive-UTC), the store seam, boot
hydration + lazy start, write-behind turn commits, metadata write-through,
hard delete with cascade — first offline through the mockable seam, then
against a real Postgres 17.

Branch: `feature/session-persistence-758106`. All commands run from the
repo root (gleam 1.19.0 / Erlang 28; local Postgres 17 per
`docker-compose.yml` — during verification a portable PG 17.5 on
`127.0.0.1:5433` stood in for the compose service, same schema).

## 1. What shipped

- **`sql/schema.sql`** — the `session` / `session_message` DDL (singular,
  explicit — see §6.5), mapping the Phase 1 `SessionSummary` field set 1:1 (id, title, title_source, model,
  system_prompt, pinned, archived_at, tags, created_at, last_active_at,
  message_count). `CREATE ... IF NOT EXISTS` so re-apply is idempotent.
- **`src/nexus/store.gleam`** — the swappable store seam (mirrors the
  `nexus/net` pattern) plus the pure, only-there-is transcript⇄row
  mappers. Mockable: offline tests substitute a fully functional
  in-memory store and never touch a database.
- **`src/nexus/store/sql/*.sql` + generated `sql.gleam`** — 15 squirrel
  queries (committed; drift-gated in CI by `gleam run -m squirrel check`).
- **`session_registry.start_with_runner`** — test seam: a registry whose
  frozen runner is injectable, so hydration paths (boot, lazy start,
  restart recovery) are testable with a fake runner like everything else.
- **`src/nexus/store/persist.gleam`** — the pog-backed store actor: one
  pool, synchronous reads/metadata, fire-and-forget ordered write-behind
  commits, in-memory persisted-length bookkeeping re-derived from
  `session.message_count` after any restart.
- **`src/nexus/store/migrate.gleam`** — schema-apply runner
  (`gleam run -m nexus/store/migrate`, DATABASE_URL convention) used by
  CI and as the compose re-apply alternative.
- **`src/nexus/session.gleam`** — two injected seams on `SessionSpec`
  (the registry constructs them, so the dependency direction stays
  registry → session): `commit_hook` (the write-behind observer, called
  with the committed transcript at the two commit points) and `hydrate`
  (a starting transcript built through `transcript.new` + `append_*`).
- **`src/nexus/session_registry.gleam`** — boot hydration of the dormant
  set (store unreachable ⇒ registry start fails; no silent ephemeral
  mode), id minting seeded past every stored id, lazy hydrated start on
  first `Get`, metadata write-through for live **and** dormant sessions,
  rehydrating restart for persisted sessions (Phase 1 empty-restart
  survives only for sessions whose row insert failed), delete = stop
  actor + hard `DELETE` (cascade).
- **`src/nexus/config.gleam`** — `NEXUS_PG_*` (host/port/database/user/
  password) with compose-matching defaults; invalid values fail loudly.
- **`src/nexus/boot.gleam`** — the store actor is the first child of the
  root supervisor, before the registry.
- **`docker-compose.yml`** — postgres:17 pinned, host port 5433 on
  loopback, db/user nexus, named volume, `pg_isready` healthcheck,
  schema mounted at `/docker-entrypoint-initdb.d/`, documented re-apply.
- **CI** (`.forgejo/workflows/test.yml`) — postgres service container +
  schema apply + `squirrel check` drift gate; `gleam test` stays offline.

## 2. The spike (approved plan §SPIKE FIRST)

### 2.1 Query layer: squirrel adopted (pog fallback not needed)

Tried squirrel first per the plan: `gleam add squirrel --dev` (4.7.0),
15 queries in `src/nexus/store/sql/*.sql`, codegen against live PG 17
via `DATABASE_URL` — **generated cleanly, compiled, and worked**.
Verified constraints from the plan held: gleam ≥ 1.11 (CI is 1.19),
squirrel requires PG ≥ 16 and a live DB for codegen, and `timestamptz`
is **not** a supported codegen type (issue #21) — which the query set
 sidesteps entirely: every timestamp read is
`extract(epoch from x)::int8` (Int) and every write is `to_timestamp($1)`
(float8) or server-side `now()`, so no query ever selects or binds a
timestamp type.

`gleam run -m squirrel check` exits 1 on drift (verified by mutating a
query and re-running) — that is the CI gate.

Remaining friction, accepted: codegen needs a live DB on every query
change (compose covers it), positional `arg_N` names for multi-param
queries (hidden behind the seam), a large dev-only dependency tree.
Nullable params stayed away by construction: plain vs tool-row inserts
are separate queries, archive/unarchive are two queries (the plan's
convention). Net: hand-written pog queries would have bought nothing —
squirrel kept.

### 2.2 Timestamps: timestamptz (naive-UTC hunch tested and rejected)

`src/spikes/d_pg_roundtrip.gleam` (kept, runnable) writes the same
instant E = 1760000000 through connection pools pinned to UTC and
Asia/Tokyo and reads it back under both. Measured:

| write → read | timestamptz `extract(epoch)` | naive `extract(epoch)` |
|---|---|---|
| UTC write, UTC/Tokyo read | `1760000000` both | `1760000000` both |
| disciplined write (`at time zone 'utc'`), any read | `1760000000` | `1760000000` |
| session-cast write (`::timestamp`) under Tokyo, UTC read | `1760000000` | **`1760032400` (+9h)** |
| `now()` into column under Tokyo vs timestamptz twin | 0s delta | **32400s delta** |

Findings: `extract(epoch from <naive>)` is timezone-free calendar
arithmetic (the naive reads matched), but the **write** side is where
naive bites — `timestamptz → timestamp` casts (including bare `now()`
into a naive column) render in the session timezone, so any
connection-timezone drift between write and read (config change between
deploys, `PGTZ`, per-connection startup params) silently shifts stored
values by the offset. Naive is only safe with `at time zone 'utc'`
discipline on every write. timestamptz needed no discipline anywhere
and hands us exactly Phase 1's wire format (epoch-second Ints).

Decision: **keep `timestamptz`** (DDL unchanged from the baseline).
The pool additionally pins `timezone=UTC` per connection as hygiene.
Squirrel's native `timestamp` mapping (a `gleam_time` `Timestamp`) was
mooted: no query touches a timestamp type at all.

### 2.3 Schema deviation: `tool_args` is `text`, not `jsonb`

The baseline DDL typed `tool_args` as jsonb with the comment "raw
argument JSON, byte-stable" — but jsonb **normalizes** JSON: the spike
stored `{"z": 1, "a": [2, 3], "m": {"q": "x"}}` and read back
`{"a": [2, 3], "m": {"q": "x"}, "z": 1}` (keys sorted, whitespace
stripped). Tool-call argument strings sit **above the request tail**
in every subsequent turn, so normalized arguments would change the
prefix — a direct KV-cache-contract violation. The hard constraint
(byte-identical hydration) outranks the column type: `tool_args` is
`text`, storing the model-emitted fragment verbatim
(`args_text_back_identical=true`). FTS (a future tsvector generated
column) is unaffected; message content stays plain text either way.

Also: an assistant message with N tool calls is N rows (first row
carries the message text); a maximal run of consecutive tool-call rows
rehydrates as one assistant message (the protocol never places two
assistant messages back-to-back). `seq` is the 0-based row index;
`sessions.message_count` counts messages **including** the system
prompt, matching Phase 1's `message_count` — and it is the
write-behind watermark, because rows undercount messages.

## 3. Offline suite (`gleam test`, no network)

`test/session_persistence_test.gleam` + the functional in-memory store
`test/store_mock.gleam` (which survives registry teardown, playing the
external database):

- **Hydrate rebuild**: rich transcripts (plain turns, assistant
  messages with text + two calls, tool results, whitespace-heavy
  unsorted-key argument JSON) round-trip transcript → rows → transcript
  with **byte-identical** `request_body`; deltas skip the persisted
  prefix; `has_delta` guards the lane.
- **Write-behind ordering**: two tool turns produce commits of
  transcripts of length 2, 6, 7, 11 — in order — and the final rows
  reconstruct the live transcript byte-identically.
- **Metadata write-through**: auto-title (once, guarded), rename, tags,
  pin, archive — each reaches the store in order; archiving clears the
  pin in the stored row; a fresh boot sees the stored metadata.
- **Restart with history**: registry + factory torn down, re-booted
  over the surviving store → dormant listing (stored metadata, count,
  no metrics by design) → lazy `Get` → **byte-identical body across the
  restart** → continuing grows it suffix-only (`extends`).
- **Idempotency**: duplicate commit no-ops; an older transcript no-ops;
  rewind (crash between flushes) + recommit repairs to the exact same
  rows.
- **Delete**: dormant and live deletes remove stored rows; the session
  stays gone across a restart.
- **Counter continuation**: dormant s1/s2 ⇒ fresh create mints s3.
- **Fail-fast boot**: a seam whose `list_summaries` errors refuses to
  start the registry.
- Phase 1 suites keep passing (187 → 199 tests); the killed-session
  test now asserts **rehydrated** restart (same transcript) instead of
  Phase 1's empty restart — the intended Phase 2 semantics change. The
  golden metadata-isolation test (not one request byte changes) is
  untouched and green.

## 4. Real-Postgres smoke (`spikes/d3_persistence_smoke`, local only)

Two tool turns through a registry over the real store, full
teardown/re-boot, lazy hydration, continuation, replay, then the
SQL sanity battery — `gleam run -m spikes/d3_persistence_smoke` prints:

```
phaseA_messages=9
phaseB_dormant_count=1   phaseB_title=smoke title   phaseB_message_count=9
phaseB_byte_identical=true
phaseC_snapshot_messages=13   phaseC_store_messages=13
phaseC_extends=true
replay_rows_unchanged=true
recency_index_forced_plan=  ->  Bitmap Index Scan on session_recency
recency_index_forced_plan=        Index Cond: (archived_at IS NULL)
gin_tags_plan=  ->  Bitmap Index Scan on session_tags
gin_tags_plan=        Index Cond: (tags @> '{smoke}'::text[])
gin_filter_count=1
auto_title_guard_refused=true
cascade_rows_before=4 → cascade_rows_after=0
```

At two rows the planner picks a Seq Scan for both queries, so each
index proof runs one `EXPLAIN` with `enable_seqscan=off` (labeled
`_forced`) to show the indexes serve them; a production-sized table
plans the bitmap/index scans on its own (an earlier run with more rows
showed `Bitmap Index Scan on session_recency` unprompted).
`phaseC_snapshot_messages == phaseC_store_messages` matters: the turn
after the restart COMPLETED and persisted (the smoke's registry boots
through `session_registry.start_with_runner`, the test seam that keeps
the fake runner across hydration — see the bug it caught in §5).
Migration idempotency: `gleam run -m nexus/store/migrate` applied 4
statements, and a second run applied the same 4 again with no errors
(`IF NOT EXISTS`).

## 5. Contract check (KV-cache rules 1–6)

- The transcript remains append-only and `nexus/transcript` remains the
  single request-encoding path; the store persists rows and never sees
  a request body. Hydration rebuilds via `transcript.new(model,
  system_prompt)` + the existing `append_*` functions only — proven
  byte-identical offline **and** against real Postgres across a full
  registry restart, and suffix-only after continuing.
- System prompt and model are stored per session and refrozen on
  hydration, so a changed `NEXUS_SYSTEM_PROMPT` between runs cannot
  fork an existing session's prefix (rule 2).
- Dependency direction stays registry → session: persistence reaches
  the session only through the injected `commit_hook` closure (same
  pattern as the injected turn runner).
- **A bug the strict assertions caught**: lazy-started sessions
  originally took the registry's frozen runner — correct for
  production, but it silently made every post-restart turn in the
  tests hit the fake Bifrost URL and fail, while lenient checks
  (`extends` on a user-only delta, silent await timeouts) still passed.
  Fixed by the `start_with_runner` seam + strict
  commit-count/snapshot-length assertions; the smoke's
  `phaseC_snapshot_messages=13` now proves a completed, persisted
  post-restart turn against the real database.
- Plain `gleam test` remains network-free (mock seam); DB-backed checks
  are the local smoke above.

## 6. Deviations from the plan / baseline, and why

1. `tool_args` `jsonb` → `text` (§2.3; byte-stability).
2. `CREATE ... IF NOT EXISTS` (idempotent re-apply via compose/migrate).
3. Killed sessions now restart **rehydrated** rather than empty — the
   Phase 1 empty restart survives only for never-persisted sessions.
   This is the point of Phase 2; the M2 plan's "history loss on restart
   is accepted" PRD clause is superseded here.
4. `squirrel check` needs a live DB in CI — hence the postgres service
   container (scope: schema apply + drift gate only, as decided).
5. Table names are singular and explicit — `session`, `session_message`
   (with `session_recency` / `session_tags` indexes), a deliberate rename
   from the baseline DDL's `sessions`/`messages` before first merge: each
   row is one entity (the Postgres system catalog's own convention), and
   `session_message` keeps the child table's link obvious as the schema
   grows. No deployed data existed, so the rename was free; `session` is
   a non-reserved keyword in Postgres and works unquoted (verified).
