---
title: Nexus — multiple LLM providers, provider keys, and models
status: approved
tags: [nexus, providers, models, secrets, schema, kv-cache]
updated: 2026-10-18
---

# Nexus: multiple providers, provider keys, and models

Design + migration plan for moving nexus from **one hard-coded Bifrost
endpoint** to **N provider endpoints each with its own (encrypted) key**,
with **provider + model pinned per session**.

> Decisions captured here came out of the 2026-10-18 planning session;
> implementation is split into the phased roadmap (§17), each phase to be
> kicked off separately.

## 1. Goal and non-goals

**Goal.** Let one nexus instance talk to N independent OpenAI-compatible
`/v1` endpoints ("providers"), each with its own base URL and optional
bearer key. Provider keys are stored in Postgres, encrypted at rest.
Every session pins exactly one `(provider, model)` pair for its lifetime.

**Non-goals (this plan).**

- Native non-OpenAI dialects (Anthropic Messages, Gemini). Providers stay
  OpenAI-compatible; the registry carries a `dialect` field defaulting to
  `openai` so a future dialect does not need a schema change.
- Multi-user. Auth stays the single `NEXUS_UI_TOKEN`.
- Per-provider retry/failover or routing between providers. A session's
  provider is fixed; recovery is out of scope.
- Provider health/scoring, cost accounting.

## 2. Current state (the single-provider assumption)

| Seam | File | Today |
|---|---|---|
| Config | `src/nexus/config.gleam` | one `base_url` (must end `/v1`) + `api_key`, both required |
| Transport | `src/nexus/openai.gleam` | `to_openai_config(cfg)` builds one glopenai client; `list_models(cfg)` |
| Loop | `src/nexus/loop.gleam` | `bifrost_stream(cfg)` |
| Session | `src/nexus/session.gleam` | `agent_runner(cfg, specs)` closes over global `cfg`; `TurnRunner = fn(Config, Transcript, cancel, on_event)` |
| Model | `src/nexus/transcript.gleam` | `Transcript(model: String, …)` — the only model identity |
| Schema | `sql/schema.sql` | `session.model text` — alias only, provider implicit |
| Web | `src/nexus/web.gleam` | `GET /models`, `POST /sessions {model}` |
| UI | `src/nexus/ui.gleam` | one flat alias list; subtitle `model · relative time` |

Because glopenai is instantiated per request (`oai_config.new(key) |>
oai_config.with_api_base(url)`), no library surface changes are needed for
per-session providers — only where those two strings come from.

The KV-cache contract (`docs/plans/mvp-requirements.md`) is the binding
constraint: provider + model are frozen at session creation (like the
system prompt), append-only transcript, one encode path, byte-identical
prefix. A mid-session provider/model switch is a **fork**, never an
in-place edit.

## 3. Decisions (this planning session)

1. **Multiple OpenAI-compatible endpoints** — nexus owns N provider
   definitions; it does not delegate provider identity to Bifrost.
2. **Keys in Postgres, encrypted at rest.**
3. **Provider + model pinned per session** (frozen like the alias today).
4. **Hard cut** on `BIFROST_BASE_URL` / `BIFROST_API_KEY` — removed from
   the server config; DB is the only source of providers.
5. **Single `NEXUS_ENCRYPTION_KEY`** master key (`key_version` stays 1;
   the column exists so rotation is additive later).
6. **Disable by default; hard delete only when unreferenced** — deleting a
   referenced provider is a `409`.
7. **Keyless providers allowed** — `api_key` optional (local Ollama /
   LM Studio / llama.cpp).
8. **Pre-deployment schema edit, not a migration** — nexus has not been
   deployed, so `sql/schema.sql` is edited in place (per `AGENTS.md`);
   no `ALTER`, no backfill, no legacy NULL handling.
9. **The migrate-tool splitter fix is optional and decoupled** from this
   feature; the c_cache decouple may land first (§18).

## 4. Architecture overview

```
boot
 └─ root supervisor (OneForAll)
    ├─ persist store actor        (ciphertext in/out, unchanged seam shape)
    ├─ provider_registry actor    (NEW: decrypt, cache, CRUD, resolve)
    ├─ session factory supervisor
    ├─ session_registry actor
    ├─ ui_runtime
    └─ mist

session actor ──frozen ProviderSpec──> loop.run ──> openai.stream(spec, …)
                       ▲
                       └── resolved at create via provider_registry
```

