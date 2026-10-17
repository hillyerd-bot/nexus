-- Append one assistant tool-call row (content = the message text, '' for
-- continuation rows of the same assistant message).
insert into session_message (session_id, seq, role, content, tool_call_id, tool_name, tool_args)
values ($1, $2, 'assistant', $3, $4, $5, $6)
on conflict (session_id, seq) do nothing
