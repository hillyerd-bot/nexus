//// The `http_fetch` tool adapter (M3): the model may fetch one public
//// http/https URL per call, under the SSRF/size/time policy in
//// `nexus/net`.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result
import glopenai/chat
import glopenai/shared.{FunctionObject}
import nexus/net

const description =
  "Fetch a public http(s) URL and return the response "
  <> "body (truncated). Use for reading documentation pages and APIs."

const parameters =
  "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":"
  <> "\"string\",\"description\":\"Absolute http:// or https:// URL to "
  <> "fetch\"}},\"required\":[\"url\"]}"

pub fn schema() -> chat.ChatCompletionTool {
  let parameters = case json.parse(parameters, decode.dynamic) {
    Ok(dynamic) -> Some(dynamic)
    Error(_) -> option.None
  }
  chat.FunctionTool(function: FunctionObject(
    name: "http_fetch",
    description: Some(description),
    parameters: parameters,
    strict: option.None,
  ))
}

pub fn run(
  max_bytes: Int,
  timeout_ms: Int,
  allow_private: Bool,
) -> fn(String) -> Result(String, String) {
  fn(arguments: String) {
    use url <- result.try(parse_url(arguments))
    use response <- result.try(
      net.fetch(
        url,
        [],
        max_bytes,
        timeout_ms,
        allow_private,
        // Manual, re-validated redirects, tightly bounded.
        3,
      )
      |> result.map_error(fn(reason) {
        // net.fetch errors never carry credentials (none are sent).
        "fetch failed: " <> reason
      }),
    )
    // Non-2xx statuses are data, not transport errors: the model can react.
    case response.status {
      _ if response.status >= 200 && response.status < 300 ->
        Ok(
          json.object([
            #("status", json.int(response.status)),
            #("content_type", json.string(response.content_type)),
            #("truncated", json.bool(response.truncated)),
            // The body is already byte-capped by the FFI; it is returned as
            // inert JSON string content, never executed or rendered raw.
            #("body", json.string(response.body)),
          ])
          |> json.to_string,
        )
      status ->
        Error(
          json.object([
            #("status", json.int(status)),
            #("error", json.string("non-success status")),
          ])
          |> json.to_string,
        )
    }
  }
}

fn parse_url(arguments: String) -> Result(String, String) {
  let decoder = {
    use url <- decode.field("url", decode.string)
    decode.success(url)
  }
  case json.parse(arguments, decoder) {
    Ok(url) -> Ok(url)
    Error(_) -> Error("arguments must be JSON with a string \"url\" field")
  }
}
