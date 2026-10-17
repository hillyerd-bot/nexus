-module(nexus_store_ffi).

-export([read_file/1, database_url/0]).

read_file(Path) ->
    case file:read_file(unicode:characters_to_list(Path)) of
        {ok, Binary} -> {ok, Binary};
        {error, Reason} ->
            {error, unicode:characters_to_binary(
                      io_lib:format("~p", [Reason]))}
    end.

database_url() ->
    case os:getenv("DATABASE_URL") of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
