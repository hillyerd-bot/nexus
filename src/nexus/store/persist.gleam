//// The pog-backed store implementation behind the `nexus/store` seam: a
//// supervised actor owning one Postgres connection pool (pog over pgo)
//// and the per-session write-behind bookkeeping.
////
//// Boot starts this actor BEFORE the registry (persistence is mandatory —
//// there is no ephemeral fallback; if the pool cannot start, boot fails).
//// Reads and metadata writes are synchronous `actor.call`s from the
//// registry; turn commits arrive as fire-and-forget `Commit` messages
//// from the session actors' injected commit hooks and are applied
//// strictly in arrival order, which preserves per-session seq order.
////
//// The SQL itself lives in `src/nexus/store/sql/*.sql` and is turned into
//// typed Gleam by squirrel (`gleam run -m squirrel`); the generated
//// `nexus/store/sql` module is committed and drift-gated in CI via
//// `gleam run -m squirrel check`.
////
//// Idempotency / recovery:
//// - every message insert carries `on conflict (session_id, seq) do
////   nothing`, so replaying a commit after a crash re-inserts nothing;
//// - `last_active_at` / `message_count` are written as absolute values
////   (now() / the committed transcript length), so a replayed bump is a
////   no-op;
//// - the persisted-length bookkeeping is in-memory; if this actor
////   restarts it re-derives each session's length from the session's
////   denormalized message_count on the next commit, never from guesswork.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import nexus/config.{type Config}
import nexus/session
import nexus/store
import nexus/store/sql
import nexus/transcript.{type Transcript}
import pog

pub type Msg {
  ListSummaries(reply: Subject(Result(List(store.StoredSummary), String)))
  GetSession(id: String, reply: Subject(Result(store.StoredSession, String)))
  LoadMessages(
    id: String,
    reply: Subject(Result(List(store.MessageRow), String)),
  )
  InsertSession(
    summary: store.StoredSummary,
    system_prompt: String,
    reply: Subject(Result(Nil, String)),
  )
  /// Write-behind turn commit (fire-and-forget, ordered by arrival).
  Commit(id: String, transcript: Transcript)
  SetTitle(id: String, title: String, reply: Subject(Result(Nil, String)))
  AutoTitle(id: String, title: String, reply: Subject(Result(Bool, String)))
  SetTags(id: String, tags: List(String), reply: Subject(Result(Nil, String)))
  SetPinned(id: String, pinned: Bool, reply: Subject(Result(Nil, String)))
  Archive(id: String, reply: Subject(Result(Nil, String)))
  Unarchive(id: String, reply: Subject(Result(Nil, String)))
  DeleteSession(id: String, reply: Subject(Result(Nil, String)))
}

type State {
  State(
    db: pog.Connection,
    /// Chronological transcript length (including the system prompt)
    /// already persisted per session. `-1` marks a session whose row is
    /// known absent — commits are dropped for it until it is created.
    persisted: Dict(String, Int),
  )
}

const call_timeout_ms = 15_000

/// Start the store actor with its own pog pool (linked: if the actor dies
/// the pool dies with it and supervision restarts both).
pub fn start(
  cfg: Config,
  name: process.Name(Msg),
) -> actor.StartResult(Subject(Msg)) {
  let builder =
    actor.new_with_initialiser(10_000, fn(self) {
      let pg_config =
        pog.default_config(pool_name: process.new_name("nexus_store_pool"))
        |> pog.host(cfg.pg_host)
        |> pog.port(cfg.pg_port)
        |> pog.database(cfg.pg_database)
        |> pog.user(cfg.pg_user)
      let pg_config = pog.password(pg_config, cfg.pg_password)
      // Hygiene only (the schema is timestamptz and every read goes
      // through extract(epoch ...)); pinning keeps ad-hoc renders and any
      // future naive-typed debugging deterministic.
      let pg_config = pog.connection_parameter(pg_config, "timezone", "UTC")
      case pog.start(pg_config) {
        Ok(started) ->
          actor.initialised(State(db: started.data, persisted: dict.new()))
          |> actor.returning(self)
          |> Ok
        Error(reason) ->
          // Fail fast and loudly: persistence is mandatory, there is no
          // silent ephemeral mode (see README env table).
          panic as {
            "nexus store: could not start Postgres pool on "
            <> cfg.pg_host
            <> ":"
            <> int.to_string(cfg.pg_port)
            <> " ("
            <> start_error_text(reason)
            <> ") — is the database up? see docker-compose.yml"
          }
      }
    })
    |> actor.on_message(handle)
    |> actor.named(name)
  actor.start(builder)
}

