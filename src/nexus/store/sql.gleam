//// This module contains the code to run the sql queries defined in
//// `./src/nexus/store/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import pog

/// Append a user or plain-assistant row. Idempotent on replay.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn append_plain_message(
  db: pog.Connection,
  arg_1: String,
  arg_2: Int,
  arg_3: String,
  arg_4: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Append a user or plain-assistant row. Idempotent on replay.
insert into session_message (session_id, seq, role, content)
values ($1, $2, $3, $4)
on conflict (session_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Append one assistant tool-call row (content = the message text, '' for
/// continuation rows of the same assistant message).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn append_tool_call(
  db: pog.Connection,
  arg_1: String,
  arg_2: Int,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Append one assistant tool-call row (content = the message text, '' for
-- continuation rows of the same assistant message).
insert into session_message (session_id, seq, role, content, tool_call_id, tool_name, tool_args)
values ($1, $2, 'assistant', $3, $4, $5, $6)
on conflict (session_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Append one tool-result row.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn append_tool_result(
  db: pog.Connection,
  arg_1: String,
  arg_2: Int,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: Bool,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Append one tool-result row.
insert into session_message (session_id, seq, role, content, tool_call_id, tool_name, tool_ok)
values ($1, $2, 'tool', $3, $4, $5, $6)
on conflict (session_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.bool(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `archive` query
/// defined in `./src/nexus/store/sql/archive.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn archive(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update session set archived_at = now(), pinned = false
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Auto-title only while the title is still the untouched auto default.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn auto_title(
  db: pog.Connection,
  title: String,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Auto-title only while the title is still the untouched auto default.
update session set title = $1
where id = $2 and title_source = 'auto' and title = ''
"
  |> pog.query
  |> pog.parameter(pog.text(title))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Turn commit: recency + denormalized count (absolute, idempotent).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn bump_activity(
  db: pog.Connection,
  message_count: Int,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Turn commit: recency + denormalized count (absolute, idempotent).
update session set last_active_at = now(), message_count = $1
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.int(message_count))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `delete_session` query
/// defined in `./src/nexus/store/sql/delete_session.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn delete_session(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "delete from session where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `get_session` query
/// defined in `./src/nexus/store/sql/get_session.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GetSessionRow {
  GetSessionRow(
    id: String,
    title: String,
    title_source: String,
    model: String,
    system_prompt: String,
    pinned: Bool,
    archived: Bool,
    tags: List(String),
    created_s: Int,
    last_active_s: Int,
    message_count: Int,
  )
}

/// One stored session row (lazy hydration of a dormant session).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn get_session(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(GetSessionRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use title <- decode.field(1, decode.string)
    use title_source <- decode.field(2, decode.string)
    use model <- decode.field(3, decode.string)
    use system_prompt <- decode.field(4, decode.string)
    use pinned <- decode.field(5, decode.bool)
    use archived <- decode.field(6, decode.bool)
    use tags <- decode.field(7, decode.list(decode.string))
    use created_s <- decode.field(8, decode.int)
    use last_active_s <- decode.field(9, decode.int)
    use message_count <- decode.field(10, decode.int)
    decode.success(GetSessionRow(
      id:,
      title:,
      title_source:,
      model:,
      system_prompt:,
      pinned:,
      archived:,
      tags:,
      created_s:,
      last_active_s:,
      message_count:,
    ))
  }

  "-- One stored session row (lazy hydration of a dormant session).
select
  id,
  title,
  title_source,
  model,
  system_prompt,
  pinned,
  (archived_at is not null) as archived,
  tags,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from session
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A new session row: created/last_active from the registry's epoch
/// seconds; message_count is the transcript length (1 = system prompt).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn insert_session(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: Bool,
  arg_7: List(String),
  arg_8: Float,
  arg_9: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- A new session row: created/last_active from the registry's epoch
-- seconds; message_count is the transcript length (1 = system prompt).
insert into session (id, title, title_source, model, system_prompt, pinned, tags, created_at, last_active_at, message_count)
values ($1, $2, $3, $4, $5, $6, $7, to_timestamp($8), to_timestamp($8), $9)
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.bool(arg_6))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_7))
  |> pog.parameter(pog.float(arg_8))
  |> pog.parameter(pog.int(arg_9))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `list_summaries` query
/// defined in `./src/nexus/store/sql/list_summaries.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListSummariesRow {
  ListSummariesRow(
    id: String,
    title: String,
    title_source: String,
    model: String,
    pinned: Bool,
    archived: Bool,
    tags: List(String),
    created_s: Int,
    last_active_s: Int,
    message_count: Int,
  )
}

/// All stored session summaries, ordered by id (the registry re-sorts).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_summaries(
  db: pog.Connection,
) -> Result(pog.Returned(ListSummariesRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use title <- decode.field(1, decode.string)
    use title_source <- decode.field(2, decode.string)
    use model <- decode.field(3, decode.string)
    use pinned <- decode.field(4, decode.bool)
    use archived <- decode.field(5, decode.bool)
    use tags <- decode.field(6, decode.list(decode.string))
    use created_s <- decode.field(7, decode.int)
    use last_active_s <- decode.field(8, decode.int)
    use message_count <- decode.field(9, decode.int)
    decode.success(ListSummariesRow(
      id:,
      title:,
      title_source:,
      model:,
      pinned:,
      archived:,
      tags:,
      created_s:,
      last_active_s:,
      message_count:,
    ))
  }

  "-- All stored session summaries, ordered by id (the registry re-sorts).
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
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `load_messages` query
/// defined in `./src/nexus/store/sql/load_messages.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LoadMessagesRow {
  LoadMessagesRow(
    seq: Int,
    role: String,
    content: String,
    tool_call_id: Option(String),
    tool_name: Option(String),
    tool_args: Option(String),
    tool_ok: Option(Bool),
    message_count: Int,
  )
}

