import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import glopenai/shared
import nexus/config
import nexus/openai
import nexus/transcript
import spikes/c_cache

pub fn deterministic_transcript_test() {
  let body =
    c_cache.system_prompt(123)
    |> transcript.new("test-model", _)
    |> transcript.append_user(c_cache.user_prompt(1))
    |> transcript.request_body(transcript.default_options())
  should.be_true(string.contains(body, "Session nonce: 123"))
  should.be_true(string.contains(body, "Cache audit turn"))
}

pub fn summarize_cold_and_warm_test() {
  let metrics =
    c_cache.summarize([
      turn(1, 1, 100, None),
      turn(1, 10, 20, usage(75)),
      turn(1, 11, 40, usage(90)),
      turn(2, 1, 200, usage(0)),
      turn(2, 10, 30, usage(120)),
    ])
    |> result.unwrap(c_cache.Metrics(0.0, 0.0, 0.0, False))
  should.equal(metrics.cold_median_ms, 150.0)
  should.equal(metrics.warm_median_ms, 30.0)
  should.equal(metrics.ratio, 0.2)
  should.be_true(metrics.passed)
}

pub fn csv_row_test() {
  should.equal(
    c_cache.csv_header(),
    "session,turn,ttft_ms,duration_ms,token_deltas,events_parsed,prompt_tokens,cached_tokens,prompt_tokens_estimated,tokens_per_second",
  )
  should.equal(
    c_cache.csv_row(turn(1, 10, 20, usage(75))),
    "1,10,20,100,4,8,100,75,100,40.0",
  )
}

pub fn validity_rejects_incomplete_streams_test() {
  let assert Ok(base) =
    config.from_env(fn(name) {
      case name {
        "BIFROST_BASE_URL" -> Ok("http://bifrost.test/v1")
        "BIFROST_API_KEY" -> Ok("sk-test")
        "NEXUS_MODEL_DEFAULT" -> Ok("test-model")
        _ -> Error(Nil)
      }
    })
  let cfg = config.Config(..base, spike_c_turns: 20, spike_c_repeats: 1)
  should.be_false(c_cache.valid_results(cfg, [turn(1, 1, 100, usage(0))]))
}

fn turn(
  session: Int,
  turn_number: Int,
  ttft_ms: Int,
  usage: option.Option(shared.CompletionUsage),
) -> c_cache.TurnResult {
  c_cache.TurnResult(
    session: session,
    turn: turn_number,
    prompt_chars: 400,
    stats: openai.StreamStats(
      ttft_ms: Some(ttft_ms),
      duration_ms: 100,
      token_deltas: 4,
      tool_call_deltas: 0,
      events_parsed: 8,
      decode_errors: 0,
      saw_done: True,
      usage: usage,
    ),
  )
}

fn usage(cached: Int) -> option.Option(shared.CompletionUsage) {
  Some(shared.CompletionUsage(
    prompt_tokens: 100,
    completion_tokens: 4,
    total_tokens: 104,
    prompt_tokens_details: Some(shared.PromptTokensDetails(
      audio_tokens: None,
      cached_tokens: Some(cached),
    )),
    completion_tokens_details: None,
  ))
}
