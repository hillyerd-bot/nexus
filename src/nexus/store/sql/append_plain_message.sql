-- Append a user or plain-assistant row. Idempotent on replay.
insert into session_message (session_id, seq, role, content)
values ($1, $2, $3, $4)
on conflict (session_id, seq) do nothing
