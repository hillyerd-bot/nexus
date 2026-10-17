-module(nexus_timing_ffi).

-export([monotonic_us/0, wall_now_s/0, wall_to_rfc3339/1]).

monotonic_us() ->
    erlang:monotonic_time(microsecond).

%% Wall-clock epoch seconds. Display/ordering metadata only — every metric
%% stays on the monotonic clock above.
wall_now_s() ->
    erlang:system_time(second).

wall_to_rfc3339(Seconds) ->
    unicode:characters_to_binary(
      calendar:system_time_to_rfc3339(
        Seconds, [{unit, second}, {offset, "Z"}]
       )
     ).
