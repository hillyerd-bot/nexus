//// Spike C — KV-cache audit harness.
////
//// Each repeat uses a unique nonce in an otherwise deterministic system
//// prompt. Request one is cold; requests 10–20 are warm samples. The
//// assistant messages recorded in the transcript are fixed seed-generated
//// answers, not prior network responses, so every prefix remains immutable
//// and byte-stable.

import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import glopenai/shared.{type CompletionUsage}
import nexus/config.{type Config}
import nexus/openai
import nexus/timing
import nexus/transcript

const stream_attempts = 3

@external(erlang, "nexus_spike_ffi", "halt")
fn halt(code: Int) -> a

@external(erlang, "nexus_spike_ffi", "argv")
fn argv() -> List(String)

@external(erlang, "nexus_spike_ffi", "unique_integer")
fn unique_integer() -> Int

pub type TurnResult {
  TurnResult(
    session: Int,
    turn: Int,
    stats: openai.StreamStats,
    prompt_chars: Int,
  )
}

fn stream_with_retries(
  cfg: Config,
  requested: transcript.Transcript,
  attempt: Int,
) -> Result(openai.StreamStats, openai.StreamError) {
  let outcome = openai.stream(cfg, requested, options(), fn(_) { Nil })
  case outcome, attempt < stream_attempts {
    Ok(stats), _ -> Ok(stats)
    Error(openai.Transport(reason)), True -> {
      io.println(
        "retryable_transport_error=true attempt="
        <> int.to_string(attempt)
        <> " reason="
        <> reason,
      )
      stream_with_retries(cfg, requested, attempt + 1)
    }
    Error(error), _ -> Error(error)
  }
}

fn report_invalid_results(cfg: Config, results: List(TurnResult)) -> Nil {
  let expected = cfg.spike_c_turns * cfg.spike_c_repeats
  let missing_ttft =
    list.filter(results, fn(result) { result.stats.ttft_ms == None })
  let without_tokens =
    list.filter(results, fn(result) { result.stats.token_deltas == 0 })
  io.println("invalid_results=true")
  io.println("result_count=" <> int.to_string(list.length(results)))
  io.println("expected_count=" <> int.to_string(expected))
  io.println("missing_ttft_count=" <> int.to_string(list.length(missing_ttft)))
  io.println("zero_token_count=" <> int.to_string(list.length(without_tokens)))
  io.println(
    "first_invalid="
    <> case list.append(missing_ttft, without_tokens) {
      [] -> "none"
      [result, ..] ->
        "session="
        <> int.to_string(result.session)
        <> ",turn="
        <> int.to_string(result.turn)
        <> ",events="
        <> int.to_string(result.stats.events_parsed)
        <> ",decode_errors="
        <> int.to_string(result.stats.decode_errors)
        <> ",saw_done="
        <> bool_string(result.stats.saw_done)
    },
  )
}

pub type Metrics {
  Metrics(
    cold_median_ms: Float,
    warm_median_ms: Float,
    ratio: Float,
    passed: Bool,
  )
}

pub fn main() -> Nil {
  let csv_mode = list.contains(argv(), "--csv")
  case config.load() {
    Error(message) ->
      case csv_mode {
        True -> halt(2)
        False -> {
          io.println("=== spike c: cache ===")
          io.println("config error: " <> message)
          halt(2)
        }
      }
    Ok(cfg) ->
      case cfg.spike_c_turns < 20 || cfg.spike_c_repeats < 1 {
        True ->
          case csv_mode {
            True -> halt(2)
            False -> {
              io.println("=== spike c: cache ===")
              io.println(
                "config error: NEXUS_SPIKE_C_TURNS must be >= 20 and NEXUS_SPIKE_C_REPEATS must be >= 1",
              )
              halt(2)
            }
          }
        False ->
          case csv_mode {
            True -> run_csv(cfg)
            False -> run_report(cfg)
          }
      }
  }
}

fn run_report(cfg: Config) -> Nil {
  io.println("=== spike c: cache ===")
  io.println("base_url=" <> cfg.base_url)
  io.println("model=" <> cfg.model_default)
  io.println("turns=" <> int.to_string(cfg.spike_c_turns))
  io.println("repeats=" <> int.to_string(cfg.spike_c_repeats))
  let collected = collect_results(cfg)
  case valid_results(cfg, collected) {
    False -> {
      list.each(collected, report_turn)
      report_invalid_results(cfg, collected)
      halt(1)
    }
    True -> {
      list.each(collected, report_turn)
      case summarize(collected) {
        Ok(metrics) -> {
          report_metrics(metrics)
          report_usage_evidence(collected)
          io.println("=== spike c complete ===")
        }
        Error(reason) -> {
          io.println("metrics error: " <> reason)
          halt(1)
        }
      }
    }
  }
}

