-- One provider row by id. `Error` for unknown ids is decided by the
-- caller from the empty result; the envelope rides along for the
-- registry to decrypt (AAD = provider id).
select
  id,
  name,
  base_url,
  api_key_encrypted,
  key_version,
  dialect,
  enabled,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from updated_at)::int8 as updated_s
from provider
where id = $1
