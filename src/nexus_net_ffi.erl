%% M3 tool-adapter FFI: bounded buffered GETs and host resolution for the
%% http_fetch SSRF guard. Body size is enforced here (not in Gleam) so a
%% multi-gigabyte response cannot be materialised before truncation.
-module(nexus_net_ffi).

-export([bounded_get/4, resolve_host/1]).

%% GET with connect/receive timeouts and a hard byte cap. Does NOT follow
%% redirects (policy — including re-validating every hop against the SSRF
%% guard — lives in nexus/http_fetch.gleam). Returns:
%%   {ok, {Status, ContentType, Body, Truncated}} | {error, Reason}
%% where ContentType is <<>> when absent and Truncated is true when the body
%% was cut at MaxBytes.
bounded_get(Url, Headers, MaxBytes, TimeoutMs) ->
    Opts = [{connect_timeout, TimeoutMs}, {recv_timeout, TimeoutMs}],
    case hackney:request(get, Url, Headers, <<>>, Opts) of
        {ok, Status, RespHeaders, Client} ->
            ContentType = header(RespHeaders, <<"content-type">>),
            Location = header(RespHeaders, <<"location">>),
            case read_body(Client, MaxBytes, <<>>, false) of
                {ok, Body, Truncated} ->
                    {ok, {fetch_response, Status, ContentType, Location, Body, Truncated}};
                {error, Reason} ->
                    hackney:close(Client),
                    {error, format_reason(Reason)}
            end;
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

read_body(Client, MaxBytes, Acc, Dropped) ->
    Remaining = MaxBytes - byte_size(Acc),
    case Remaining =< 0 andalso Dropped of
        true ->
            hackney:close(Client),
            {ok, Acc, Dropped};
        false ->
            case hackney:stream_body(Client) of
                {ok, Chunk} ->
                    {Acc2, Dropped2} = append_capped(Acc, Chunk, Remaining),
                    read_body(Client, MaxBytes, Acc2, Dropped orelse Dropped2);
                done ->
                    hackney:close(Client),
                    {ok, Acc, Dropped};
                {error, Reason} ->
                    {error, format_reason(Reason)}
            end
    end.

append_capped(Acc, Chunk, Remaining) ->
    ChunkSize = byte_size(Chunk),
    case ChunkSize =< Remaining of
        true -> {<<Acc/binary, Chunk/binary>>, false};
        false -> {<<Acc/binary, Chunk:Remaining/binary>>, true}
    end.

header(Headers, Name) ->
    Pred = fun({K, _}) -> string:lowercase(K) =:= string:lowercase(Name) end,
    case lists:search(Pred, Headers) of
        {value, {_, Value}} -> Value;
        false -> <<>>
    end.

format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~tp", [Reason])).

%% Resolve a hostname (or IP literal) to all its addresses, as printable
%% strings ("127.0.0.1", "::1"). The Gleam side applies the private-range
%% policy. Errors are formatted binaries.
resolve_host(Host) ->
    HostList = unicode:characters_to_list(Host),
    Addresses = lists:usort(lists:flatten([
        resolve_family(HostList, inet),
        resolve_family(HostList, inet6)
    ])),
    case Addresses of
        [] -> {error, <<"could not resolve host">>};
        _ -> {ok, Addresses}
    end.

resolve_family(Host, Family) ->
    case inet:getaddr(Host, Family) of
        {ok, Addr} ->
            [unicode:characters_to_binary(inet:ntoa(Addr))];
        {error, _} -> []
    end.