fn run_csv(cfg: Config) -> Nil {
  let collected = collect_results(cfg)
  case valid_results(cfg, collected) {
    False -> halt(1)
    True -> {
      io.println(csv_header())
      list.each(collected, fn(turn) { io.println(csv_row(turn)) })
    }
  }
}

fn collect_results(cfg: Config) -> List(TurnResult) {
  int.range(1, cfg.spike_c_repeats + 1, [], list.prepend)
  |> list.reverse
  |> list.flat_map(fn(session) { run_session(cfg, session) })
}

fn run_session(cfg: Config, session: Int) -> List(TurnResult) {
  let nonce = unique_integer()
  let initial = transcript.new(cfg.model_default, system_prompt(nonce))
  int.range(1, cfg.spike_c_turns + 1, [], list.prepend)
  |> list.reverse
  |> list.fold(#(initial, []), fn(state, turn) {
    let #(current, results) = state
    let requested = transcript.append_user(current, user_prompt(turn))
    let prompt_chars =
      string.length(transcript.request_body(requested, options()))
    io.println(
      "session="
      <> int.to_string(session)
      <> " turn="
      <> int.to_string(turn)
      <> " started",
    )
    let outcome = case turn {
      1 -> openai.stream(cfg, requested, options(), fn(_) { Nil })
      _ -> stream_with_retries(cfg, requested, 1)
    }
    case outcome {
      Ok(stats) -> #(
        transcript.append_assistant(requested, assistant_prompt(turn)),
        [TurnResult(session, turn, stats, prompt_chars), ..results],
      )
      Error(openai.Non200(status, body)) -> {
        io.println(
          "session="
          <> int.to_string(session)
          <> " turn="
          <> int.to_string(turn)
          <> " error=non200 status="
          <> int.to_string(status)
          <> " body="
          <> body,
        )
        #(requested, results)
      }
      Error(openai.Transport(reason)) -> {
        report_stream_error(session, turn, "transport", reason)
        #(requested, results)
      }
      Error(openai.Decode(reason)) -> {
        report_stream_error(session, turn, "decode", reason)
        #(requested, results)
      }
    }
  })
  |> fn(pair) { pair.1 }
  |> list.reverse
}

fn report_stream_error(session: Int, turn: Int, kind: String, reason: String) {
  io.println(
    "session="
    <> int.to_string(session)
    <> " turn="
    <> int.to_string(turn)
    <> " error="
    <> kind
    <> " reason="
    <> reason,
  )
}

pub fn summarize(results: List(TurnResult)) -> Result(Metrics, String) {
  use cold <- result.try(median_for(results, Cold))
  use warm <- result.try(median_for(results, Warm))
  use ratio <- result.try(timing.ttft_ratio(warm, cold))
  Ok(Metrics(cold, warm, ratio, ratio <=. 0.3))
}

type SampleKind {
  Cold
  Warm
}

fn median_for(
  results: List(TurnResult),
  kind: SampleKind,
) -> Result(Float, String) {
  results
  |> list.filter_map(fn(result) {
    let selected = case kind {
      Cold -> result.turn == 1
      Warm -> result.turn >= 10
    }
    case selected, result.stats.ttft_ms {
      True, Some(ms) -> Ok(int.to_float(ms))
      _, _ -> Error(Nil)
    }
  })
  |> timing.median
  |> result.replace_error(case kind {
    Cold -> "no cold TTFT samples"
    Warm -> "no warm TTFT samples (turns 10+)"
  })
}

pub fn valid_results(cfg: Config, results: List(TurnResult)) -> Bool {
  list.length(results) == cfg.spike_c_turns * cfg.spike_c_repeats
  && list.all(results, fn(result) {
    result.stats.ttft_ms != None && result.stats.token_deltas > 0
  })
}