- `nexus/crypto` — pure AES-256-GCM over OTP `crypto` (FFI). No provider
  logic.
- `nexus/provider` — pure types + validation + masking (`ProviderSpec`,
  `Provider` row, base-URL normalization, key hinting).
- `nexus/provider_registry` — actor: load from store, decrypt lazily,
  cache, CRUD, hand out frozen `ProviderSpec`.
- Store stays dumb: it reads/writes **ciphertext only**. Encryption lives
  in the registry, so the mockable seam never handles plaintext and offline
  tests can fake crypto.

## 5. Data model

### 5.1 New table (insert into `sql/schema.sql`)

Singular name, `<table>_<purpose>` indexes, `timestamptz` timestamps,
per `AGENTS.md`. **Declared before `session`** — `session.provider_id`
references it (§5.2), and the FK target must exist first.

```sql
CREATE TABLE IF NOT EXISTS provider (
  id                 text PRIMARY KEY,
  name               text NOT NULL UNIQUE,          -- display + lookup key
  base_url           text NOT NULL,                 -- OpenAI-compatible, ends /v1
  api_key_encrypted  bytea,                         -- NULL = keyless (local endpoints)
  key_version        int NOT NULL DEFAULT 1,
  dialect            text NOT NULL DEFAULT 'openai',-- future: 'anthropic', …
  enabled            boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL,
  updated_at         timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS provider_enabled ON provider (enabled);
```

`name` is unique → implicit unique index satisfies lookups by name;
`provider_enabled` supports the picker's `enabled = true` filter.

### 5.2 Session link (edit the existing `CREATE TABLE session`)

Because nexus is pre-deployment, add the column straight to the existing
`session` DDL rather than via `ALTER`:

```sql
provider_id  text NOT NULL REFERENCES provider(id) ON DELETE RESTRICT,
```

`NOT NULL` is safe — there are no rows to backfill (every local database is
disposable; §15). New sessions always write an explicit id, so no
NULL/legacy path exists. `ON DELETE RESTRICT` enforces the "hard delete
only if unreferenced" rule at the DB layer, backed by the registry's `409`
pre-check.

The naive `migrate` splitter is therefore **not** a constraint here: the
change is a plain `CREATE` edit with no semicolons in literals. Moving the
`session` block below the new `provider` block is the only structural care
needed.

### 5.3 Queries (`src/nexus/store/sql/*.sql`, one per file, filename = fn name)

New:

- `list_providers.sql` — all providers, ciphertext + key_version included
  (the store hands ciphertext to the registry).
- `get_provider.sql`
- `insert_provider.sql`
- `update_provider.sql` — name / base_url / key envelope / key_version /
  enabled / updated_at; present-key semantics via `COALESCE` or explicit
  full-row update. **Key replacement vs. keep** must be distinguishable:
  use a boolean `replace_key` flag so "PATCH without api_key" keeps the
  existing ciphertext instead of nulling it.
- `delete_provider.sql`
- `count_sessions_for_provider.sql` — the `409` guard.

Amended:

- `insert_session.sql`, `get_session.sql`, `list_summaries.sql` — carry
  `provider_id`; regenerate row types in `src/nexus/store/persist.gleam`.

Regenerate with `gleam run -m squirrel` and commit; CI's `squirrel check`
gates drift.

### 5.4 Optional: harden the `nexus/store/migrate.gleam` splitter

Not required for this feature (the schema edit is plain `CREATE`), but it
remains a latent footgun: the splitter strips `--` comments and splits on
`;`, so any future `DO $$…$$` block, `CREATE FUNCTION`, or literal
containing `;` breaks. A small quote-aware splitter (single, double, and
dollar quotes) with unit tests removes that trap. Land independently;
**do not gate multi-provider on it.**

## 6. Encryption at rest (`nexus/crypto`)

- **Algorithm:** AES-256-GCM via OTP `crypto`. New FFI module
  `src/nexus_crypto_ffi.erl`.
- **Master key:** `NEXUS_ENCRYPTION_KEY` = base64 of exactly 32 random
  bytes (`openssl rand -base64 32`). Validated at boot; wrong length /
  missing → boot fails loudly (matches the existing fail-fast config
  style). No default, no derived key.
