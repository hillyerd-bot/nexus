//// The M3 tool registry: model-visible schemas paired with local
//// executors.
////
//// The list is built **once per process start** from the global config
//// (loaded from the environment before any session exists — the M3 plan's
//// pre-creation requirement) and handed to the session runner at boot, so
//// the tool schema sent with every request of every session is frozen for
//// the lifetime of the VM. That keeps request prefixes byte-identical
//// across a session's turns (KV-cache contract rule 4).

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glopenai/chat.{type ChatCompletionTool}
import glopenai/shared.{FunctionObject}
import nexus/config.{type Config}
import nexus/http_fetch
import nexus/web_search

/// One tool: its wire schema plus the executor. `run` receives the raw
/// arguments JSON string and returns the tool-result content (already
/// sanitised and truncated) or an error string.
pub type ToolSpec {
  ToolSpec(tool: ChatCompletionTool, run: fn(String) -> Result(String, String))
}

/// The default M3 toolset derived from the global config. `web_search` is
/// registered only when a SearxNG base URL is configured.
pub fn default(cfg: Config) -> List(ToolSpec) {
  let fetch =
    ToolSpec(
      tool: http_fetch.schema(),
      run: http_fetch.run(
        cfg.http_fetch_max_bytes,
        cfg.http_fetch_timeout_ms,
        cfg.http_fetch_allow_private,
      ),
    )
  case cfg.searxng_base_url {
    Some(base) -> [
      fetch,
      ToolSpec(
        tool: web_search.schema(),
        run: web_search.run(base, cfg.searxng_token, cfg.http_fetch_timeout_ms),
      ),
    ]
    None -> [fetch]
  }
}

/// The wire schemas, in registry order — this exact list goes into every
/// request.
pub fn schemas(specs: List(ToolSpec)) -> List(ChatCompletionTool) {
  list.map(specs, fn(spec: ToolSpec) { spec.tool })
}

/// Execute a call by tool name. Unknown tools and failing executors both
/// produce an error rendered as tool content by the agent loop.
pub fn execute(
  specs: List(ToolSpec),
  name: String,
  arguments: String,
) -> Result(String, String) {
  case list.find(specs, fn(spec: ToolSpec) { tool_name(spec) == name }) {
    Error(_) -> Error("unknown tool: " <> name)
    Ok(spec) -> spec.run(arguments)
  }
}

pub fn tool_name(spec: ToolSpec) -> String {
  let chat.FunctionTool(function: function) = spec.tool
  function.name
}

/// Build a function schema from raw JSON parameter-schema text.
pub fn function_tool(
  name name: String,
  description description: String,
  parameters_json parameters_json: String,
) -> ChatCompletionTool {
  let parameters = case json.parse(parameters_json, decode.dynamic) {
    Ok(dynamic) -> Some(dynamic)
    Error(_) -> None
  }
  chat.FunctionTool(function: FunctionObject(
    name: name,
    description: Some(description),
    parameters: parameters,
    strict: None,
  ))
}
