%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_call_servers_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").


setup() ->
    tutil:setup(),
    ha_redis:start(),
    application:ensure_all_started(locus),
    clear(),
    meck_load(),
    ok.

clear() ->
    tutil:cleardb(redis_accounts).

meck_load() ->
    meck:new(mod_aws, [passthrough]),
    meck:expect(mod_aws, get_secret, fun(_Key) -> undefined end),
    ok.

meck_unload() ->
    meck:unload(mod_aws).

start_test() ->
    setup(),
    mod_geodb:start(undefined, []),
    mod_call_servers:start_link(),
    meck_unload(),
    ok.

get_stun_turn_servers_basic_test() ->
    setup(),
    {[StunServer], [TurnServer]} = mod_call_servers:get_stun_turn_servers(),
    ?assertEqual(<<"stun.halloapp.dev">>, StunServer#pb_stun_server.host),
    ?assertEqual(3478, StunServer#pb_stun_server.port),
    ?assertEqual(<<"turn.halloapp.dev">>, TurnServer#pb_turn_server.host),
    ?assertEqual(3478, TurnServer#pb_turn_server.port),
    ?assertEqual(<<"clients">>, TurnServer#pb_turn_server.username),
    meck_unload(),
    ok.

get_stun_turn_servers_by_ip_test() ->
    setup(),
    model_accounts:set_last_ipaddress(?UID1, ?US_IP),
    model_accounts:set_last_ipaddress(?UID2, ?DE_IP),
    check_server_from_region(?UID1, ?UID2, <<"us-east-1">>),
    check_server_from_region(?UID2, ?UID1, <<"eu-central-1">>),
    meck_unload(),
    ok.

get_stun_turn_servers_by_ip2_test() ->
    setup(),
    model_accounts:set_last_ipaddress(?UID1, ?SA_IP),
    model_accounts:set_last_ipaddress(?UID2, ?BR_IP),
    check_server_from_region(?UID1, ?UID2, <<"me-south-1">>),
    check_server_from_region(?UID2, ?UID1, <<"sa-east-1">>),
    meck_unload(),
    ok.

check_server_from_region(Uid1, Uid2, Region) ->
    {[StunServer], [TurnServer]} = mod_call_servers:get_stun_turn_servers(Uid1, Uid2, audio),
    {ok, USServers} = mod_call_servers:get_ips(Region),
    Host = StunServer#pb_stun_server.host,
    % make sure the turn and stun servers have the same host
    ?assertEqual(StunServer#pb_stun_server.host, TurnServer#pb_turn_server.host),
    % check if the server we got is one of the us servers
    ?assertEqual(true, lists:member(Host, USServers)),
    % check that the ports are as expected
    ?assertEqual(3478, StunServer#pb_stun_server.port),
    ?assertEqual(3478, TurnServer#pb_turn_server.port),
    ?assertEqual(<<"clients">>, TurnServer#pb_turn_server.username),
    ok.


get_ip_test() ->
    setup(),
    check_country_to_region(<<"US">>, <<"us-east-1">>),
    check_country_to_region(<<"FR">>, <<"eu-central-1">>),
    check_country_to_region(<<"GB">>, <<"eu-west-2">>),
    check_country_to_region(<<"RU">>, <<"eu-central-1">>),
    check_country_to_region(<<"IN">>, <<"ap-south-1">>),
    check_country_to_region(<<"CN">>, <<"ap-east-1">>),
    check_country_to_region(<<"ID">>, <<"ap-southeast-1">>),
    check_country_to_region(<<"JP">>, <<"ap-northeast-3">>),
    check_country_to_region(<<"KP">>, <<"ap-northeast-2">>),
    check_country_to_region(<<"AU">>, <<"ap-southeast-2">>),
    check_country_to_region(<<"AE">>, <<"me-south-1">>),
    check_country_to_region(<<"BR">>, <<"sa-east-1">>),
    check_country_to_region(<<"MX">>, <<"us-west-1">>),
    meck_unload(),
    ok.

check_country_to_region(CC, Region) ->
    {ok, ServerIP} = mod_call_servers:get_ip(CC),
    {ok, Servers} = mod_call_servers:get_ips(Region),
    ?assertEqual(true, lists:member(ServerIP, Servers)),
    ok.
