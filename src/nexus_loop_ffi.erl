%% Tiny mutable cells for the M3 agent loop fold. The loop runs inside the
%% per-turn worker process (never the session actor), so the process
%% dictionary is a safe place to accumulate streamed fragments while the
%% transport seam pushes events through a plain callback.
-module(nexus_loop_ffi).

-export([cell_init/0, put_text/1, take_text/0, peek_text/0, put_calls/1,
         take_calls/0, peek_calls/0]).

cell_init() ->
    erlang:erase(nexus_loop_text),
    erlang:erase(nexus_loop_calls),
    nil.

put_text(Text) ->
    erlang:put(nexus_loop_text, Text),
    nil.

put_calls(Calls) ->
    erlang:put(nexus_loop_calls, Calls),
    nil.

take_text() ->
    case erlang:erase(nexus_loop_text) of
        undefined -> <<>>;
        Text -> Text
    end.

peek_text() ->
    case erlang:get(nexus_loop_text) of
        undefined -> <<>>;
        Text -> Text
    end.

%% The Gleam side seeds the calls cell with `tool_calls.new()` before every
%% stream; these defaults only cover a cell that was never seeded (a bug
%% canary, not a valid accumulator).
take_calls() ->
    case erlang:erase(nexus_loop_calls) of
        undefined -> accumulator_never_seeded;
        Calls -> Calls
    end.

peek_calls() ->
    case erlang:get(nexus_loop_calls) of
        undefined -> accumulator_never_seeded;
        Calls -> Calls
    end.
