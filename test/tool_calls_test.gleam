//// Accumulator unit tests from realistic streamed tool-call chunk fixtures
//// (shapes observed from OpenAI-compatible backends: llama.cpp, vLLM).
//// Pure and network-free.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import glopenai/chat
import nexus/tool_calls

fn chunk(
  index index: Int,
  id id: Option(String),
  name name: Option(String),
  arguments arguments: Option(String),
) -> chat.ToolCallChunk {
  chat.ToolCallChunk(
    index: index,
    id: id,
    function: case name == None && arguments == None {
      True -> None
      False -> Some(chat.FunctionCallStream(name: name, arguments: arguments))
    },
  )
}

fn accumulate(chunks: List(chat.ToolCallChunk)) -> tool_calls.Accumulator {
  tool_calls.push_all(tool_calls.new(), chunks)
}

/// The canonical single-call shape: one header chunk, argument fragments.
pub fn single_call_fragments_test() {
  let acc =
    accumulate([
      chunk(0, Some("call_1"), Some("get_time"), Some("")),
      chunk(0, None, None, Some("{\"time")),
      chunk(0, None, None, Some("zone\":\"UTC\"}")),
    ])
  should.equal(tool_calls.tool_calls(acc), [
    tool_calls.ToolCall(
      index: 0,
      id: Some("call_1"),
      name: Some("get_time"),
      arguments: "{\"timezone\":\"UTC\"}",
    ),
  ])
}

/// Two calls interleaved by index.
pub fn multiple_calls_interleaved_test() {
  let acc =
    accumulate([
      chunk(0, Some("call_a"), Some("get_time"), Some("")),
      chunk(1, Some("call_b"), Some("http_fetch"), Some("{\"u")),
      chunk(0, None, None, Some("{}")),
      chunk(1, None, None, Some("rl\":\"x\"}")),
    ])
  let calls = tool_calls.tool_calls(acc)
  should.equal(list.length(calls), 2)
  let assert [first, second] = calls
  should.equal(first.id, Some("call_a"))
  should.equal(first.arguments, "{}")
  should.equal(second.name, Some("http_fetch"))
  should.equal(second.arguments, "{\"url\":\"x\"}")
}

/// Header chunk arriving with no arguments, then pure argument fragments.
pub fn header_then_args_test() {
  let acc =
    accumulate([
      chunk(0, Some("c1"), Some("get_time"), None),
      chunk(0, None, None, Some("{}")),
    ])
  let assert [call] = tool_calls.tool_calls(acc)
  should.equal(call.arguments, "{}")
}

/// Some backends send the whole call in one chunk.
pub fn single_chunk_whole_call_test() {
  let acc = accumulate([chunk(0, Some("c1"), Some("get_time"), Some("{}"))])
  let assert [call] = tool_calls.tool_calls(acc)
  should.be_true(tool_calls.is_complete(call))
}

/// Missing id or name leaves the call incomplete.
pub fn incomplete_without_id_test() {
  let acc = accumulate([chunk(0, None, Some("get_time"), Some("{}"))])
  let assert [call] = tool_calls.tool_calls(acc)
  should.be_false(tool_calls.is_complete(call))
}

pub fn incomplete_without_name_test() {
  let acc = accumulate([chunk(0, Some("c1"), None, Some("{}"))])
  let assert [call] = tool_calls.tool_calls(acc)
  should.be_false(tool_calls.is_complete(call))
}

/// Split JSON arguments must assemble into a parseable object.
pub fn split_arguments_valid_json_test() {
  let acc =
    accumulate([
      chunk(0, Some("c"), Some("t"), Some("{\"a\"")),
      chunk(0, None, None, Some(":1,\"b\":2}")),
    ])
  let assert [call] = tool_calls.tool_calls(acc)
  should.be_true(tool_calls.valid_arguments(call))
  should.be_true(tool_calls.is_complete(call))
}

pub fn invalid_arguments_detected_test() {
  let acc = accumulate([chunk(0, Some("c"), Some("t"), Some("{not json"))])
  let assert [call] = tool_calls.tool_calls(acc)
  should.be_false(tool_calls.valid_arguments(call))
  should.be_false(tool_calls.is_complete(call))
}

/// Empty arguments string is not valid JSON (no object emitted).
pub fn empty_arguments_test() {
  let acc = accumulate([chunk(0, Some("c"), Some("t"), Some(""))])
  let assert [call] = tool_calls.tool_calls(acc)
  should.equal(call.arguments, "")
  should.be_false(tool_calls.valid_arguments(call))
}

/// Out-of-order indices must still sort by index.
pub fn sorted_by_index_test() {
  let acc =
    accumulate([
      chunk(2, Some("c2"), Some("two"), Some("{}")),
      chunk(0, Some("c0"), Some("zero"), Some("{}")),
      chunk(1, Some("c1"), Some("one"), Some("{}")),
    ])
  let calls = tool_calls.tool_calls(acc)
  should.equal(list.length(calls), 3)
  let assert [first, ..] = calls
  should.equal(first.index, 0)
}

/// Missing `function` object entirely (id only) is tolerated.
pub fn missing_function_object_test() {
  let acc = accumulate([chunk(0, Some("c"), None, None)])
  let assert [call] = tool_calls.tool_calls(acc)
  should.equal(call.name, None)
  should.equal(call.arguments, "")
}

/// Incremental pushes equal one batched push_all.
pub fn push_matches_push_all_test() {
  let chunks = [
    chunk(0, Some("c"), Some("t"), Some("{\"k")),
    chunk(0, None, None, Some("\":\"v\"}")),
  ]
  let incremental =
    tool_calls.new()
    |> tool_calls.push(chunks |> list.first |> unwrap_chunk)
    |> tool_calls.push(chunks |> list.drop(1) |> list.first |> unwrap_chunk)
  let batched = accumulate(chunks)
  should.equal(
    tool_calls.tool_calls(incremental),
    tool_calls.tool_calls(batched),
  )
}

fn unwrap_chunk(c: Result(chat.ToolCallChunk, Nil)) -> chat.ToolCallChunk {
  case c {
    Ok(chunk) -> chunk
    Error(_) -> panic as "fixture error"
  }
}
