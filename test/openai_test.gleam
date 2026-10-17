//// Offline tests for the seam's stream-chunk fold (`nexus/openai.handle_chunk`)
//// — no network involved.
////
//// The usage-forwarding case is the regression guard for the PR #3 review
//// finding: `chunk.usage` was silently dropped (the `Usage` event was
//// declared but never emitted), which would have lost spike C's
//// cached_tokens evidence.

import gleam/option.{type Option, None, Some}
import gleeunit/should
import glopenai/chat
import glopenai/shared
import nexus/openai

fn stream_chunk(
  content content: Option(String),
  usage usage: Option(shared.CompletionUsage),
) -> chat.CreateChatCompletionStreamResponse {
  chat.CreateChatCompletionStreamResponse(
    id: "chatcmpl-test",
    object: "chat.completion.chunk",
    created: 0,
    model: "test-model",
    choices: [
      chat.ChatChoiceStream(
        index: 0,
        delta: chat.ChatCompletionStreamDelta(
          role: None,
          content: content,
          refusal: None,
          tool_calls: None,
        ),
        finish_reason: None,
      ),
    ],
    usage: usage,
    service_tier: None,
    system_fingerprint: None,
  )
}

fn acc() -> openai.Acc {
  openai.Acc(
    started_us: 0,
    ttft_us: None,
    last_event_us: 0,
    token_deltas: 0,
    tool_call_deltas: 0,
    events_parsed: 0,
    decode_errors: 0,
    saw_done: False,
    first_decode_error: None,
    usage: None,
  )
}

fn usage_with(cached cached: Int) -> shared.CompletionUsage {
  shared.CompletionUsage(
    prompt_tokens: 100,
    completion_tokens: 5,
    total_tokens: 105,
    prompt_tokens_details: Some(shared.PromptTokensDetails(
      audio_tokens: None,
      cached_tokens: Some(cached),
    )),
    completion_tokens_details: None,
  )
}

pub fn content_delta_accounting_test() {
  let out =
    openai.handle_chunk(
      stream_chunk(content: Some("hi"), usage: None),
      7,
      acc(),
      fn(_) { Nil },
    )
  out.token_deltas |> should.equal(1)
  out.ttft_us |> should.equal(Some(7))
  out.events_parsed |> should.equal(1)
  out.usage |> should.equal(None)
}

pub fn usage_is_forwarded_not_dropped_test() {
  let usage = usage_with(cached: 42)
  let out =
    openai.handle_chunk(
      stream_chunk(content: None, usage: Some(usage)),
      9,
      acc(),
      fn(_) { Nil },
    )
  // The accumulator (and thus StreamStats) must carry the usage block —
  // this is spike C's secondary cache-hit signal.
  out.usage |> should.equal(Some(usage))
  out.events_parsed |> should.equal(1)
  out.token_deltas |> should.equal(0)
  out.ttft_us |> should.equal(None)
}

pub fn later_usage_chunk_replaces_earlier_test() {
  let first = usage_with(cached: 42)
  let acc1 =
    openai.handle_chunk(
      stream_chunk(content: Some("a"), usage: Some(first)),
      10,
      acc(),
      fn(_) { Nil },
    )
  let second = usage_with(cached: 90)
  let acc2 =
    openai.handle_chunk(
      stream_chunk(content: None, usage: Some(second)),
      20,
      acc1,
      fn(_) { Nil },
    )
  acc2.usage |> should.equal(Some(second))
  acc2.token_deltas |> should.equal(1)
  acc2.events_parsed |> should.equal(2)
  acc2.last_event_us |> should.equal(20)
}