pub fn system_prompt(nonce: Int) -> String {
  let discipline =
    [
      "Prefix caching depends on immutable request bytes",
      "Every conversation turn extends an append-only transcript",
      "The system prompt and prior turns never change after creation",
      "Request encoding follows one deterministic construction path",
      "No clock values, session metadata, or random IDs enter old turns",
      "A cache-friendly agent treats history as an immutable prefix",
      "Each new request may append one deterministic tail turn",
      "Stable field ordering keeps serialized prefixes byte-identical",
      "Local inference latency improves when backend cache hits accumulate",
      "The audit harness must preserve these rules on every request",
    ]
    |> string.join(". ")
  let discipline = list.repeat(discipline, 180) |> string.join(". ")
  "You are nexus spike C, a deterministic cache audit assistant. Session nonce: "
  <> int.to_string(nonce)
  <> ". Cache discipline: "
  <> discipline
  <> ". Answer only the final question, in one short sentence."
}

pub fn user_prompt(turn: Int) -> String {
  "Cache audit turn "
  <> int.to_string(turn)
  <> ": what is "
  <> int.to_string(turn)
  <> " squared plus one? Answer with the number only."
}

pub fn assistant_prompt(turn: Int) -> String {
  int.to_string(turn * turn + 1)
}

pub fn csv_header() -> String {
  "session,turn,ttft_ms,duration_ms,token_deltas,events_parsed,prompt_tokens,cached_tokens,prompt_tokens_estimated,tokens_per_second"
}

pub fn csv_row(result: TurnResult) -> String {
  let #(prompt_tokens, cached_tokens, estimated) = usage_fields(result)
  [
    int.to_string(result.session),
    int.to_string(result.turn),
    option.unwrap(result.stats.ttft_ms, 0) |> int.to_string,
    int.to_string(result.stats.duration_ms),
    int.to_string(result.stats.token_deltas),
    int.to_string(result.stats.events_parsed),
    int.to_string(prompt_tokens),
    int.to_string(cached_tokens),
    int.to_string(estimated),
    tokens_per_second(result) |> float.to_string,
  ]
  |> string.join(",")
}

fn usage_fields(result: TurnResult) -> #(Int, Int, Int) {
  let estimated = case result.prompt_chars / 4 {
    0 -> 1
    estimate -> estimate
  }
  case result.stats.usage {
    Some(usage) -> #(usage.prompt_tokens, cached_tokens(usage), estimated)
    None -> #(0, 0, estimated)
  }
}

fn cached_tokens(usage: CompletionUsage) -> Int {
  case usage.prompt_tokens_details {
    Some(details) -> option.unwrap(details.cached_tokens, 0)
    None -> 0
  }
}

fn tokens_per_second(result: TurnResult) -> Float {
  case result.stats.duration_ms {
    0 -> 0.0
    duration ->
      int.to_float(result.stats.token_deltas * 1000) /. int.to_float(duration)
  }
}

fn report_turn(result: TurnResult) -> Nil {
  io.println(
    "session="
    <> int.to_string(result.session)
    <> " turn="
    <> int.to_string(result.turn)
    <> " ttft_ms="
    <> int.to_string(option.unwrap(result.stats.ttft_ms, 0))
    <> " duration_ms="
    <> int.to_string(result.stats.duration_ms)
    <> " token_deltas="
    <> int.to_string(result.stats.token_deltas)
    <> " events="
    <> int.to_string(result.stats.events_parsed)
    <> " saw_done="
    <> bool_string(result.stats.saw_done)
    <> " csv_row="
    <> csv_row(result),
  )
}

fn report_metrics(metrics: Metrics) -> Nil {
  io.println("cold_median_ms=" <> float.to_string(metrics.cold_median_ms))
  io.println("warm_median_ms=" <> float.to_string(metrics.warm_median_ms))
  io.println("warm_cold_ratio=" <> float.to_string(metrics.ratio))
  io.println("gate_ratio=0.3")
  io.println(
    "verdict="
    <> case metrics.passed {
      True -> "pass"
      False -> "fail"
    },
  )
}

fn report_usage_evidence(results: List(TurnResult)) -> Nil {
  let #(actual, missing, cached) =
    list.fold(results, #(0, 0, 0), fn(acc, result) {
      let #(actual, missing, cached) = acc
      case result.stats.usage {
        Some(usage) -> #(actual + 1, missing, cached + cached_tokens(usage))
        None -> #(actual, missing + 1, cached)
      }
    })
  io.println("usage_actual=" <> int.to_string(actual))
  io.println("usage_missing=" <> int.to_string(missing))
  io.println("cached_tokens_sum=" <> int.to_string(cached))
}

fn options() -> transcript.Options {
  transcript.Options(..transcript.default_options(), stream: True)
}

fn bool_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
