-- A new session row: created/last_active from the registry's epoch
-- seconds; message_count is the transcript length (1 = system prompt).
insert into session (id, title, title_source, model, system_prompt, pinned, tags, created_at, last_active_at, message_count)
values ($1, $2, $3, $4, $5, $6, $7, to_timestamp($8), to_timestamp($8), $9)
