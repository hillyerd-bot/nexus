%% Per-test call index for the scripted stream in loop_test.
-module(nexus_loop_test_ffi).

-export([next_index/0, reset_index/0, read_file/1]).

next_index() ->
    Index = case erlang:get(nexus_test_index) of
                undefined -> 0;
                N -> N
            end,
    erlang:put(nexus_test_index, Index + 1),
    Index.

reset_index() ->
    erlang:erase(nexus_test_index),
    nil.

%% Test-only file read for the M3 golden prefix fixture.
read_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Bin.
