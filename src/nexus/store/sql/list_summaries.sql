-- All stored session summaries, ordered by id (the registry re-sorts).
select
  id,
  title,
  title_source,
  model,
  pinned,
  (archived_at is not null) as archived,
  tags,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from session
order by id
