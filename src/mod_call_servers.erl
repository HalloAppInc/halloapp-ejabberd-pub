%%%---------------------------------------------------------------------------------
%%% File    : mod_call_servers.erl
%%%
%%% Copyright (C) 2021 HalloApp Inc.
%%%
%%%---------------------------------------------------------------------------------

-module(mod_call_servers).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("packets.hrl").
-include("account.hrl").
-include("proc.hrl").

-define(RESPONSE_LIFETIME, 600).
-define(CLOUDFLARE_URL, "https://api.cloudflare.com").
-define(CLOUDFLARE_ZONE_ID, "b216df12845d4f13fd18718ac2bb861f").
-define(CLOUDFLARE_APP_ID, "e791102bd060439e8134f4623ac7e76c").
-define(TEMP_HALLOAPP_EMAIL, "murali@halloapp.com").
-define(CLOUDFLARE_AUTH_KEY, <<"cloudflare_auth_key">>).

-define(REGIONS_FILE, "region_ips.json").
-define(CC_TO_REGION_FILE, "cc_to_region.json").
-define(DEFAULT_REGION, <<"us-east-1">>).

-define(COTURN_PORT1, 3478).
-define(COTURN_PORT2, 443).
-define(COTURN_USER, <<"clients">>).
% TODO(nikola): add a new password and put it in secrets manager
-define(COTURN_PASSWORD, <<"2Nh57xoGpDy7Z7D1Sg0S">>).


%% gen_mod API
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% API
-export([
    start_link/0,  % for tests
    get_stun_turn_servers/4,
    get_stun_turn_servers/0,  % for tests
    get_cloudflare_servers/0,
    get_ha_stun_turn_servers/3,
    get_ip/1,
    get_region/1,
    get_ips/1
]).


start_link() ->
    gen_server:start_link({local, ?PROC()}, ?MODULE, [], []).

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    mod_aws:get_secret(?CLOUDFLARE_AUTH_KEY),
    ok.


stop(_Host) ->
    gen_mod:stop_child(?PROC()),
    ok.


depends(_Host, _Opts) ->
    [{mod_aws, hard}].


