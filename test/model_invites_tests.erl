%%%-------------------------------------------------------------------
%%% File: mod_invites_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_invites_tests).
-author("nikola").

-include("invites.hrl").
-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1">>).
-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).
-define(USER_AGENT1, <<"HalloApp/Android1.0">>).

-define(UID2, <<"2">>).
-define(PHONE2, <<"16175287001">>).
-define(NAME2, <<"Name2">>).
-define(USER_AGENT2, <<"HalloApp/Android1.0">>).

-define(UID3, <<"3">>).
-define(PHONE3, <<"16175287002">>).
-define(NAME3, <<"Name3">>).
-define(USER_AGENT3, <<"HalloApp/Android1.0">>).



%% -------------------------------------------- %%
%% Tests for API functions
%% --------------------------------------------	%%
%%

get_invites_remaining_test() ->
    setup(),
    ?assertEqual({ok, undefined, undefined}, model_invites:get_invites_remaining(?UID1)),
    Now = util:now(),
    ok = model_invites:record_invite(?UID1, ?PHONE2, 9, Now),
    ?assertEqual({ok, 9, Now}, model_invites:get_invites_remaining(?UID1)),
    ok.

record_invite_test() ->
    setup(),
    Now1 = util:now(),
    ok = model_invites:record_invite(?UID1, ?PHONE2, 9, Now1),
    ?assertEqual({ok, 9, Now1}, model_invites:get_invites_remaining(?UID1)),

    Now2 = util:now(),
    ok = model_invites:record_invite(?UID2, ?PHONE3, 5, Now2),
    ?assertEqual({ok, 5, Now2}, model_invites:get_invites_remaining(?UID2)),
    ok.

is_invited_test() ->
    setup(),
    Now1 = util:now(),
    ?assertEqual(false, model_invites:is_invited(?PHONE2)),
    ok = model_invites:record_invite(?UID1, ?PHONE2, 9, Now1),
    ?assertEqual(true, model_invites:is_invited(?PHONE2)),

    % expiration test
    Now2 = Now1 + model_invites:get_invite_ttl() + 100,
    ?assertEqual(true, model_invites:is_invited(?PHONE2, Now1)),
    ?assertEqual(false, model_invites:is_invited(?PHONE2, Now2)),
    ok.

is_invited_by_test() ->
    setup(),
    Now1 = util:now(),
    ?assertEqual(false, model_invites:is_invited_by(?PHONE2, ?UID1)),
    ok = model_invites:record_invite(?UID1, ?PHONE2, 9, Now1),
    ?assertEqual(true, model_invites:is_invited_by(?PHONE2, ?UID1)),
    ?assertEqual(false, model_invites:is_invited_by(?PHONE2, ?UID3)),

    % expiration test
    Now2 = Now1 + model_invites:get_invite_ttl() + 100,
    ?assertEqual(true, model_invites:is_invited_by(?PHONE2, ?UID1, Now1)),
    ?assertEqual(false, model_invites:is_invited_by(?PHONE2, ?UID2, Now2)),
    ok.

set_invites_left_test() ->
    setup(),
    ?assertEqual({ok, undefined, undefined}, model_invites:get_invites_remaining(?UID1)),
    Now = util:now(),
    ok = model_invites:record_invite(?UID1, ?PHONE2, 9, Now),
    ?assertEqual({ok, 9, Now}, model_invites:get_invites_remaining(?UID1)),
    ok = model_invites:set_invites_left(?UID1, 20),
    ?assertEqual({ok, 20, Now}, model_invites:get_invites_remaining(?UID1)),
    ok.

