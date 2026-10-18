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
//// re-running is safe. Statements are split by a quote-aware scanner
//// (`statements`), so `;` inside string literals, double-quoted
//// identifiers, dollar-quoted bodies (`CREATE FUNCTION` / `DO`), and
//// comments does not break a statement apart.

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

/// Split a schema script into individual SQL statements on top-level
/// semicolons.
///
/// The scan is quote-aware: a `;` inside a single-quoted literal, a
/// double-quoted identifier, or a dollar-quoted body (`$$...$$`,
/// `$tag$...$tag$`) belongs to the statement, not the separator. This is
/// what lets `CREATE FUNCTION ... $$ ... ; ... $$`, `DO $$ ... $$`, and
/// literals containing `;` survive. `--` line comments and nestable
/// `/* ... */` block comments are stripped too, so a `;` in a comment is
/// inert.
///
/// Escaped quotes (`''` and `""`) are understood. PostgreSQL's default
/// `standard_conforming_strings` is assumed, so a backslash is literal and
/// only doubling escapes a quote (i.e. `E'...'` escape strings are not
/// distinguished).
pub fn statements(schema: String) -> List(String) {
  scan_code(string.to_graphemes(schema), [], []) |> list.reverse
}

fn scan_code(
  chars: List(String),
  current: List(String),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    ["-", "-", ..rest] -> scan_line_comment(rest, current, done)
    ["/", "*", ..rest] -> scan_block_comment(1, rest, current, done)
    ["'", ..rest] -> scan_single(rest, ["'", ..current], done)
    ["\"", ..rest] -> scan_double(rest, ["\"", ..current], done)
    [";", ..rest] -> scan_code(rest, [], finish(current, done))
    ["$", ..rest] ->
      case parse_dollar(rest) {
        Ok(#(tag, after)) ->
          scan_dollar(tag, after, [dollar_delimiter(tag), ..current], done)
        Error(_) -> scan_code(rest, ["$", ..current], done)
      }
    [char, ..rest] -> scan_code(rest, [char, ..current], done)
  }
}

fn scan_single(
  chars: List(String),
  current: List(String),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    ["'", "'", ..rest] -> scan_single(rest, ["'", "'", ..current], done)
    ["'", ..rest] -> scan_code(rest, ["'", ..current], done)
    [char, ..rest] -> scan_single(rest, [char, ..current], done)
  }
}

fn scan_double(
  chars: List(String),
  current: List(String),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    ["\"", "\"", ..rest] -> scan_double(rest, ["\"", "\"", ..current], done)
    ["\"", ..rest] -> scan_code(rest, ["\"", ..current], done)
    [char, ..rest] -> scan_double(rest, [char, ..current], done)
  }
}

fn scan_dollar(
  tag: String,
  chars: List(String),
  current: List(String),
  done: List(String),
) -> List(String) {
  scan_dollar_body(string.to_graphemes(tag <> "$"), tag, chars, current, done)
}

fn scan_dollar_body(
  closing: List(String),
  tag: String,
  chars: List(String),
  current: List(String),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    ["$", ..rest] ->
      case drop_prefix(rest, closing) {
        Ok(after) -> scan_code(after, [dollar_delimiter(tag), ..current], done)
        Error(_) -> scan_dollar_body(closing, tag, rest, ["$", ..current], done)
      }
    [char, ..rest] ->
      scan_dollar_body(closing, tag, rest, [char, ..current], done)
  }
}

fn scan_line_comment(
  chars: List(String),
  current: List(String),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    ["\n", ..rest] -> scan_code(rest, ["\n", ..current], done)
    [_, ..rest] -> scan_line_comment(rest, current, done)
  }
}

fn scan_block_comment(
  depth: Int,
  chars: List(String),
  current: List(String),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    ["/", "*", ..rest] -> scan_block_comment(depth + 1, rest, current, done)
    ["*", "/", ..rest] ->
      case depth {
        1 -> scan_code(rest, [" ", ..current], done)
        _ -> scan_block_comment(depth - 1, rest, current, done)
      }
    [_, ..rest] -> scan_block_comment(depth, rest, current, done)
  }
}

/// Match a dollar-quote opener at `chars` (the text after the leading `$`)
/// and return its tag plus the text after the closing `$`.
fn parse_dollar(chars: List(String)) -> Result(#(String, List(String)), Nil) {
  case chars {
    ["$", ..after] -> Ok(#("", after))
    _ -> parse_dollar_tag(chars, [])
  }
}

fn parse_dollar_tag(
  chars: List(String),
  tag: List(String),
) -> Result(#(String, List(String)), Nil) {
  case chars {
    [] -> Error(Nil)
    [char, ..rest] ->
      case is_tag_char(char, tag) {
        True -> parse_dollar_tag(rest, [char, ..tag])
        False ->
          case char, tag {
            "$", [] -> Error(Nil)
            "$", _ -> Ok(#(string.join(list.reverse(tag), ""), rest))
            _, _ -> Error(Nil)
          }
      }
  }
}

/// A dollar-quote tag is an empty string or an identifier: its first
/// character is an ASCII letter or `_`, later ones may also be digits.
fn is_tag_char(char: String, tag: List(String)) -> Bool {
  case tag {
    [] -> is_letter(char) || char == "_"
    _ -> is_letter(char) || is_digit(char) || char == "_"
  }
}

fn is_letter(char: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", char)
}

fn is_digit(char: String) -> Bool {
  string.contains("0123456789", char)
}

fn dollar_delimiter(tag: String) -> String {
  "$" <> tag <> "$"
}

/// Drop `prefix` from the front of `chars`, or fail if it does not match.
fn drop_prefix(
  chars: List(String),
  prefix: List(String),
) -> Result(List(String), Nil) {
  case prefix {
    [] -> Ok(chars)
    [expected, ..more] ->
      case chars {
        [char, ..rest] if char == expected -> drop_prefix(rest, more)
        _ -> Error(Nil)
      }
  }
}

/// Close the current statement: trim it, keep it if non-empty.
fn finish(current: List(String), done: List(String)) -> List(String) {
  case string.trim(string.join(list.reverse(current), "")) {
    "" -> done
    statement -> [statement, ..done]
  }
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
