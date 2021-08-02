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
    ok = model_ip_addresses:delete_ip_address(?IP1, ?CC1),
    ok = model_ip_addresses:delete_ip_address(?IP2, ?CC2),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP1, ?CC1),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP2, ?CC2),
    ok = model_ip_addresses:add_ip_address(?IP1, ?CC1, ?TIME1),
    {ok, {1, ?TIME1}} = model_ip_addresses:get_ip_address_info(?IP1, ?CC1),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP2, ?CC2),
    ok = model_ip_addresses:add_ip_address(?IP1, ?CC1, ?TIME2),
    {ok, {2, ?TIME2}} = model_ip_addresses:get_ip_address_info(?IP1, ?CC1),
    ok = model_ip_addresses:add_ip_address(?IP2, ?CC2, ?TIME1),
    {ok, {1, ?TIME1}} = model_ip_addresses:get_ip_address_info(?IP2, ?CC2),
    ok = model_ip_addresses:add_ip_address(?IP2, ?CC2, ?TIME2),
    {ok, {2, ?TIME2}} = model_ip_addresses:get_ip_address_info(?IP2, ?CC2),
    ok = model_ip_addresses:delete_ip_address(?IP1, ?CC1),
    ok = model_ip_addresses:delete_ip_address(?IP2, ?CC2),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP1, ?CC1),
    {ok, {undefined, undefined}} = model_ip_addresses:get_ip_address_info(?IP2, ?CC2).

