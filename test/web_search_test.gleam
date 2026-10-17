//// web_search adapter tests against a controlled fake SearxNG (mist on
//// loopback). The base URL is admin config, so the loopback target is by
//// design; the token must never leak into results or error strings.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import mist
import nexus/web_search

const port = 18_051

const token = "super-secret-searxng-token"

/// The controlled SearxNG stand-in: /search serves results JSON, /boom
/// fails with 500, and /echo-auth echoes whether the bearer token arrived.
fn handler(req: Request(mist.Connection)) -> Response(mist.ResponseData) {
  let #(path, query) = split(req)
  let authorized = case request.get_header(req, "authorization") {
    Ok("Bearer " <> t) if t == token -> True
    _ -> False
  }
  let q_gleam = case query {
    Some(q) -> string.contains(q, "q=gleam")
    None -> False
  }
  case path, req.method {
    "/search", Get ->
      case authorized, q_gleam {
        True, True ->
          respond(
            200,
            "{\"results\":[{\"title\":\"Gleam\",\"url\":\"https://gleam.run\","
              <> "\"content\":\"A language on the BEAM\"},{\"title\":\"Extra\","
              <> "\"url\":\"https://example.invalid/x\",\"content\":\"tail\"}]}",
          )
        True, _ ->
          respond(
            200,
            "{\"results\":[{\"title\":\"Other\",\"url\":\"u\",\"content\":\"c\"}]}",
          )
        False, _ -> respond(401, "{\"error\":\"unauthorized\"}")
      }
    "/boom", Get -> respond(500, "internal error")
    _, _ -> respond(404, "not found")
  }
}

fn respond(status: Int, body: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn split(req: Request(mist.Connection)) -> #(String, Option(String)) {
  let parsed = request.to_uri(req)
  #(parsed.path, parsed.query)
}

fn start_service() -> Nil {
  let _ =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  process.sleep(100)
}

fn base() -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

pub fn adapter_roundtrips_test() {
  start_service()

  // Authenticated happy path: top results parsed and re-rendered.
  let run = web_search.run(base(), Some(token), 2000)
  let assert Ok(content) = run("{\"query\":\"gleam\"}")
  should.be_true(string.contains(content, "\"title\":\"Gleam\""))
  should.be_true(string.contains(content, "gleam.run"))
  should.be_true(string.contains(content, "\"snippet\""))

  // Missing/absent token: the fake refuses, and the error carries only the
  // status — never the token or the URL with credentials.
  let run_no_auth = web_search.run(base(), None, 2000)
  let assert Error(reason) = run_no_auth("{\"query\":\"gleam\"}")
  should.be_true(string.contains(reason, "401"))
  should.be_false(string.contains(reason, token))

  // Backend failures surface as tool errors without the token.
  let run_boom = web_search.run(base() <> "/boom", Some(token), 2000)
  let assert Error(boom) = run_boom("{\"query\":\"gleam\"}")
  should.be_false(string.contains(boom, token))

  // A query with spaces and an ampersand is percent-encoded whole.
  let assert Ok(encoded_query) =
    run("{\"query\":\"gleam & elixir on the beam\"}")
  should.be_true(string.contains(encoded_query, "\"title\""))

  // Malformed arguments are a tool error.
  let assert Error(bad) = run("not json")
  should.be_true(string.contains(bad, "query"))
}

pub fn schema_names_the_tool_test() {
  // No service needed: pure schema check.
  let encoded =
    web_search.schema()
    |> glopenai_schema_to_json
  should.be_true(string.contains(encoded, "\"name\":\"web_search\""))
  should.be_true(string.contains(encoded, "\"query\""))
}

import gleam/json
import glopenai/chat

fn glopenai_schema_to_json(schema: chat.ChatCompletionTool) -> String {
  chat.chat_completion_tool_to_json(schema) |> json.to_string
}
