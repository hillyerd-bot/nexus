-- Hard delete of an unreferenced provider. While any session pins it,
-- the session_provider_id FK (ON DELETE RESTRICT) refuses the delete —
-- the registry's count-based 409 pre-check is the friendly copy of that
-- guard, this is the enforcement.
delete from provider where id = $1