fn start_error_text(reason: actor.StartError) -> String {
  case reason {
    actor.InitFailed(message) -> message
    _ -> "start failed"
  }
}

/// Child specification for the boot supervision tree (first child: the
/// registry resolves the seam by name afterwards).
pub fn supervised(
  cfg: Config,
  name: process.Name(Msg),
) -> actor.StartResult(Subject(Msg)) {
  start(cfg, name)
}

/// Build the swappable seam over a started store actor.
pub fn seam(store_actor: Subject(Msg)) -> store.Store {
  store.Store(
    list_summaries: fn() {
      actor.call(store_actor, call_timeout_ms, ListSummaries)
    },
    get_session: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        GetSession(id, reply)
      })
    },
    load_messages: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        LoadMessages(id, reply)
      })
    },
    insert_session: fn(summary, system_prompt) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        InsertSession(summary, system_prompt, reply)
      })
    },
    commit: fn(id, transcript) {
      process.send(store_actor, Commit(id, transcript))
    },
    set_title: fn(id, title) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        SetTitle(id, title, reply)
      })
    },
    auto_title: fn(id, title) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        AutoTitle(id, title, reply)
      })
    },
    set_tags: fn(id, tags) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        SetTags(id, tags, reply)
      })
    },
    set_pinned: fn(id, pinned) -> Result(Nil, String) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        SetPinned(id, pinned, reply)
      })
    },
    archive: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) { Archive(id, reply) })
    },
    unarchive: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        Unarchive(id, reply)
      })
    },
    delete_session: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        DeleteSession(id, reply)
      })
    },
  )
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    ListSummaries(reply) -> {
      let result =
        sql.list_summaries(state.db)
        |> result.map(fn(returned) {
          returned.rows |> list.map(stored_summary_from_row)
        })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    GetSession(id, reply) -> {
      let result = case sql.get_session(state.db, id) {
        Error(error) -> Error(query_error(error))
        Ok(pog.Returned(_, rows)) ->
          case rows {
            [row] ->
              Ok(store.StoredSession(
                summary: store.StoredSummary(
                  id: row.id,
                  title: row.title,
                  title_source: title_source(row.title_source),
                  model: row.model,
                  pinned: row.pinned,
                  archived: row.archived,
                  tags: row.tags,
                  created_at: row.created_s,
                  last_active_at: row.last_active_s,
                  // The column already counts the system prompt
                  // (Phase 1 semantics).
                  message_count: row.message_count,
                ),
                system_prompt: row.system_prompt,
              ))
            _ -> Error("no stored session " <> id)
          }
      }
      process.send(reply, result)
      actor.continue(state)
    }

    LoadMessages(id, reply) -> {
      let result =
        sql.load_messages(state.db, id)
        |> result.map(fn(returned) {
          let rows = returned.rows
          // The joined message_count is the authoritative persisted
          // transcript length (rows undercount when a message carried
          // several tool calls).
          let persisted = case list.last(rows) {
            Ok(row) -> row.message_count
            Error(_) -> 1
          }
          #(rows |> list.map(message_row_from_row), persisted)
        })
        |> result.map_error(query_error)
      case result {
        Ok(#(rows, persisted)) -> {
          process.send(reply, Ok(rows))
          actor.continue(
            State(
              ..state,
              persisted: dict.insert(state.persisted, id, persisted),
            ),
          )
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }

    InsertSession(summary, system_prompt, reply) -> {
      let result =
        sql.insert_session(
          state.db,
          summary.id,
          summary.title,
          title_source_text(summary.title_source),
          summary.model,
          system_prompt,
          summary.pinned,
          summary.tags,
          int.to_float(summary.created_at),
          summary.message_count,
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(query_error)
      let state = case result {
        Ok(_) ->
          State(
            ..state,
            persisted: dict.insert(
              state.persisted,
              summary.id,
              summary.message_count,
            ),
          )
        Error(_) -> state
      }
      process.send(reply, result)
      actor.continue(state)
    }

    Commit(id, tr) -> handle_commit(state, id, tr)

    SetTitle(id, title, reply) -> {
      process.send(reply, update(sql.set_title(state.db, title, id)))
      actor.continue(state)
    }

    AutoTitle(id, title, reply) -> {
      let result =
        sql.auto_title(state.db, title, id)
        |> result.map(fn(returned) { returned.count > 0 })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    SetTags(id, tags, reply) -> {
      process.send(reply, update(sql.set_tags(state.db, tags, id)))
      actor.continue(state)
    }

    SetPinned(id, pinned, reply) -> {
      process.send(reply, update(sql.set_pinned(state.db, pinned, id)))
      actor.continue(state)
    }

    Archive(id, reply) -> {
      process.send(reply, update(sql.archive(state.db, id)))
      actor.continue(state)
    }

    Unarchive(id, reply) -> {
      process.send(reply, update(sql.unarchive(state.db, id)))
      actor.continue(state)
    }

    DeleteSession(id, reply) -> {
      process.send(reply, update(sql.delete_session(state.db, id)))
      actor.continue(
        State(..state, persisted: dict.delete(state.persisted, id)),
      )
    }
  }
}

/// The write-behind lane: append the transcript's unpersisted delta in seq
/// order, then bump recency + the denormalized count. Any row failure
/// keeps the old persisted length so the next commit retries the delta
/// (idempotent: duplicate seqs are skipped in SQL).
fn handle_commit(
  state: State,
  id: String,
  tr: Transcript,
) -> actor.Next(State, Msg) {
  case ensure_persisted(state, id) {
    Error(_) -> actor.continue(state)
    Ok(state) -> {
      let already = dict.get(state.persisted, id) |> result.unwrap(1)
      case store.has_delta(tr, already) {
        False -> actor.continue(state)
        True -> {
          let rows = store.transcript_rows(tr, already)
          let total = transcript.length(tr)
          let outcome =
            list.index_fold(rows, Ok(Nil), fn(acc, row, index) {
              case acc {
                Error(error) -> Error(error)
                Ok(_) ->
                  append_row(state.db, id, already - 1 + index, row)
                  |> result.map(fn(_) { Nil })
                  |> result.map_error(query_error)
              }
            })
          case outcome {
            Ok(_) -> {
              // Absolute values: replaying this bump is a no-op.
              let _ =
                sql.bump_activity(state.db, total, id)
                |> result.map_error(query_error)
              actor.continue(
                State(
                  ..state,
                  persisted: dict.insert(state.persisted, id, total),
                ),
              )
            }
            Error(error) -> {
              log_store_error("commit " <> id, error)
              actor.continue(state)
            }
          }
        }
      }
    }
  }
}

/// Resolve the persisted length for `id`, re-deriving it from the database
/// when unknown (first commit after this actor restarted, or a session
/// created before it existed). Sessions with no row at all are marked
/// dropped (`-1`) so their commit lane stays quiet instead of spamming
/// foreign-key errors.
fn ensure_persisted(state: State, id: String) -> Result(State, Nil) {
  case dict.get(state.persisted, id) {
    Ok(_) -> Ok(state)
    Error(_) ->
      case sql.get_session(state.db, id) {
        // The session's denormalized message_count is the safe source:
        // it only ever advances after the corresponding rows were
        // written, so it can lag but never lead — a lagging value just
        // re-emits rows that `on conflict do nothing` skips.
        Ok(pog.Returned(_, [row])) ->
          Ok(
            State(
              ..state,
              persisted: dict.insert(state.persisted, id, row.message_count),
            ),
          )
        Ok(_) -> Ok(state)
        Error(_) -> {
          log_store_error(
            "commit " <> id,
            "no stored session row — dropping its write-behind commits",
          )
          Ok(State(..state, persisted: dict.insert(state.persisted, id, -1)))
        }
      }
  }
}

fn append_row(
  db: pog.Connection,
  id: String,
  seq: Int,
  row: store.MessageRow,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  case row {
    store.UserRow(content) ->
      sql.append_plain_message(db, id, seq, "user", content)
    store.AssistantRow(content) ->
      sql.append_plain_message(db, id, seq, "assistant", content)
    store.ToolCallRow(content, call_id, name, arguments) ->
      sql.append_tool_call(db, id, seq, content, call_id, name, arguments)
    store.ToolResultRow(call_id, name, ok, content) ->
      sql.append_tool_result(db, id, seq, content, call_id, name, ok)
  }
}

/// Metadata write-through outcome: errors are logged and surfaced, never
/// fatal — the in-memory record stays authoritative while live.
fn update(
  query: Result(pog.Returned(Nil), pog.QueryError),
) -> Result(Nil, String) {
  case query {
    Ok(_) -> Ok(Nil)
    Error(error) -> {
      let error = query_error(error)
      log_store_error("metadata write-through", error)
      Error(error)
    }
  }
}

fn log_store_error(context: String, error: String) -> Nil {
  io.println("nexus store: " <> context <> " failed: " <> error)
}

fn query_error(error: pog.QueryError) -> String {
  case error {
    pog.ConstraintViolated(message, constraint, detail) ->
      message <> " (" <> constraint <> "): " <> detail
    pog.PostgresqlError(_, name, message) -> name <> ": " <> message
    pog.UnexpectedArgumentCount(expected, got) ->
      "argument count mismatch: expected "
      <> int.to_string(expected)
      <> ", got "
      <> int.to_string(got)
    pog.UnexpectedArgumentType(expected, got) ->
      "argument type mismatch: expected " <> expected <> ", got " <> got
    pog.UnexpectedResultType(_) -> "unexpected result type"
    pog.QueryTimeout -> "query timeout"
    pog.ConnectionUnavailable -> "connection unavailable"
  }
}

fn stored_summary_from_row(row: sql.ListSummariesRow) -> store.StoredSummary {
  store.StoredSummary(
    id: row.id,
    title: row.title,
    title_source: title_source(row.title_source),
    model: row.model,
    pinned: row.pinned,
    archived: row.archived,
    tags: row.tags,
    created_at: row.created_s,
    last_active_at: row.last_active_s,
    // The column already counts the system prompt (Phase 1 semantics).
    message_count: row.message_count,
  )
}

fn message_row_from_row(row: sql.LoadMessagesRow) -> store.MessageRow {
  let name = row.tool_name |> option.unwrap("tool")
  case row.role, row.tool_call_id {
    "user", _ -> store.UserRow(row.content)
    "assistant", Some(call_id) ->
      store.ToolCallRow(
        content: row.content,
        call_id: call_id,
        name: name,
        arguments: row.tool_args |> option.unwrap(""),
      )
    "assistant", None -> store.AssistantRow(row.content)
    "tool", Some(call_id) ->
      store.ToolResultRow(
        call_id: call_id,
        name: name,
        ok: row.tool_ok |> option.unwrap(True),
        content: row.content,
      )
    "tool", None ->
      store.ToolResultRow(
        call_id: "",
        name: name,
        ok: row.tool_ok |> option.unwrap(True),
        content: row.content,
      )
    _, _ -> store.AssistantRow(row.content)
  }
}

fn title_source(text: String) -> session.TitleSource {
  case text {
    "manual" -> session.ManualTitle
    _ -> session.AutoTitle
  }
}

fn title_source_text(source: session.TitleSource) -> String {
  case source {
    session.ManualTitle -> "manual"
    session.AutoTitle -> "auto"
  }
}
