//// Append-only transcript and the **single request-encoding path** shared
//// by every spike and (later) the product.
////
//// The KV-cache contract requires that re-encoding an unchanged message
//// prefix yields byte-identical request bodies (rule 4). That property is
//// only real if there is exactly one place where requests are built — this
//// module. Messages are stored newest-first (Gleam list idiom) and reversed
//// once at encode time, deterministically, through the glopenai codec whose
//// JSON encoding is field-order-stable and omits absent optional fields.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import glopenai/chat.{type ChatMessage}
import glopenai/shared

/// Options applied on top of the transcript when building a request.
/// Everything here must stay constant across a session's turns except where
/// the cache contract allows tail-only changes.
pub type Options {
  Options(
    stream: Bool,
    tools: List(chat.ChatCompletionTool),
    tool_choice: Option(chat.ToolChoice),
    max_completion_tokens: Option(Int),
    temperature: Option(Float),
  )
}

pub fn default_options() -> Options {
  Options(
    stream: False,
    tools: [],
    tool_choice: None,
    max_completion_tokens: None,
    temperature: None,
  )
}

pub opaque type Transcript {
  Transcript(model: String, messages: List(ChatMessage))
}

/// New transcript: system prompt is frozen at creation (contract rule 2).
pub fn new(model: String, system: String) -> Transcript {
  Transcript(model, [chat.system_message(system)])
}

pub fn model(transcript: Transcript) -> String {
  transcript.model
}

/// Messages in chronological order (oldest first).
pub fn messages(transcript: Transcript) -> List(ChatMessage) {
  list.reverse(transcript.messages)
}

pub fn length(transcript: Transcript) -> Int {
  list.length(transcript.messages)
}

pub fn append_user(transcript: Transcript, text: String) -> Transcript {
  Transcript(..transcript, messages: [
    chat.user_message(text),
    ..transcript.messages
  ])
}

pub fn append_assistant(transcript: Transcript, text: String) -> Transcript {
  Transcript(..transcript, messages: [
    chat.assistant_message(text),
    ..transcript.messages
  ])
}

/// Append an assistant turn carrying a native tool call (spike B round-trip).
pub fn append_assistant_tool_call(
  transcript: Transcript,
  id id: String,
  name name: String,
  arguments arguments: String,
) -> Transcript {
  let call =
    chat.FunctionToolCall(
      id: id,
      function: shared.FunctionCall(name: name, arguments: arguments),
    )
  Transcript(..transcript, messages: [
    chat.AssistantMessage(
      content: None,
      refusal: None,
      name: None,
      tool_calls: Some([call]),
    ),
    ..transcript.messages
  ])
}

/// Append an assistant turn carrying several native tool calls (M3 loop):
/// one message, one call entry each, with optional text content.
pub fn append_assistant_tool_calls(
  transcript: Transcript,
  text text: Option(String),
  calls calls: List(#(String, String, String)),
) -> Transcript {
  let calls =
    list.map(calls, fn(call: #(String, String, String)) {
      let #(id, name, arguments) = call
      chat.FunctionToolCall(
        id: id,
        function: shared.FunctionCall(name: name, arguments: arguments),
      )
    })
  Transcript(..transcript, messages: [
    chat.AssistantMessage(
      content: case text {
        Some(content) -> Some(chat.AssistantTextContent(content))
        None -> None
      },
      refusal: None,
      name: None,
      tool_calls: Some(calls),
    ),
    ..transcript.messages
  ])
}

/// Append a tool result turn (spike B round-trip).
pub fn append_tool_result(
  transcript: Transcript,
  tool_call_id tool_call_id: String,
  content content: String,
) -> Transcript {
  Transcript(..transcript, messages: [
    chat.tool_message(content, tool_call_id),
    ..transcript.messages
  ])
}

/// Build the request value (pure). This is the one construction path; both
/// `request_body` and the transport seam consume it.
pub fn to_request(
  transcript: Transcript,
  opts opts: Options,
) -> chat.CreateChatCompletionRequest {
  let req =
    chat.new_create_request(
      model: transcript.model,
      messages: messages(transcript),
    )
  let req = case opts.stream {
    True -> chat.with_stream(req, True)
    False -> req
  }
  let req = case opts.tools {
    [] -> req
    tools -> chat.with_tools(req, tools)
  }
  let req = case opts.tool_choice {
    Some(choice) -> chat.with_tool_choice(req, choice)
    None -> req
  }
  let req = case opts.max_completion_tokens {
    Some(n) -> chat.with_max_completion_tokens(req, n)
    None -> req
  }
  let req = case opts.temperature {
    Some(t) -> chat.with_temperature(req, t)
    None -> req
  }
  req
}

/// Deterministic JSON body for the transcript under `opts`. Byte-stable by
/// construction: same messages + same options => same bytes.
pub fn request_body(transcript: Transcript, opts: Options) -> String {
  transcript
  |> to_request(opts)
  |> chat.create_chat_completion_request_to_json
  |> json.to_string
}
