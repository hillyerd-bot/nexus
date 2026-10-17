-- Append one tool-result row.
insert into session_message (session_id, seq, role, content, tool_call_id, tool_name, tool_ok)
values ($1, $2, 'tool', $3, $4, $5, $6)
on conflict (session_id, seq) do nothing
