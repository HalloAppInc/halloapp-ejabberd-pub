%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% Client to simulate requests to upload server
%%% @end
%%%-------------------------------------------------------------------
-module(upload_client).
-author("vipin").

-include("ha_types.hrl").
-include("logger.hrl").

-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, "1080").

%% API
-export([
    request_upload/1,
    request_upload/2,
    upload_data/3
]).


setup() ->
    application:ensure_started(inets).


-spec request_upload(Size :: integer()) -> {ok, list()} | {error, term()}.
request_upload(Size) ->
    request_upload(Size, #{}).


-spec request_upload(Size :: integer(), Options :: map()) -> {ok, list()} | {error, term()}.
request_upload(Size, Options) ->
    setup(),
    Headers = [{"Tus-Resumable", "1.0.0"}, {"Upload-Length", integer_to_list(Size)}],
    Host = maps:get(host, Options, ?DEFAULT_HOST),
    Port = maps:get(port, Options, ?DEFAULT_PORT),
    Request = {"http://" ++ Host ++ ":" ++ Port ++"/files/", Headers, "application/json", <<>>},
    {ok, Response} = httpc:request(post, Request, [{timeout, 30000}], []),
    case Response of
        {{_, 201, _}, ResHeaders, _ResponseBody} ->
            LocationHdr = [Location || {"location", _} = Location <- ResHeaders],
            [{_, LocationUrl}] = LocationHdr,
            {ok, LocationUrl};
        {{_, HTTPCode, _}, _ResHeaders, ResponseBody} ->
            {error, {HTTPCode, ResponseBody}}
    end.


-spec upload_data(PatchUrl :: list(), Offset :: integer(), Size :: integer()) -> {ok, list()} | {error, term()}.
upload_data(PatchUrl, Offset, Size) ->
    setup(),
    Headers = [{"Tus-Resumable", "1.0.0"}, {"Upload-Offset", integer_to_list(Offset)}],
    Body = crypto:strong_rand_bytes(Size),
    Request = {PatchUrl, Headers, "application/offset+octet-stream", Body},
    {ok, Response} = httpc:request(patch, Request, [{timeout, 30000}], []),
    case Response of
        {{_, 204, _}, ResHeaders, _ResponseBody} ->
            LocationHdr = [Location || {"download-location", _} = Location <- ResHeaders],
            [{_, LocationUrl}] = LocationHdr,
            {ok, LocationUrl};
        {{_, HTTPCode, _}, _ResHeaders, ResponseBody} ->
            {error, {HTTPCode, ResponseBody}}
    end.


