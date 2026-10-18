%% Vendored FFI from httpp 1.8.0 (https://github.com/VioletBuse/httpp,
%% Apache-2.0, Copyright VioletBuse). nexus dropped the httpp package during
%% the gleam_stdlib 1.x migration (httpp's last release pins
%% `gleam_stdlib ~> 0.65`) and keeps only this thin hackney layer; the Gleam
%% side lives in src/nexus/hackney.gleam.
-module(nexus_hackney_ffi).

-export([send/5, close/1, body/1, insert_selector_handler/3]).

send(Method, Url, Headers, Body, Options) ->
    case hackney:request(Method, Url, Headers, Body, Options) of
        {ok, Status, ResponseHeaders, <<Binary>>} ->
            {ok, {binary_response, Status, ResponseHeaders, Binary}};

        {ok, Status, ResponseHeaders, ClientRef} ->
            {ok, {client_ref_response, Status, ResponseHeaders, ClientRef}};

        {ok, Status, ResponseHeaders} ->
            {ok, {empty_response, Status, ResponseHeaders}};

        {ok, ClientRef} ->
            {ok, {async_response, ClientRef}};

        {error, {closed, PartialBody}} ->
            {error, {connection_closed, PartialBody}};

        {error, Error} ->
            {error, {other, Error}}
    end.

close(ClientRef) ->
    hackney:close(ClientRef),
    nil.

%% Read the full buffered body. Translate hackney's raw error terms into
%% the Gleam Error constructors, mirroring send/5, so callers never see
%% untagged error tuples typed as Error.
body(ClientRef) ->
    case hackney:body(ClientRef) of
        {ok, Body} -> {ok, Body};
        {error, {closed, PartialBody}} -> {error, {connection_closed, PartialBody}};
        {error, Error} -> {error, {other, Error}}
    end.

%% Reaches into gleam_erlang's internal selector record to install a handler
%% for `{hackney_response, Ref, Payload}` messages. Same technique (and same
%% fragility against gleam_erlang internals) as httpp 1.8.0, which nexus
%% migrated off of; gleam_erlang is effectively pinned by this.
insert_selector_handler({selector, Handlers}, Tag, Fn) ->
    {selector, Handlers#{Tag => Fn}}.