mod_options(_Host) ->
    [].

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_) ->
    ets:new(mod_call_servers_cc_to_region, [set, named_table, protected, {read_concurrency, true}]),
    ets:new(mod_call_servers_region_to_ips, [set, named_table, protected, {read_concurrency, true}]),
    ?INFO("creating mod_call_servers ets tables"),
    load_regions(),
    load_cc_to_region(),
    {ok, #{}}.


terminate(Reason, _State) ->
    ?INFO("~p", [Reason]),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(_Request, _From, State) ->
    ?ERROR("Unexpected call ~p From: ~p", [_Request, _From]),
    {reply, {error, unhandled}, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast(crash, _State) ->
    error(test_crash);
handle_cast(_Request, State) ->
    ?DEBUG("Invalid request, ignoring it: ~p", [_Request]),
    {noreply, State}.


handle_info(Request, State) ->
    ?DEBUG("Unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.


%%====================================================================
%% API
%%====================================================================

-spec get_ip(CC :: binary()) -> {ok, binary()}.
get_ip(CC) ->
    {ok, Region} = get_region(CC),
    {ok, IPs} = get_ips(Region),
    [IP | _Rest] = util:random_shuffle(IPs),
    {ok, IP}.


-spec get_region(CC :: binary()) -> {ok, binary()}.
get_region(CC) ->
    case ets:lookup(mod_call_servers_cc_to_region, CC) of
        [{CC, Region}] -> {ok, Region};
        [] ->
            ?WARNING("Can not find region for CC: ~p", [CC]),
            {ok, ?DEFAULT_REGION}
    end.

-spec get_ips(Region :: binary()) -> {ok, [binary()]}.
get_ips(Region) ->
    Result = case ets:lookup(mod_call_servers_region_to_ips, Region) of
        [{Region, IPs}] when is_list(IPs) andalso length(IPs) > 0 ->
            IPs;
        [] ->
            ?ERROR("Can not find ips for region ~p", [Region]),
            [<<"turn.halloapp.dev">>]
    end,
    {ok, Result}.

-spec get_ha_stun_turn_servers(Uid :: uid(), PeerUid :: uid(), CallType :: atom()) -> {list(pb_stun_server()), list(pb_turn_server())}.
get_ha_stun_turn_servers(Uid, PeerUid, _CallType) ->
    IP = model_accounts:get_last_ipaddress(Uid),
    ?INFO("Uid: ~s LastIP: ~s", [Uid, IP]),
    CC = case IP of
        undefined -> <<"ZZ">>;
        _ -> mod_geodb:lookup(IP)
    end,
    ?INFO("Uid: ~s LastIP: ~s CC: ~s", [Uid, IP, CC]),
    {ok, ServerIP} = get_ip(CC),
    ?INFO("Uid: ~s CC: ~s Selected call server: ~s", [Uid, CC, ServerIP]),
    %% Send turn server addresses with both ports to dev clients.
    case dev_users:is_dev_uid(Uid) orelse dev_users:is_dev_uid(PeerUid) of
        true ->
            TurnServer1 = get_ha_turn_server(ServerIP, ?COTURN_PORT1),
            TurnServer2 = get_ha_turn_server(ServerIP, ?COTURN_PORT2),
            {[], [TurnServer2, TurnServer1]};
        false ->
            TurnServer1 = get_ha_turn_server(ServerIP, ?COTURN_PORT1),
            {[], [TurnServer1]}
    end.


-spec get_stun_turn_servers() -> {list(pb_stun_server()), list(pb_turn_server())}.
get_stun_turn_servers() ->
    get_dev_ha_servers().


-spec get_stun_turn_servers(CallId :: binary(), Uid :: uid(), PeerUid :: uid(), CallType :: 'CallType'())
    -> {list(pb_stun_server()), list(pb_turn_server())}.
get_stun_turn_servers(CallId, Uid, PeerUid, CallType) ->
    IsDevInvolvedInCall = dev_users:is_dev_uid(Uid) orelse dev_users:is_dev_uid(PeerUid),
    case IsDevInvolvedInCall of
        true ->
            {Stun1, Turn1} = get_ha_stun_turn_servers(Uid, PeerUid, CallType),
            case get_cloudflare_servers() of
                {ok, {Stun2, Turn2}} -> {Stun1 ++ Stun2, Turn1 ++ Turn2};
                {error, _} -> {Stun1, Turn1}
            end;
        false ->
            CallHash = call_id_hash(CallId),
            case CallHash rem 2 =:= 0 of
                true ->
                    case get_cloudflare_servers() of
                        {ok, Result} -> Result;
                        {error, _} -> get_ha_stun_turn_servers(Uid, PeerUid, CallType)
                    end;
                false ->
                    get_ha_stun_turn_servers(Uid, PeerUid, CallType)
            end
    end.


-spec call_id_hash(CallId :: binary()) -> integer().
call_id_hash(CallId) ->
    <<Result:32/integer, _Rest/binary>> = crypto:hash(sha256, CallId),
    Result.

-spec get_dev_ha_servers() -> {list(#pb_stun_server{}), list(#pb_turn_server{})}.
get_dev_ha_servers() ->
    TurnServer1 = get_ha_turn_server(<<"35.175.122.234">>, ?COTURN_PORT1),
    TurnServer2 = get_ha_turn_server(<<"35.175.122.234">>, ?COTURN_PORT2),
    {[], [TurnServer2, TurnServer1]}.


get_ha_turn_server(Host, Port) ->
    #pb_turn_server{
        host = Host,
        port = Port,
        username = ?COTURN_USER,
        password = ?COTURN_PASSWORD
    }.


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


-spec load_regions() -> ok.
load_regions() ->
    Filename = filename:join(misc:data_dir(), ?REGIONS_FILE),
    {ok, Bin} = file:read_file(Filename),
    Map = jiffy:decode(Bin, [return_maps]),
    maps:map(
        fun (K, V) ->
            ets:insert(mod_call_servers_region_to_ips, {K, V})
        end,
        Map),
    ok.


-spec load_cc_to_region() -> ok.
load_cc_to_region() ->
    Filename = filename:join(misc:data_dir(), ?CC_TO_REGION_FILE),
    {ok, Bin} = file:read_file(Filename),
    Lines = binary:split(Bin, [<<"\n">>], [global]),
    Bin2 = erlang:iolist_to_binary(lists:map(
        fun (Line) ->
            [Line2 | _Comment] =  binary:split(Line, [<<"//">>], [global]),
            Line2
        end,
        Lines)),
    Map = jiffy:decode(Bin2, [return_maps]),
    maps:map(
        fun (CC, Region) ->
            ets:insert(mod_call_servers_cc_to_region, {CC, Region})
        end,
        Map),
    ok.
