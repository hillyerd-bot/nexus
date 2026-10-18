import audit/config
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn env(pairs: List(#(String, String))) -> fn(String) -> Result(String, Nil) {
  fn(name) {
    case list.find(pairs, fn(pair) { pair.0 == name }) {
      Ok(#(_, value)) -> Ok(value)
      Error(Nil) -> Error(Nil)
    }
  }
}

fn minimal() -> List(#(String, String)) {
  [
    #("NEXUS_AUDIT_BASE_URL", "http://bifrost.test/v1"),
    #("NEXUS_AUDIT_MODEL", "test-model"),
  ]
}

pub fn requires_base_url_test() {
  config.from_env(env([#("NEXUS_AUDIT_MODEL", "m")]))
  |> should.be_error
}

pub fn requires_model_test() {
  config.from_env(env([#("NEXUS_AUDIT_BASE_URL", "http://bifrost.test/v1")]))
  |> should.be_error
}

pub fn rejects_base_url_without_v1_test() {
  let assert Error(message) =
    config.from_env(
      env([
        #("NEXUS_AUDIT_BASE_URL", "http://bifrost.test"),
        #("NEXUS_AUDIT_MODEL", "m"),
      ]),
    )
  should.be_true(string.contains(message, "NEXUS_AUDIT_BASE_URL"))
}

pub fn api_key_optional_test() {
  let assert Ok(cfg) = config.from_env(env(minimal()))
  should.equal(cfg.api_key, None)
  let assert Ok(cfg_with_key) =
    config.from_env(
      env(list.append(minimal(), [#("NEXUS_AUDIT_API_KEY", "sk-test")])),
    )
  should.equal(cfg_with_key.api_key, Some("sk-test"))
}

pub fn trims_and_normalizes_base_url_test() {
  let assert Ok(cfg) =
    config.from_env(
      env([
        #("NEXUS_AUDIT_BASE_URL", "  http://bifrost.test/v1/ "),
        #("NEXUS_AUDIT_MODEL", "m"),
      ]),
    )
  should.equal(cfg.base_url, "http://bifrost.test/v1")
}

pub fn defaults_test() {
  let assert Ok(cfg) = config.from_env(env(minimal()))
  should.equal(cfg.model, "test-model")
  should.equal(cfg.turns, 20)
  should.equal(cfg.repeats, 5)
  should.equal(cfg.sse_first_response_timeout_ms, 30_000)
  should.equal(cfg.stream_idle_timeout_ms, 120_000)
}

pub fn overrides_test() {
  let assert Ok(cfg) =
    config.from_env(
      env(
        list.append(minimal(), [
          #("NEXUS_AUDIT_TURNS", "30"),
          #("NEXUS_AUDIT_REPEATS", "2"),
          #("NEXUS_AUDIT_SSE_FIRST_RESPONSE_TIMEOUT_MS", "60000"),
          #("NEXUS_AUDIT_STREAM_IDLE_TIMEOUT_MS", "5000"),
        ]),
      ),
    )
  should.equal(cfg.turns, 30)
  should.equal(cfg.repeats, 2)
  should.equal(cfg.sse_first_response_timeout_ms, 60_000)
  should.equal(cfg.stream_idle_timeout_ms, 5000)
}

pub fn rejects_non_integer_test() {
  let assert Error(message) =
    config.from_env(
      env(list.append(minimal(), [#("NEXUS_AUDIT_TURNS", "soon")])),
    )
  should.be_true(string.contains(message, "NEXUS_AUDIT_TURNS"))
}
