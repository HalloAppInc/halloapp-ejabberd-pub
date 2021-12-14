%%%---------------------------------------------------------------------------------
%%% File    : mod_call_servers.erl
%%%
%%% Copyright (C) 2021 HalloApp Inc.
%%%
%%%---------------------------------------------------------------------------------

-module(mod_call_servers).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("account.hrl").

-define(RESPONSE_LIFETIME, 600).
-define(CLOUDFLARE_URL, "https://api.cloudflare.com").
-define(CLOUDFLARE_ZONE_ID, "b216df12845d4f13fd18718ac2bb861f").
-define(CLOUDFLARE_APP_ID, "e791102bd060439e8134f4623ac7e76c").
-define(TEMP_HALLOAPP_EMAIL, "murali@halloapp.com").
-define(CLOUDFLARE_AUTH_KEY, <<"cloudflare_auth_key">>).

%% API
-export([
    start/2,
    stop/1,
    depends/2,
    mod_options/1,
    get_stun_turn_servers/3,
    get_stun_turn_servers/0  % for tests
]).


start(_Host, _Opts) ->
    mod_aws:get_secret(?CLOUDFLARE_AUTH_KEY),
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

mod_options(_Host) ->
    [].

%%====================================================================
%% iq handlers
%%====================================================================

get_stun_turn_servers() -> get_ha_servers().


-spec get_stun_turn_servers(Uid :: uid(), PeerUid :: uid(), CallType :: 'CallType'())
    -> {ok, {list(pb_stun_server()), list(pb_turn_server())}}.
get_stun_turn_servers(Uid, _PeerUid, _CallType) ->
    %% Enabled only for nikola and murali as of now.
    case Uid =:= <<"1000000000739856658">> orelse Uid =:= <<"1000000000379188160">> of
        true ->
            case get_cloudflare_servers() of
                {ok, Result} -> Result;
                {error, _} -> get_ha_servers()
            end;
        false ->
            get_ha_servers()
    end.


-spec get_ha_servers() -> {list(#pb_stun_server{}), list(#pb_turn_server{})}.
get_ha_servers() ->
    StunServer = #pb_stun_server {
        host = <<"stun.halloapp.dev">>,
        port = 3478
    },

    TurnServer = #pb_turn_server{
        host = <<"turn.halloapp.dev">>,
        port = 3478,
        username = <<"clients">>,
        password = <<"2Nh57xoGpDy7Z7D1Sg0S">>
    },
    {[StunServer], [TurnServer]}.


-spec get_cloudflare_servers() -> {list(#pb_stun_server{}), list(#pb_turn_server{})}.
get_cloudflare_servers() ->
    try
        Data = jiffy:encode(#{ <<"data">> => #{ <<"lifetime">> => ?RESPONSE_LIFETIME }}),
        ?DEBUG("Data: ~p", [Data]),
        URL = ?CLOUDFLARE_URL ++ "/client/v4/zones/" ++ ?CLOUDFLARE_ZONE_ID ++ "/webrtc-turn/credential/" ++ ?CLOUDFLARE_APP_ID,
        ?DEBUG("URL: ~s", [URL]),
        Headers = fetch_cloudflare_headers(),
        HTTPOptions = [],
        Options = [],
        Type = "application/json",
        Body = Data,
        ?DEBUG("Body: ~p", [Body]),
        Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
        ?DEBUG("Response: ~p", [Response]),
        case Response of
            {ok, {{_, 200, _}, _ResHeaders, ResBody}} ->
                Json = jiffy:decode(ResBody, [return_maps]),
                ?DEBUG("Response: ~p", [Json]),
                TurnServer = parse_response(Json),
                {ok, {[], [TurnServer]}};
            _ ->
                ?ERROR("Failed to fetch cloudflare servers ~p", [Response]),
                {error, failed}
        end
    catch
        Class: Reason: Stacktrace ->
            ?ERROR("Failed to fetch cloudflare servers, crash:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, crashed}
    end.



-spec fetch_cloudflare_headers() -> string().
fetch_cloudflare_headers() ->
    [
        {"Content-Type", "application/json"},
        {"X-Auth-Email", ?TEMP_HALLOAPP_EMAIL},
        {"X-Auth-Key", util:to_list(mod_aws:get_secret(?CLOUDFLARE_AUTH_KEY))}
    ].


-spec parse_response(ResponseJson :: #{}) -> pb_turn_server().
parse_response(ResponseJson) ->
    Result = maps:get(<<"result">>, ResponseJson),
    Host = maps:get(<<"name">>, maps:get(<<"dns">>, Result)),
    Protocol = maps:get(<<"protocol">>, Result),
    Port = util:to_integer(lists:nth(2, string:split(Protocol, "/"))),
    Username = maps:get(<<"userid">>, Result),
    Password = maps:get(<<"credential">>, Result),
    TurnServer = #pb_turn_server{
        host = Host,
        port = Port,
        username = Username,
        password = Password
    },
    TurnServer.