- **Envelope** (single `bytea` column `api_key_encrypted`):
  `0x01 || nonce(12) || tag(16) || ciphertext`. Version byte allows a
  format change independent of `key_version`.
- **AAD = provider id** — binds ciphertext to its row; a swapped/copied
  envelope fails authentication.
- **Nonce:** 12 random bytes per encryption (`crypto:strong_rand_bytes`).
- **API:** `nexus/crypto.encrypt(key: BitArray, aad: String, plaintext:
  String) -> Result(BitArray, CryptoError)`,
  `decrypt(key, aad, envelope) -> Result(String, CryptoError)`.
- **Storage type:** `pog.bytea(BitArray)` for bind params; squirrel maps
  `bytea` columns to `gleam.BitArray` on read. (Verified against
  pog 4.1.0 / squirrel 4.7.0.)
- **Rotation (deferred):** `key_version` on the row plus an
  `NEXUS_ENCRYPTION_KEY_VERSION` env read; a `rewrap` path can re-encrypt
  rows with the active key. Not implemented now; the columns make it
  additive.
- Keys are **never** logged, echoed, or put in errors. `CryptoError` is a
  closed type with fixed strings.

## 7. Provider registry and boot order

`nexus/provider_registry` is a `gleam_otp` actor wrapped around the store
seam.

Messages:

- `List(reply: Subject(Result(List(Provider), _)))` — metadata + `has_key`,
  never the key.
- `Get(id, reply)` — metadata.
- `Resolve(id, reply) -> Result(ProviderSpec, _)` — decrypts, returns the
  runtime spec used to stream.
- `Create(params, reply)`, `Update(id, params, reply)`,
  `Delete(id, reply)`, `SetEnabled(id, bool, reply)`.
- `ListModels(id, reply)` — delegates to `openai.list_models(spec)`.

`ProviderSpec` (runtime, holds the **plaintext** key, never persisted or
serialized):

```
ProviderSpec(id: String, name: String, base_url: String, api_key: Option(String))
```

Caching: providers are small and change rarely; the actor keeps a
`Dict(String, ProviderSpec)` cache populated on first `Resolve`, invalidated
on update/delete. Reads of the whole table happen once at start (so a bad
envelope fails loudly at boot, not on first message).

**Boot order change** (`src/nexus/boot.gleam`): store first, then
**provider_registry**, then factory, session_registry, ui_runtime, mist.
The registry resolves the seam by name like the session registry does.

## 8. Session pinning and the runner change

- `TurnRunner` becomes
  `fn(ProviderSpec, Transcript, cancel, on_event) -> StreamOutcome`.
  `session.agent_runner(spec-details, tools)` captures only config that is
  provider-independent (`max_tool_iterations`, tool specs); the provider
  comes in per call.
- Session state gains a frozen `provider: ProviderSpec` resolved at create.
  `SessionSpec` gains `provider_id`; `start_builder` resolves/accepts the
  spec via the registry (production) or injected into the spec (tests).
- `loop.bifrost_stream(cfg)` → `loop.openai_stream(spec)`;
  `openai.stream(spec, …)` / `openai.stream_with_cancel(spec, …)` /
  `openai.list_models(spec)` build the glopenai client from `spec` instead
  of `cfg`.
- `session.model` and `transcript.model` stay the alias string; the
  provider lives beside them in session state and the `session.provider_id`
  column. Hydration resolves the spec by persisted id, then rebuilds the
  transcript exactly as today.
- **Fork rule:** a provider or model change = create a new session. No
  in-place switch, no re-encode. This preserves the frozen-prefix contract
  byte-for-byte.

## 9. KV-cache contract preservation

- Provider, model, system prompt, and tool schema are all frozen at
  creation. Nothing about the provider is written into the request body
  beyond the existing `model` field, so request bytes are unchanged.
- Session→backend affinity (contract rule 5) is now trivially satisfied
  *across* providers (different endpoints) and stays provider-local within
  one (Bifrost routing unchanged).
- The golden prefix tests (`test/m3_prefix_test.gleam`) must still pass
  with a `ProviderSpec` injected; a new golden test asserts that switching
  a spec's **key** (same base URL + model) produces byte-identical request
  bodies — credentials never enter the body.
- Warm/cold TTFT evidence is now **per provider**; the audit tool canon
  (§13) must name its provider.

