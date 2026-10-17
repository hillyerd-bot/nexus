//// Schema migration runner: applies `sql/schema.sql` to the database in
//// `DATABASE_URL` (the same convention squirrel uses).
////
//// Two supported apply paths (README documents both):
//// - docker compose first boot mounts `sql/schema.sql` at
////   `/docker-entrypoint-initdb.d/` and the postgres image applies it
////   once on an empty volume;
//// - this runner is the re-apply path for schema changes and the CI
////   service container:
////
////     DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus \
////       gleam run -m nexus/store/migrate
////
//// The schema is written idempotently (`create table if not exists`), so
//// re-running is safe. Statement splitting is naive on ';' after
//// stripping `--` comments — sufficient for this schema, which contains
//// no semicolons inside literals.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import pog

@external(erlang, "nexus_store_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "nexus_store_ffi", "database_url")
fn database_url() -> Result(String, Nil)

pub fn main() -> Nil {
  let schema =
    or_panic(read_file("sql/schema.sql"), "cannot read sql/schema.sql")
  let url = or_panic(database_url(), "DATABASE_URL is not set")
  let config =
    or_panic(
      pog.url_config(process.new_name("nexus_migrate"), url),
      "invalid DATABASE_URL",
    )
  let started =
    or_panic(
      pog.start(pog.connection_parameter(config, "timezone", "UTC")),
      "could not connect — is the database up?",
    )
  let db = started.data
  let stmts = statements(schema)
  case stmts {
    [] -> io.println("migrate: schema file contains no statements (?)")
    _ ->
      list.each(stmts, fn(statement) {
        case
          statement
          |> pog.query
          |> pog.returning(decode.dynamic)
          |> pog.execute(db)
        {
          Ok(_) -> io.println("migrate: applied: " <> summarize(statement))
          Error(error) -> {
            io.println(
              "migrate: FAILED: "
              <> summarize(statement)
              <> " — "
              <> string.inspect(error),
            )
            panic as "migrate: statement failed"
          }
        }
      })
  }
  io.println(
    "migrate: done (" <> int.to_string(list.length(stmts)) <> " statements)",
  )
}

fn or_panic(result: Result(a, e), message: String) -> a {
  case result {
    Ok(value) -> value
    Error(reason) -> {
      io.println("migrate: " <> message <> " — " <> string.inspect(reason))
      panic as "migrate failed"
    }
  }
}

/// Strip `--` comments, split on ';', drop empties.
fn statements(schema: String) -> List(String) {
  schema
  |> string.split("\n")
  |> list.map(fn(line) {
    case string.split_once(line, "--") {
      Ok(#(code, _comment)) -> code
      Error(_) -> line
    }
  })
  |> string.join("\n")
  |> string.split(";")
  |> list.map(string.trim)
  |> list.filter(fn(statement) { statement != "" })
}

/// First non-empty line, truncated for the log.
fn summarize(statement: String) -> String {
  statement
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.first
  |> fn(first) {
    case first {
      Ok(line) -> string.slice(string.trim(line), 0, 72)
      Error(_) -> string.slice(statement, 0, 72)
    }
  }
}
