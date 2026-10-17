//// The `web_search` tool adapter (M3): SearxNG-backed search.
////
//// The SearxNG base URL and optional bearer token come from the global
//// config (admin-controlled, not model-controlled), so no SSRF guard is
//// needed here — but the token is only ever placed in the Authorization
//// header: it must never appear in result content or error strings.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import glopenai/chat
import glopenai/shared.{FunctionObject}
import nexus/net

const description =
  "Search the web and return the top results (title, "
  <> "url, snippet). Use for current information instead of guessing."

const parameters =
  "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":"
  <> "\"string\",\"description\":\"The search query\"}},\"required\":"
  <> "[\"query\"]}"

/// Results kept per call, and the byte cap on the SearxNG response body
/// (defensive; the JSON API returns small payloads).
const max_results = 5

const searxng_max_bytes = 200_000

pub fn schema() -> chat.ChatCompletionTool {
  let params = case json.parse(parameters, decode.dynamic) {
    Ok(dynamic) -> Some(dynamic)
    Error(_) -> None
  }
  chat.FunctionTool(function: FunctionObject(
    name: "web_search",
    description: Some(description),
    parameters: params,
    strict: None,
  ))
}

pub fn run(
  base_url: String,
  token: Option(String),
  timeout_ms: Int,
) -> fn(String) -> Result(String, String) {
  fn(arguments: String) {
    use query <- result.try(parse_query(arguments))
    use response <- result.try(request(base_url, token, query, timeout_ms))
    use results <- result.try(parse_results(response.body))
    Ok(render(results))
  }
}

fn request(
  base_url: String,
  token: Option(String),
  query: String,
  timeout_ms: Int,
) -> Result(net.FetchResponse, String) {
  let url =
    trim_slashes(base_url) <> "/search?format=json&q=" <> percent_encode(query)
  // The token rides only in this header; error strings below carry the
  // status/transport reason, never headers or credentials.
  let headers = case token {
    Some(value) -> [#("authorization", "Bearer " <> value)]
    None -> []
  }
  // No SSRF guard: the base URL is admin configuration, and tests point it
  // at loopback services by design.
  case net.fetch(url, headers, searxng_max_bytes, timeout_ms, True, 2) {
    Ok(response) ->
      case response.status {
        200 -> Ok(response)
        status ->
          Error("search backend returned status " <> int.to_string(status))
      }
    // Only the failure reason, which cannot contain the header value.
    Error(reason) -> Error("search failed: " <> reason)
  }
}

type SearchHit {
  SearchHit(title: String, url: String, snippet: String)
}

fn parse_results(body: String) -> Result(List(SearchHit), String) {
  let hit = {
    use title <- decode.optional_field("title", "", decode.string)
    use url <- decode.optional_field("url", "", decode.string)
    use content <- decode.optional_field("content", "", decode.string)
    decode.success(SearchHit(title, url, content))
  }
  let decoder = {
    use results <- decode.field("results", decode.list(hit))
    decode.success(results)
  }
  case json.parse(body, decoder) {
    Ok(results) -> Ok(results |> list.take(max_results))
    Error(_) -> Error("search backend returned unparseable results")
  }
}

fn render(results: List(SearchHit)) -> String {
  json.array(results, fn(hit: SearchHit) {
    json.object([
      #("title", json.string(hit.title)),
      #("url", json.string(hit.url)),
      #("snippet", json.string(hit.snippet)),
    ])
  })
  |> json.to_string
}

fn parse_query(arguments: String) -> Result(String, String) {
  let decoder = {
    use query <- decode.field("query", decode.string)
    decode.success(query)
  }
  case json.parse(arguments, decoder) {
    Ok(query) -> Ok(query)
    Error(_) -> Error("arguments must be JSON with a string \"query\" field")
  }
}

fn percent_encode(text: String) -> String {
  text
  |> uri.percent_encode
}

fn trim_slashes(text: String) -> String {
  case string.ends_with(text, "/") {
    True -> string.drop_end(text, 1)
    False -> text
  }
}