## 10. Transport changes (`nexus/openai`)

- Replace `Config` params with `ProviderSpec` in `list_models`, `stream`,
  `stream_with_cancel`, `to_openai_config`.
- `list_models` keeps the Bifrost `alias`-field fallback decoder.
- Add `dialect` dispatch stub: only `openai` implemented; anything else is
  a typed `UnsupportedDialect` error (no silent fallback).

## 11. HTTP API

All provider routes require `NEXUS_UI_TOKEN` when set (same gate as the
rest of the JSON surface).

| Route | Body | Notes |
|---|---|---|
| `GET /providers` | — | metadata list; `has_key: bool`, never the key |
| `POST /providers` | `{name, base_url, api_key?}` | validate base URL ends `/v1`; normalize; encrypt |
| `PATCH /providers/<id>` | `{name?, base_url?, api_key?, enabled?}` | present-api_key replaces; omitted keeps |
| `DELETE /providers/<id>` | — | `409` while `count_sessions_for_provider > 0`; prefer `enabled:false` |
| `GET /providers/<id>/models` | — | live alias list from that provider |
| `POST /sessions` | `{provider, model}` | both validated; provider resolved by name/id; pin both |
| `GET /models` | — | **deprecated** alias for the default provider's models |

Session summaries gain `provider` (name) for display; the UI subtitle
becomes `provider/model · relative time`.

Error mapping: unknown provider → `400`; disabled provider → `400`;
unreachable/auth failure on model list → `502` (existing pattern).

## 12. UI (`nexus/ui` + `nexus/page`)

- Provider picker on session create; models load per selected provider
  (`aliases_effect` becomes provider-scoped).
- A providers settings surface (Lustre component route or a section in the
  shell): list, add, edit, enable/disable, delete. Key field is
  **write-only**: renders empty on edit; blank means "keep existing". Show
  `has_key` / a `configured` badge, never key material.
- Existing sessions display their pinned provider; changing it is
  "fork session", not an edit.

## 13. Config and first-run bootstrap (hard cut)

`nexus/config.Config`:

- **Removed:** `base_url`, `api_key`.
- **Added:** `encryption_key: String` (required),
  `provider_default: Option(String)` (provider **name** for the boot
  session), and `model_default` becomes `Option(String)`.
- **Unchanged:** PG fields, timeouts, system prompt, tool/web-search knobs.

First run:

1. Boot loads config; missing/invalid `NEXUS_ENCRYPTION_KEY` → fail loudly.
2. Provider registry starts with an empty table → zero providers.
3. Boot creates the default session **only if** `NEXUS_PROVIDER_DEFAULT`
   and `NEXUS_MODEL_DEFAULT` both resolve to an existing/enabled provider
   and model. Otherwise the server starts with an empty session list and
   the operator creates a provider via `POST /providers` (or the UI).
4. README documents the new required env and the first-run curl.

**Audit tool canon (open prerequisite).** `spikes/c_cache` currently reads
the removed `BIFROST_*` env (and shares `nexus/config`). It must be
decoupled — its own small loader (`NEXUS_AUDIT_BASE_URL` /
`NEXUS_AUDIT_API_KEY` / `NEXUS_AUDIT_MODEL`) or CLI flags — but **this is
tracked separately and may land before multi-provider (§18).** It is a
standalone operator tool and must not be coupled to the server's provider
store.

**Test churn.** Every `test/*.gleam` fixture that constructs
`config.Config(base_url:, api_key:, …)` (`session_test`,
`session_persistence_test`, `session_registry_test`, `web_routes_test`,
`ui_test`, `m3_prefix_test`, …) must drop those fields and supply a
`ProviderSpec`/registry fixture instead.

## 14. Security and threat model

- **Auth:** provider CRUD is behind `NEXUS_UI_TOKEN`; with the token unset
  the app is loopback-only (PRD hard req. 5), so the DB is not reachable
  remotely anyway.
- **At rest:** AES-256-GCM protects against DB dumps, backups, and
  SQL-read leaks. It does **not** protect against VM/host compromise (the
  master key is in the process env). State this plainly in the doc.
- **In transit:** provider TLS is the operator's `base_url` scheme;
  loopback HTTP endpoints are allowed (local models).