/// One session's messages in append-only order, with the session's
/// denormalized message_count (the authoritative persisted transcript
/// length, including the system prompt — a multi-call assistant message is
/// one message but several rows, so rows alone would undercount).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn load_messages(
  db: pog.Connection,
  m_session_id: String,
) -> Result(pog.Returned(LoadMessagesRow), pog.QueryError) {
  let decoder = {
    use seq <- decode.field(0, decode.int)
    use role <- decode.field(1, decode.string)
    use content <- decode.field(2, decode.string)
    use tool_call_id <- decode.field(3, decode.optional(decode.string))
    use tool_name <- decode.field(4, decode.optional(decode.string))
    use tool_args <- decode.field(5, decode.optional(decode.string))
    use tool_ok <- decode.field(6, decode.optional(decode.bool))
    use message_count <- decode.field(7, decode.int)
    decode.success(LoadMessagesRow(
      seq:,
      role:,
      content:,
      tool_call_id:,
      tool_name:,
      tool_args:,
      tool_ok:,
      message_count:,
    ))
  }

  "-- One session's messages in append-only order, with the session's
-- denormalized message_count (the authoritative persisted transcript
-- length, including the system prompt — a multi-call assistant message is
-- one message but several rows, so rows alone would undercount).
select m.seq, m.role, m.content, m.tool_call_id, m.tool_name, m.tool_args, m.tool_ok, s.message_count
from session_message m
join session s on s.id = m.session_id
where m.session_id = $1
order by m.seq
"
  |> pog.query
  |> pog.parameter(pog.text(m_session_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `set_pinned` query
/// defined in `./src/nexus/store/sql/set_pinned.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn set_pinned(
  db: pog.Connection,
  pinned: Bool,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update session set pinned = $1
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.bool(pinned))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `set_tags` query
/// defined in `./src/nexus/store/sql/set_tags.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn set_tags(
  db: pog.Connection,
  tags: List(String),
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update session set tags = $1
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, tags))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `set_title` query
/// defined in `./src/nexus/store/sql/set_title.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn set_title(
  db: pog.Connection,
  arg_1: String,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update session set title = $1, title_source = 'manual'
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `unarchive` query
/// defined in `./src/nexus/store/sql/unarchive.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn unarchive(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update session set archived_at = null
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
