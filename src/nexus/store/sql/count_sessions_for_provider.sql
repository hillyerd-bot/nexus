-- How many sessions pin this provider — the registry's delete guard
-- (409 while > 0; prefer disabling).
select count(*)::int8 as sessions
from session
where provider_id = $1
