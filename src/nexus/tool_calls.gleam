//// Pure accumulator for streamed native tool-call deltas (spike B).
////
//// OpenAI-compatible backends stream tool calls as `tool_calls` chunks on
//// the delta, keyed by `index`: the first chunk usually carries `id` and
//// `function.name`, subsequent chunks append fragments of
//// `function.arguments` (which must be concatenated before JSON parsing).
//// Continuation chunks frequently omit `id` and `name` — this accumulator
//// keeps whatever it has seen per index and never discards prior state.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import glopenai/chat.{type ToolCallChunk}

/// A fully assembled tool call, ready to execute locally.
pub type ToolCall {
  ToolCall(
    index: Int,
    id: Option(String),
    name: Option(String),
    arguments: String,
  )
}

pub opaque type Accumulator {
  Accumulator(partials: Dict(Int, ToolCall))
}

pub fn new() -> Accumulator {
  Accumulator(dict.new())
}

/// Fold a whole batch of chunks (one SSE delta can carry several).
pub fn push_all(
  accumulator: Accumulator,
  chunks: List(ToolCallChunk),
) -> Accumulator {
  list.fold(chunks, accumulator, push)
}

pub fn push(accumulator: Accumulator, chunk: ToolCallChunk) -> Accumulator {
  let chat.ToolCallChunk(index, id, function) = chunk
  let #(name, arguments) = case function {
    Some(chat.FunctionCallStream(name, arguments)) -> #(name, arguments)
    None -> #(None, None)
  }
  let existing = case dict.get(accumulator.partials, index) {
    Ok(partial) -> partial
    Error(_) -> ToolCall(index: index, id: None, name: None, arguments: "")
  }
  let id = case id {
    Some(_) -> id
    None -> existing.id
  }
  let name = case name {
    Some(_) -> name
    None -> existing.name
  }
  let arguments = existing.arguments <> option.unwrap(arguments, "")
  Accumulator(dict.insert(
    accumulator.partials,
    index,
    ToolCall(index: index, id: id, name: name, arguments: arguments),
  ))
}

/// All assembled calls ordered by stream index.
pub fn tool_calls(accumulator: Accumulator) -> List(ToolCall) {
  accumulator.partials
  |> dict.values
  |> list.sort(fn(a, b) { int.compare(a.index, b.index) })
}

/// A call is usable when it has an id, a name, and JSON-parseable arguments
/// (the wire format sends `"{}"`-style or object fragments, never raw text).
pub fn is_complete(tool_call: ToolCall) -> Bool {
  option.is_some(tool_call.id)
  && option.is_some(tool_call.name)
  && valid_arguments(tool_call)
}

pub fn valid_arguments(tool_call: ToolCall) -> Bool {
  case json.parse(tool_call.arguments, decode.dynamic) {
    Ok(_) -> True
    Error(_) -> False
  }
}