get_inviters_list_test() ->
    setup(),
    Now = util:now(),

    ?assertEqual({ok, []}, model_invites:get_inviters_list(?PHONE2)),
    Ts1 = Now - 10,
    ok = model_invites:record_invite(?UID1, ?PHONE2, 10, Ts1),
    Ts2 = Now - 2,
    ok = model_invites:record_invite(?UID3, ?PHONE2, 10, Ts2),
    ?assertEqual(
        {ok, [{?UID1, util:to_binary(Ts1)}, {?UID3, util:to_binary(Ts2)}]},
        model_invites:get_inviters_list(?PHONE2)),

    % test expiration
    Ts3 = Now + model_invites:get_invite_ttl() - 15, % 60 days from now - 15 sec, expect both
    ?assertEqual(
        {ok, [{?UID1, util:to_binary(Ts1)}, {?UID3, util:to_binary(Ts2)}]},
        model_invites:get_inviters_list(?PHONE2, Ts3)),

    Ts4 = Now + model_invites:get_invite_ttl() - 5, % 60 days from now - 5 sec, expect one
    ?assertEqual(
        {ok, [{?UID3, util:to_binary(Ts2)}]},
        model_invites:get_inviters_list(?PHONE2, Ts4)),

    Ts5 = Now + model_invites:get_invite_ttl(), % 60 days from now expect none
    ?assertEqual(
        {ok, []},
        model_invites:get_inviters_list(?PHONE2, Ts5)),
    ok.

get_sent_invites_test() ->
    setup(),
    Now = util:now(),

    ?assertEqual({ok, []}, model_invites:get_sent_invites(?UID1)),
    Ts1 = Now - 10,
    ok = model_invites:record_invite(?UID1, ?PHONE2, 10, Ts1),
    Ts2 = Now - 2,
    ok = model_invites:record_invite(?UID1, ?PHONE3, 10, Ts2),
    ?assertEqual(
        {ok, [?PHONE2, ?PHONE3]},
        model_invites:get_sent_invites(?UID1)),

    % test expiration
    Ts3 = Now + model_invites:get_invite_ttl() - 15, % 60 days from now - 15 sec, expect both
    ?assertEqual(
        {ok, [?PHONE2, ?PHONE3]},
        model_invites:get_sent_invites(?UID1, Ts3)),

    Ts4 = Now + model_invites:get_invite_ttl() - 5, % 60 days from now - 5 sec, expect one
    ?assertEqual(
        {ok, [?PHONE3]},
        model_invites:get_sent_invites(?UID1, Ts4)),

    Ts5 = Now + model_invites:get_invite_ttl(), % 60 days from now expect none
    ?assertEqual(
        {ok, []},
        model_invites:get_sent_invites(?UID1, Ts5)),
    ok.


duplicate_invites_test() ->
    setup(),
    Now = util:now(),

    ?assertEqual({ok, []}, model_invites:get_sent_invites(?UID1)),
    ?assertEqual({ok, []}, model_invites:get_inviters_list(?PHONE2)),
    ok = model_invites:record_invite(?UID1, ?PHONE2, 10, Now),
    ok = model_invites:record_invite(?UID1, ?PHONE3, 10, Now + 1),
    ok = model_invites:record_invite(?UID3, ?PHONE2, 10, Now + 2),
    ?assertEqual(
        {ok, [?PHONE2, ?PHONE3]},
        model_invites:get_sent_invites(?UID1)),
    ?assertEqual(
        {ok, [{?UID1, util:to_binary(Now)}, {?UID3, util:to_binary(Now + 2)}]},
        model_invites:get_inviters_list(?PHONE2)),

    ok = model_invites:record_invite(?UID1, ?PHONE2, 10, Now + 10),
    ?assertEqual(
        {ok, [?PHONE3, ?PHONE2]},
        model_invites:get_sent_invites(?UID1)),
    ?assertEqual(
        {ok, [{?UID3, util:to_binary(Now + 2)}, {?UID1, util:to_binary(Now + 10)}]},
        model_invites:get_inviters_list(?PHONE2)),
    ok.


%% --------------------------------------------	%%
%% Internal functions
%% -------------------------------------------- %%

setup() ->
    tutil:setup(),
    ha_redis:start(),
    phone_number_util:init(undefined, undefined),
    clear(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1),
    ok = model_accounts:set_name(?UID1, ?NAME1),
    ok.

clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_phone).

