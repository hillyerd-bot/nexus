%% FFI for the surviving spike runner (spikes/c_cache): process exit,
%% plain argv, and a unique integer for per-run identifiers.
-module(nexus_spike_ffi).

-export([halt/1, argv/0, unique_integer/0]).

halt(Code) ->
    erlang:halt(Code).

argv() ->
    [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()].

unique_integer() ->
    erlang:unique_integer([positive]).
