//// A fully functional **in-memory** implementation of the `nexus/store`
//// seam for offline tests: no database, no network, but the real
//// semantics — idempotent write-behind commits (an unchanged or older
//// transcript is a no-op), guarded auto-title, archive-clears-pin,
//// cascade delete, recency bumps. The persistence tests use it as the
//// "external Postgres" that survives a registry teardown, which makes
//// the whole hydrate/restart cycle testable inside plain `gleam test`.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/string
import nexus/session
import nexus/store.{type Store, type StoredSummary}
import nexus/timing
import nexus/transcript.{type Transcript}

/// Recorded seam calls, oldest first — for write-behind ordering and
/// metadata write-through assertions.
pub type Event {
  EvInsertSession(id: String)
  EvCommit(id: String, messages: Int)
  EvSetTitle(id: String, title: String)
  EvAutoTitle(id: String, title: String)
  EvSetTags(id: String, tags: List(String))
  EvSetPinned(id: String, pinned: Bool)
  EvArchive(id: String)
  EvUnarchive(id: String)
  EvDeleteSession(id: String)
}

pub type MockMsg {
  // ---- seam operations (synchronous, Result replies) ----
  ListSummaries(reply: Subject(Result(List(StoredSummary), String)))
  GetSession(id: String, reply: Subject(Result(store.StoredSession, String)))
  LoadMessages(
    id: String,
    reply: Subject(Result(List(store.MessageRow), String)),
  )
  InsertSession(
    summary: StoredSummary,
    system_prompt: String,
    reply: Subject(Result(Nil, String)),
  )
  /// The write-behind lane: fire-and-forget, ordered by arrival. Also the
  /// replay path — applying the same (or an older) transcript again is a
  /// no-op apart from the recency bump.
  Commit(id: String, transcript: Transcript)
  SetTitle(id: String, title: String, reply: Subject(Result(Nil, String)))
  AutoTitle(id: String, title: String, reply: Subject(Result(Bool, String)))
  SetTags(id: String, tags: List(String), reply: Subject(Result(Nil, String)))
  SetPinned(id: String, pinned: Bool, reply: Subject(Result(Nil, String)))
  Archive(id: String, reply: Subject(Result(Nil, String)))
  Unarchive(id: String, reply: Subject(Result(Nil, String)))
  DeleteSession(id: String, reply: Subject(Result(Nil, String)))
  // ---- test-only introspection ----
  Events(reply: Subject(List(Event)))
  Rows(reply: Subject(List(#(String, List(store.MessageRow)))))
  /// Test-only: truncate a session's stored rows back to `keep_rows` and
  /// its persisted message count to `messages` to model a crash between
  /// commits — the next Commit re-emits the delta, which is exactly the
  /// crash-recovery replay the real store makes idempotent.
  Rewind(id: String, keep_rows: Int, messages: Int, reply: Subject(Nil))
}

type Stored {
  Stored(
    summary: StoredSummary,
    system_prompt: String,
    /// Rows in seq order (seq = index).
    rows: List(store.MessageRow),
    /// Persisted chronological transcript length INCLUDING the system
    /// prompt — the write-behind watermark. Message count, not row count:
    /// an assistant message with N tool calls is one message but N rows
    /// (mirrors sessions.message_count in the real schema).
    messages: Int,
  )
}

type State {
  State(sessions: Dict(String, Stored), events: List(Event))
}

/// Start the mock store actor; returns its subject.
pub fn start() -> Subject(MockMsg) {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(self) {
      actor.initialised(State(sessions: dict.new(), events: []))
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  started.data
}

/// The seam over a started mock actor.
pub fn seam(mock: Subject(MockMsg)) -> Store {
  store.Store(
    list_summaries: fn() { call(mock, 5000, ListSummaries) },
    get_session: fn(id) { call(mock, 5000, fn(r) { GetSession(id, r) }) },
    load_messages: fn(id) { call(mock, 5000, fn(r) { LoadMessages(id, r) }) },
    insert_session: fn(summary, system_prompt) {
      call(mock, 5000, fn(r) { InsertSession(summary, system_prompt, r) })
    },
    commit: fn(id, transcript) { process.send(mock, Commit(id, transcript)) },
    set_title: fn(id, title) {
      call(mock, 5000, fn(r) { SetTitle(id, title, r) })
    },
    auto_title: fn(id, title) {
      call(mock, 5000, fn(r) { AutoTitle(id, title, r) })
    },
    set_tags: fn(id, tags) { call(mock, 5000, fn(r) { SetTags(id, tags, r) }) },
    set_pinned: fn(id, pinned) {
      call(mock, 5000, fn(r) { SetPinned(id, pinned, r) })
    },
    archive: fn(id) { call(mock, 5000, fn(r) { Archive(id, r) }) },
    unarchive: fn(id) { call(mock, 5000, fn(r) { Unarchive(id, r) }) },
    delete_session: fn(id) { call(mock, 5000, fn(r) { DeleteSession(id, r) }) },
  )
}

// ---------------------------------------------------------------------------
// Test-side helpers (also through the actor, so ordering stays honest)
// ---------------------------------------------------------------------------

/// The recorded call log, oldest first.
pub fn events(mock: Subject(MockMsg)) -> List(Event) {
  call(mock, 5000, Events)
}

/// Every session's rows, id-sorted — for direct row assertions.
pub fn rows(mock: Subject(MockMsg)) -> List(#(String, List(store.MessageRow))) {
  call(mock, 5000, Rows)
}

/// Truncate a session's stored rows (models a crash between commits so
/// the next Commit replays).
pub fn rewind(
  mock: Subject(MockMsg),
  id: String,
  keep_rows: Int,
  messages: Int,
) -> Nil {
  call(mock, 5000, fn(r) { Rewind(id, keep_rows, messages, r) })
}

/// Wait until the mock has observed at least `n` commits — commits are
/// fire-and-forget, so tests synchronize on their effect. Gives up (and
/// fails the awaiting assertion) after ~5s.
pub fn await_commits(mock: Subject(MockMsg), n: Int) -> Nil {
  await_commits_loop(mock, n, 500)
}

fn await_commits_loop(mock: Subject(MockMsg), n: Int, patience: Int) -> Nil {
  let commits =
    events(mock)
    |> list.filter(fn(event) {
      case event {
        EvCommit(_, _) -> True
        _ -> False
      }
    })
  case list.length(commits) >= n, patience {
    True, _ -> Nil
    False, 0 -> Nil
    False, _ -> {
      process.sleep(10)
      await_commits_loop(mock, n, patience - 1)
    }
  }
}

fn call(
  mock: Subject(MockMsg),
  timeout: Int,
  make: fn(Subject(a)) -> MockMsg,
) -> a {
  actor.call(mock, timeout, make)
}

// ---------------------------------------------------------------------------
// The actor
// ---------------------------------------------------------------------------

fn handle(state: State, msg: MockMsg) -> actor.Next(State, MockMsg) {
  case msg {
    ListSummaries(reply) -> {
      let summaries =
        state.sessions
        |> dict.values
        |> list.map(fn(stored) { stored.summary })
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, Ok(summaries))
      actor.continue(state)
    }

    GetSession(id, reply) ->
      case dict.get(state.sessions, id) {
        Ok(stored) -> {
          process.send(
            reply,
            Ok(store.StoredSession(
              summary: stored.summary,
              system_prompt: stored.system_prompt,
            )),
          )
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error("no stored session " <> id))
          actor.continue(state)
        }
      }

    LoadMessages(id, reply) ->
      case dict.get(state.sessions, id) {
        Ok(stored) -> {
          process.send(reply, Ok(stored.rows))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error("no stored session " <> id))
          actor.continue(state)
        }
      }

    InsertSession(summary, system_prompt, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          sessions: dict.insert(
            state.sessions,
            summary.id,
            Stored(summary, system_prompt, [], summary.message_count),
          ),
          events: [EvInsertSession(summary.id), ..state.events],
        ),
      )
    }

    Commit(id, transcript) -> {
      let events = [EvCommit(id, transcript.length(transcript)), ..state.events]
      let sessions = case dict.get(state.sessions, id) {
        Error(_) -> state.sessions
        Ok(stored) -> {
          // The delta past what is stored, in seq order; an unchanged or
          // older transcript yields nothing (matching the real store,
          // which does not even bump recency without a delta).
          let already = stored.messages
          case store.has_delta(transcript, already) {
            False -> state.sessions
            True -> {
              let delta = store.transcript_rows(transcript, already)
              let total = transcript.length(transcript)
              dict.insert(
                state.sessions,
                id,
                Stored(
                  ..stored,
                  rows: list.append(stored.rows, delta),
                  messages: total,
                  summary: store.StoredSummary(
                    ..stored.summary,
                    // Absolute values, like bump_activity: idempotent.
                    message_count: total,
                    last_active_at: timing.wall_now_s(),
                  ),
                ),
              )
            }
          }
        }
      }
      actor.continue(State(sessions: sessions, events: events))
    }

    SetTitle(id, title, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(
              ..summary,
              title: title,
              title_source: session.ManualTitle,
            )
          }),
          events: [EvSetTitle(id, title), ..state.events],
        ),
      )
    }

    AutoTitle(id, title, reply) ->
      case dict.get(state.sessions, id) {
        Error(_) -> {
          process.send(reply, Error("no stored session " <> id))
          actor.continue(state)
        }
        Ok(stored) ->
          case stored.summary.title_source, stored.summary.title {
            session.AutoTitle, "" -> {
              process.send(reply, Ok(True))
              actor.continue(
                State(
                  ..update(state, id, fn(summary) {
                    store.StoredSummary(..summary, title: title)
                  }),
                  events: [EvAutoTitle(id, title), ..state.events],
                ),
              )
            }
            _, _ -> {
              process.send(reply, Ok(False))
              actor.continue(state)
            }
          }
      }

    SetTags(id, tags, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(..summary, tags: tags)
          }),
          events: [EvSetTags(id, tags), ..state.events],
        ),
      )
    }

    SetPinned(id, pinned, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(..summary, pinned: pinned)
          }),
          events: [EvSetPinned(id, pinned), ..state.events],
        ),
      )
    }

    Archive(id, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(..summary, archived: True, pinned: False)
          }),
          events: [EvArchive(id), ..state.events],
        ),
      )
    }

    Unarchive(id, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(..summary, archived: False)
          }),
          events: [EvUnarchive(id), ..state.events],
        ),
      )
    }

    DeleteSession(id, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(sessions: dict.delete(state.sessions, id), events: [
          EvDeleteSession(id),
          ..state.events
        ]),
      )
    }

    Events(reply) -> {
      process.send(reply, list.reverse(state.events))
      actor.continue(state)
    }

    Rows(reply) -> {
      let rows =
        state.sessions
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, pair.1.rows) })
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      process.send(reply, rows)
      actor.continue(state)
    }

    Rewind(id, keep_rows, messages, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        update_stored(state, id, fn(stored) {
          Stored(
            ..stored,
            rows: list.take(stored.rows, keep_rows),
            messages: messages,
            summary: store.StoredSummary(
              ..stored.summary,
              message_count: messages,
            ),
          )
        }),
      )
    }
  }
}

fn update(
  state: State,
  id: String,
  f: fn(StoredSummary) -> StoredSummary,
) -> State {
  update_stored(state, id, fn(stored) {
    Stored(..stored, summary: f(stored.summary))
  })
}

fn update_stored(state: State, id: String, f: fn(Stored) -> Stored) -> State {
  case dict.get(state.sessions, id) {
    Ok(stored) ->
      State(..state, sessions: dict.insert(state.sessions, id, f(stored)))
    Error(_) -> state
  }
}
