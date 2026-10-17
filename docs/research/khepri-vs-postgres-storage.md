---
title: Nexus storage — Khepri vs PostgreSQL research note
status: decided
 decision: external Postgres (plan unchanged)
tags: [computing, self-hosting, gleam, beam, storage, khepri, postgres]
updated: 2026-10-16
---

# Khepri vs PostgreSQL for Nexus persistence

> **Decision (2026-10-16): stick with external Postgres.** Khepri's local-disk requirement
> plus the export-backup/restore runbook (cadence, restore triggers, incremental-less full
> dumps) adds operational complexity that outweighs the benefit of an embedded store for
> this project. The plan in `docs/plans/mvp-requirements.md` §State (v1: external Postgres
> via `pog`) stands unchanged. Everything below is retained as the research record.

Research question: could [Khepri](https://github.com/rabbitmq/khepri) — instead of the
planned external Postgres server (`docs/plans/mvp-requirements.md` §State, v1) — be the v1
persistence layer for Nexus? Constraints checked: (1) happy in a container (Nomad job),
(2) happy on the NFS-backed host volumes that motivated the "never a database on NFS"
rule ("SQLite on NFS corrupts").

## TL;DR verdict

- **Containers: yes.** Khepri is an embedded BEAM library and is the *default* metadata
  store of RabbitMQ 4.2+ (only supported one in 4.3+), whose dominant deployment mode is
  Docker/Kubernetes. Real gotchas are a persistent volume for the Ra data dir and a
  **stable Erlang node name** across restarts — both standard BEAM-in-container concerns,
  not Khepri-specific.
- **NFS: no.** Khepri's Ra engine is a `fdatasync`-per-write-batch WAL whose docs describe
  `data_dir` as a *local* directory path. There is no NFS support statement anywhere in
  Ra/Khepri/RabbitMQ docs; the RabbitMQ production checklist says NAS only if it offers
  low latency with no spikes and "when possible, prefer local storage to NAS"; and there
  are real-world reports of Ra's `ra_log_wal` crash-looping on NFS-backed k8s volumes
  (rabbitmq-server discussion #13777). This is the same risk class as SQLite-on-NFS, minus
  the vendor guidance Postgres has.
- **Recommendation:** Khepri is a genuinely good fit for Nexus *if* its data dir lives on
  local disk — it eliminates the external DB server entirely (aligned with the "thin
  harness I own" thesis) and maps naturally onto sessions/transcripts. Use NFS only for
  periodic `khepri:export` backups (plain sequential writes — NFS-safe). If the Ra data
  dir must sit on the NFS host volume, don't use Khepri; keep the external-Postgres plan
  (and even Postgres-on-NFS is only conditionally blessed — see below).

## What Khepri is

- Tree-structured replicated database **library** for Erlang/Elixir (hex package
  `khepri`, current 0.19.3), built on [Ra](https://github.com/rabbitmq/ra) (RabbitMQ's
  Jepsen-tested Raft). Not a server: it runs inside Nexus's BEAM VM as a dependency.
  "Being a native Erlang/OTP library, [it is] perfectly integrated in any Erlang
  application" (RabbitMQ metadata-store docs).
- Maturity: "safe to be used in production" — default metadata store in RabbitMQ 4.2.x,
  the only supported one from 4.3.0. Still pre-1.0: **API will evolve with occasional
  breaking changes** (with migration notes). License: Apache-2.0 OR MPL-2.0.
- Ra fundamentals underneath: WAL (`ra_log_wal`) with **`fdatasync(2)` after each write
  batch** (or `fsync` via `wal_sync_method = sync`), pre-allocated WAL files (default max
  512 MB), checksummed segments, snapshots. Ra's config reference types `data_dir` /
  `wal_data_dir` as "**Local** directory path".
- Known limitations (from Khepri's README): the **entire data set lives in memory as well
  as on disk** — realistic size ceiling; storing **blobs is not recommended** (v1
  attachments would need a blob store regardless, same as Postgres `bytea` vs
  filesystem).
- Features that map well onto Nexus:
  - Path-addressed tree (`/sessions/<id>/turns/…`) with Unix-like path strings, patterns,
    prefix queries.
  - **Transactional multi-step updates** via deterministic anonymous functions — fits the
    append-only, byte-stable transcript contract (no side effects, no timestamps allowed
    inside transactions, which matches the discipline Nexus already enforces).
  - **Triggers/stored procedures** (e.g. notify UI watchers on transcript append).
  - Backup/restore: `khepri:export/4` + `khepri:import/3` (plaintext Erlang-term backend,
    custom backends possible).
- Gleam ergonomics: no Gleam bindings exist; access is via a thin Erlang FFI
  (`@external` → `khepri:put/get/delete/transaction/…`). Nexus already carries
  `nexus_*_ffi.erl` files, so this is normal plumbing, not a new pattern.
- OTP version: Nexus targets OTP 28. RabbitMQ's matrix shows Erlang 28 fully supported
  with Khepri from RabbitMQ 4.3.6/4.4 (4.2.x had a Khepri/Erlang-28 caveat only for
  *rolling upgrades of existing clusters* — irrelevant to a brand-new single-node store).
  Pin khepri ≥ 0.19.x. Single node = single Ra server; Raft consensus overhead is unused
  but cheap (Ra is designed to host thousands of clusters per node).

## Container verdict: fine, two gotchas

Khepri-as-RabbitMQ-metadata-store ships in effectively every containerized RabbitMQ 4.2+
deployment today; standalone embedded use outside RabbitMQ also exists (e.g. reckon_db
uses Khepri as its storage layer). Nothing about containers bothers it, provided:

1. **Persistent volume for the Ra data dir.** Default is `khepri#$NODENAME` in the CWD —
   configure a dedicated Ra system with an explicit directory on a mounted volume
   (recommended even by Khepri's own getting-started).
2. **Stable node identity.** Khepri's fundamental assumptions: "requires durable storage
   … and **stable node (replica) identities**". The Erlang node name is baked into Ra
   server identity; a container whose hostname changes every restart breaks recovery. In
   Nomad: fix the node name (`-sname nexus@127.0.0.1` or an env-pinned name) the way
   RabbitMQ's `RABBITMQ_NODENAME` does for StatefulSets.

Both are deployment details, not blockers. A `kill -9` restart replays the WAL — the
supervisor-restart acceptance criterion from the PRD carries over.

## NFS verdict: unsupported and demonstrably fragile

- **No support statement.** Neither Khepri nor Ra documents NFS; Ra types its data
  directories as local paths. The RabbitMQ production checklist (which covers Khepri and
  all other Ra-based subsystems) allows NAS only if it "offers low I/O latency" and "can
  guarantee no significant latency spikes", concluding "when possible, prefer local
  storage to NAS."
- **Real-world failure.** rabbitmq-server discussion #13777: quorum queues (same Ra WAL)
  on NFS-backed k8s PVs — `ra_log_wal` crash loops (`{badmatch,{error,edquot}}`,
  supervisor `reached_max_restart_intensity`), EOFs, hung queues.
- **The physics.** Ra's durability is fsync-per-batch. Per PostgreSQL's own NFS
  documentation, on Linux an NFS client's `fsync` "is not actually guaranteed to reach
  permanent storage on the server" unless the server *exports* with `sync` (many
  servers default to `async`). So on a casually-configured NFS export, Ra's crash
  guarantee silently degrades to roughly "fsync off" — the exact corruption class the
  PRD already hit with SQLite. Additionally NFS attribute/close-to-open caching can
  serve stale metadata to a restarting node's WAL recovery, and any latency spike stalls
  the Ra pipeline (checklist's stated concern).
- Contrast: PostgreSQL **explicitly documents** its data directory on NFS (§18.2.2.1):
  it "does not use any functionality that is known to have nonstandard behavior on NFS,
  such as file locking"; the only firm client requirement is the `hard` mount option,
  with `sync` strongly recommended on the server export. That's a vendor-blessed,
  spec'd configuration — Ra/Khepri offers nothing comparable.

## Comparison for Nexus specifically

| Dimension | Khepri (embedded) | PostgreSQL (external server) |
|---|---|---|
| Deployment | Dependency inside the Nexus Nomad job; zero extra services | Second Nomad job/host service to run, upgrade, monitor, auth |
| Gleam access | Erlang FFI (~1 small `nexus_khepri_ffi.erl`) | `pog` (mature, well supported) |
| Data model | Path tree, prefix queries, atomic transactions, triggers — natural fit for sessions/transcripts | SQL/JSONB — more query power, more ceremony |
| Capacity | Whole store in RAM (fine for chat transcripts; ~100 MB-scale OK); no blobs | Disk-bound; effectively unbounded |
| Durability on NFS | **Unsupported**, crash reports, fsync-semantics hazard | Documented (hard mount + server `sync` export), still operationally discouraged |
| Container | Proven (RabbitMQ default store); needs volume + stable node name | Proven everywhere |
| Maturity risk | Pre-1.0, evolving API; single vendor team | Very mature |
| Backups | `khepri:export` → plain file (NFS-safe to write) | `pg_dump`/WAL archiving |

## Options

- **A — Keep the plan (external Postgres).** Safest, most query headroom, ops cost of a
  second service. Choose if transcripts may grow large or SQL is wanted later.
- **B — Khepri embedded on local disk (recommended if the goal is killing the external
  server).** Ra data dir on a Nomad client-local volume (host path on local SSD, or a
  small dedicated disk), **not** the NFS host volume; periodic `khepri:export` snapshots
  written to NFS for backup (sequential plain-text writes are NFS-safe). Honors the PRD's
  "never a database on NFS host volumes" rule while removing the DB server dependency.
- **C — Khepri with its data dir on NFS.** Don't. Same WAL-on-NFS class that killed
  SQLite here, with no vendor guidance and public crash evidence.

## Option B runbook: export cadence and restore triggers

### Cadence — fully ours (it's just a function call in-process)

`khepri:export/4` runs inside the Nexus VM against the running store; there is no external
scheduler to fight. Scheduling options, best first for a single-writer app:

1. **Event-driven**: export after each committed turn (session actor hook, or a Khepri
   trigger on `/:sessions/**` with debounce). At chat scale (MBs of transcripts) a full-tree
   dump per turn is cheap; RPO collapses to "at most the in-flight turn".
2. **Timer-based**: supervised tick actor, every N minutes; RPO = N.
3. **On graceful shutdown**: Nomad sends SIGTERM → export-then-exit gives a clean latest
   snapshot on every deploy/restart.

Hygiene details:
- Call `khepri:fence/1` before exporting so every write the app considers committed is
  applied locally first (matters if any puts are async).
- Write `backup-<ISO8601>.erl` to a temp name, then rename into place + update a manifest —
  a crash mid-export can never corrupt the previous backup (rename-within-dir is NFS-safe;
  the file itself is sequential plaintext writes, the NFS-safe pattern).
- Rotate (keep N days) at our leisure; exports are full-tree dumps, not incremental —
  fine at this size. The `khepri_import_export` behavior lets us swap in a custom backend
  (e.g. gzip + checksum) later without changing the schedule.
- Exportable per-subtree (`"/:sessions/**"`) if non-transcript state shouldn't ride along.
- Freshness canary: expose "age of newest successful export" in the metrics panel Nexus
  already has; alarm when it exceeds ~2× the chosen interval — that's how we know backups
  are *happening*, as opposed to knowing when to restore.

### Restore — three triggers, two automatic

1. **Empty store at boot (automatic).** Local volume lost/wiped or new node → the store
   starts with nothing. Boot order: start store → `khepri:is_empty/1` (or a
   `/:meta/bootstrap_id` sentinel) → if empty and a manifest exists on NFS →
   `khepri:import(StoreId, khepri_export_erlang, latest)` **before** the session registry
   serves traffic. No human in the loop; worst case loses everything after the last export.
2. **Local store won't start (watchdog).** WAL fails to replay → supervisor crash-loops.
   After N failed starts: quarantine the data dir (rename aside on local disk — keep for
   forensics), start fresh, restore from latest export, log loudly. For a single-user tool,
   auto-restore-and-alert is the right default; halting for a human is the conservative
   variant (a config flag).
3. **Deliberate rollback (manual).** Admin route/CLI: `khepri:reset/1` then import the
   chosen timestamped file. Note `import` **merges into** a running store ("the target
   store is not reset") — reset first for a true rollback, import-into-empty for recovery.

Verification that a backup is *restorable*: the default backend emits plaintext Erlang
terms (`file:consult/1`-readable), so a periodic dry-run import into a scratch store (or
just consult + count records) is a cheap, automatable drill.

### Incremental exports: not built in, but composable

`khepri:export/2,3,4` is always a full dump of the matched path pattern — no `since`
parameter, no delta mode anywhere in the API (Ra machine snapshots are internal recovery
artifacts in the data dir, not a portable backup format). Two mitigations:

- **Subtree + merge = de-facto incremental.** Export `/:sessions/<id>/**` per changed
  session; `import` merges, so those files replay onto the last full backup. Sound for
  Nexus *because* transcripts are append-only by contract — merge-replay can't express
  deletions, and the MVP model produces none. Once session deletion ships, fulls must
  stay the authoritative re-anchor (increments would resurrect deleted sessions).
- **Hand-rolled deltas via `payload_version` conditions** in path patterns are buildable
  but require tracking per-node versions and still can't express deletions — not worth
  it at this scale.

At MBs of transcripts, per-turn *full* exports remain the recommended default;
subtree exports are the escape hatch if the store grows.

What this scheme deliberately gives up versus Postgres PITR: point-in-time recovery
between exports and WAL archiving. With per-turn exports on a single-user app, the loss
window is one turn; if that ever stops being acceptable, that's the signal to reconsider
Option A.

## Sources

- Khepri README & docs — https://github.com/rabbitmq/khepri , https://khepri.hexdocs.pm/overview-summary.html
- Ra README (WAL config, `data_dir` "local directory path", Jepsen) — https://github.com/rabbitmq/ra
- RabbitMQ metadata store (Khepri default in 4.2, only supported in 4.3) — https://www.rabbitmq.com/docs/metadata-store , /docs/metadata-store/how-to-enable
- RabbitMQ production checklist, "Network-attached Storage (NAS)" — https://www.rabbitmq.com/docs/production-checklist
- Ra WAL crash loop on NFS PV — https://github.com/rabbitmq/rabbitmq-server/discussions/13777
- PostgreSQL docs §18.2.2.1 NFS — https://www.postgresql.org/docs/current/creating-cluster.html
- RabbitMQ Erlang version matrix (Erlang 28 × Khepri) — https://www.rabbitmq.com/docs/which-erlang
- Embedded-Khepri precedent — https://reckon-db.hexdocs.pm/storage_internals.html
