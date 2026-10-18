import gleam/list
import gleeunit/should
import nexus/timing

pub fn elapsed_ms_basic_test() {
  timing.elapsed_ms(1_000_000, 1_250_000) |> should.equal(250)
}

pub fn elapsed_ms_never_negative_test() {
  timing.elapsed_ms(2_000_000, 1_000_000) |> should.equal(0)
}

pub fn now_us_monotonic_test() {
  let a = timing.now_us()
  let b = timing.now_us()
  should.be_true(b >= a)
}

pub fn ttft_ratio_test() {
  let assert Ok(ratio) = timing.ttft_ratio(300.0, 1000.0)
  should.equal(ratio, 0.3)
}

pub fn ttft_ratio_rejects_zero_cold_test() {
  timing.ttft_ratio(100.0, 0.0) |> should.be_error
}

pub fn ttft_ratio_rejects_negative_cold_test() {
  timing.ttft_ratio(100.0, -5.0) |> should.be_error
}

pub fn median_odd_test() {
  let assert Ok(m) = timing.median([30.0, 10.0, 20.0])
  should.equal(m, 20.0)
}

pub fn median_even_test() {
  let assert Ok(m) = timing.median([40.0, 30.0, 20.0, 10.0])
  should.equal(m, 25.0)
}

pub fn median_single_test() {
  let assert Ok(m) = timing.median([12.5])
  should.equal(m, 12.5)
}

pub fn median_empty_test() {
  timing.median([]) |> should.be_error
}

pub fn median_large_test() {
  let values = list.repeat(7.0, 101) |> list.append([1.0])
  let assert Ok(m) = timing.median(values)
  should.equal(m, 7.0)
}

pub fn wall_now_s_is_recent_epoch_test() {
  // A real wall-clock epoch (post-2020), coarse to whole seconds.
  let now = timing.wall_now_s()
  should.be_true(now > 1_600_000_000)
  should.be_true(now % 1 == 0)
  // Strictly behind the monotonic sample cadence: two reads differ by at
  // most a small number of seconds (it is a clock read, not a counter).
  should.be_true(timing.wall_now_s() - now < 10)
}

pub fn wall_to_rfc3339_fixed_values_test() {
  timing.wall_to_rfc3339(0) |> should.equal("1970-01-01T00:00:00Z")
  timing.wall_to_rfc3339(1_729_000_000)
  |> should.equal("2024-10-15T13:46:40Z")
  timing.wall_to_rfc3339(86_400) |> should.equal("1970-01-02T00:00:00Z")
}
