%%%-------------------------------------------------------------------
%%% File: model_ip_addresses_tests.erl
%%% Copyright (C) 2021, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_ip_addresses_tests).
-author("vipin").

-include_lib("eunit/include/eunit.hrl").

-define(IP1, "89.237.194.192").
-define(CC1, <<"KG">>).
-define(TIME1, 1533626578).
-define(IP2, "2409:4063:2202:d74d:33dd:75b:1b8f:49ed").
-define(CC2, <<"UA">>).
-define(TIME2, 1533626579).

setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_phone).


ip_address_test() ->
    setup(),
    ok = model_ip_addresses:delete_ip_address(?IP1),
    ok = model_ip_addresses:delete_ip_address(?IP2),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP1),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP2),
    ok = model_ip_addresses:add_ip_address(?IP1, ?TIME1),
    {ok, {1, ?TIME1}} = model_ip_addresses:get_ip_address_info(?IP1),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP2),
    ok = model_ip_addresses:add_ip_address(?IP1, ?TIME2),
    {ok, {2, ?TIME2}} = model_ip_addresses:get_ip_address_info(?IP1),
    ok = model_ip_addresses:add_ip_address(?IP2, ?TIME1),
    {ok, {1, ?TIME1}} = model_ip_addresses:get_ip_address_info(?IP2),
    ok = model_ip_addresses:add_ip_address(?IP2, ?TIME2),
    {ok, {2, ?TIME2}} = model_ip_addresses:get_ip_address_info(?IP2),
    ok = model_ip_addresses:delete_ip_address(?IP1),
    ok = model_ip_addresses:delete_ip_address(?IP2),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP1),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP2).


block_ip_address_test() ->
    setup(),
    ?assertEqual(false, model_ip_addresses:is_ip_blocked(?IP1)),
    ?assertEqual(false, model_ip_addresses:is_ip_blocked(?IP2)),
    ok = model_ip_addresses:remove_blocked_ip_address(?IP1),
    ok = model_ip_addresses:remove_blocked_ip_address(?IP2),
    ?assertEqual(false, model_ip_addresses:is_ip_blocked(?IP1)),
    ?assertEqual(false, model_ip_addresses:is_ip_blocked(?IP2)),

    %% Add ip1 to blocklist.
    ?assertEqual(ok, model_ip_addresses:add_blocked_ip_address(?IP1, <<"ha">>)),
    ?assertEqual({true, undefined}, model_ip_addresses:is_ip_blocked(?IP1)),
    ?assertEqual(false, model_ip_addresses:is_ip_blocked(?IP2)),

    %% Add ip2 to blocklist
    ?assertEqual(ok, model_ip_addresses:add_blocked_ip_address(?IP2, <<"maxm">>)),
    ?assertEqual({true, undefined}, model_ip_addresses:is_ip_blocked(?IP1)),
    ?assertEqual({true, undefined}, model_ip_addresses:is_ip_blocked(?IP2)),

    %% Record time and clear time.
    Timestamp1 = util:now(),
    ?assertEqual(ok, model_ip_addresses:record_blocked_ip_address(?IP1, Timestamp1)),
    ?assertEqual({true, Timestamp1}, model_ip_addresses:is_ip_blocked(?IP1)),
    ?assertEqual(ok, model_ip_addresses:clear_blocked_ip_address(?IP1)),
    ?assertEqual({true, undefined}, model_ip_addresses:is_ip_blocked(?IP1)),

    ok = model_ip_addresses:remove_blocked_ip_address(?IP1),
    ok = model_ip_addresses:remove_blocked_ip_address(?IP2),
    ?assertEqual(false, model_ip_addresses:is_ip_blocked(?IP1)),
    ?assertEqual(false, model_ip_addresses:is_ip_blocked(?IP2)),
    ok.


ip_attempt_test() ->
    setup(),

    Now = util:now(),
    ?assertEqual(0, model_ip_addresses:get_ip_code_attempts(?IP1, Now)),
    ?assertEqual(1, model_ip_addresses:add_ip_code_attempt(?IP1, Now)),
    ?assertEqual(2, model_ip_addresses:add_ip_code_attempt(?IP1, Now)),
    ?assertEqual(2, model_ip_addresses:get_ip_code_attempts(?IP1, Now)),
    ?assertEqual(0, model_ip_addresses:get_ip_code_attempts(?IP2, Now)),

    % check expiration time
    {ok, TTLBin} = model_phone:q(["TTL", model_ip_addresses:ip_attempt_key(?IP1, Now)]),
    TTL = util_redis:decode_int(TTLBin),
    ?assertEqual(true, TTL > 0),
    ok.