- **In memory:** only `provider_registry` and the streaming session hold
  plaintext. Keys never enter the transcript, session summary, logs, or
  error strings.
- **SSRF:** `base_url` is operator-supplied trusted config (it is the
  destination of every request), so the `http_fetch` SSRF guard does not
  apply. `http_fetch`'s existing guard is untouched.
- **Delete:** `ON DELETE RESTRICT` + registry `409` prevent orphaning
  sessions; disable is the reversible path.

## 15. Migration and rollout

**No migration — nexus is pre-deployment.**

- Edit `sql/schema.sql` in place: add `provider` **before** `session`, add
  `session.provider_id NOT NULL REFERENCES provider(id)`.
- Local databases: recreate the compose volume
  (`docker compose down -v && docker compose up -d`) so
  `/docker-entrypoint-initdb.d/` re-applies the edited schema. The
  `IF NOT EXISTS` DDL will create the new `provider` table on an existing
  volume, but it will **not** alter the existing `session` table — recreate
  the volume instead of relying on `migrate` for that edit.
- CI applies schema via `gleam run -m nexus/store/migrate` on a fresh
  Postgres service container, so it picks the edit up with no change.
- Remove `BIFROST_*` from `.env` examples, README env table, and
  `docker-compose`/e2e wiring; add `NEXUS_ENCRYPTION_KEY`.
- No data exists, so there is no NULL-provider path and no backfill. The
  ciphertext format is introduced with the feature; nothing to rotate.

## 16. Testing strategy (offline, no network/DB)

- `nexus/crypto`: fixed test key; round-trip; wrong-AAD fails; tampered
  ciphertext/tag fails; malformed key length rejected.
- `nexus/provider` (pure): base-URL normalization (`/v1` suffix), name
  validation, `has_key` masking, present-key PATCH semantics.
- `provider_registry`: actor test against the in-memory store mock;
  CRUD; cache invalidation; `409` on delete-when-referenced; disabled
  provider refused.
- `store_mock.gleam`: in-memory `provider` table.
- `web_routes_test`: provider CRUD status codes; **assert the key never
  appears in any response body**; `POST /sessions` pins provider+model.
- new golden test: same base URL + model, different key ⇒ byte-identical
  request body; existing `m3_prefix_test` still byte-identical with an
  injected spec.
- `config_test`: `NEXUS_ENCRYPTION_KEY` required; `BIFROST_*` gone.

## 17. Phased roadmap

| Phase | Scope | Acceptance |
|---|---|---|
| P0 | `nexus/crypto` + FFI + tests | round-trip + tamper tests pass offline |
| P1 | `provider` table + `session.provider_id` + squirrel queries + store seam + mock | `squirrel check` clean; store tests offline |
| P2 | `nexus/provider_registry` + boot wiring | creates/lists/resolves a provider from a live DB; boot fails on bad key |
| P3 | Config hard cut + `ProviderSpec` plumbing through openai/loop/session | server starts with zero providers; boot session gated on default env |
| P4 | HTTP API (`/providers`, provider-scoped `/models`, `POST /sessions`) | curl CRUD; key never echoed; `409` delete guard |
| P5 | UI provider management + provider→model picker | create provider, create session, stream a turn end-to-end |
| P6 | Audit-tool decoupling (**may land earlier, §18**) + docs | `c_cache` runs via its own config; README updated |
| P7 (deferred) | key rotation/`rewrap`, dialect stubs | not required for ship |

Each phase keeps `gleam test` offline and the golden prefix invariants
green.

## 18. Open questions / risks

- **Audit-tool decoupling (`spikes/c_cache`) is left open** — the operator
  may decouple it from `nexus/config` *before* multi-provider. It is a P6
  precondition, not a core-MVP blocker.
- **Model list caching:** live fetch per picker open is fine at this
  scale; add a short TTL only if it proves slow.
- **`update_provider.sql` key semantics** need an explicit `replace_key`
  boolean; verify squirrel handles the boolean + `COALESCE` ergonomically.
- **`ProviderSpec` holds a plaintext key inside session state** — accepted
  (in-process), but audit that it never lands in `describe`/metrics/
  summaries; add a "no key in serialized output" test.
- **`insert_session` gains a column** — the generated row/param types in
  `persist.gleam` change; expect mechanical churn in tests that build
  `StoredSummary` (add `provider_id`).
