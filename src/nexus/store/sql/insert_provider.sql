-- A new provider row. `api_key_encrypted` is the nexus/crypto envelope;
-- the '' sentinel inserts NULL (a keyless provider) — Postgres exposes
-- no parameter nullability, so squirrel parameters cannot be nullable
-- and the sentinel is its documented workaround.
insert into provider (id, name, base_url, api_key_encrypted, key_version, dialect, enabled, created_at, updated_at)
values ($1, $2, $3, nullif($4, ''::bytea), $5, $6, $7, to_timestamp($8), to_timestamp($8))
