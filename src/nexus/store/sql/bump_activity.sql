-- Turn commit: recency + denormalized count (absolute, idempotent).
update session set last_active_at = now(), message_count = $1
where id = $2
