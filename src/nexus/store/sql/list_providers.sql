-- All provider rows (boot load / registry cache refresh), ordered by id
-- (the registry re-sorts). The store hands CIPHERTEXT to the registry —
-- decryption lives there, never here.
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
order by id
