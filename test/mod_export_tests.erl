%%%-------------------------------------------------------------------
%%% File: mod_export_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_export_tests).
-author("nikola").

-include("account_test_data.hrl").
-include_lib("eunit/include/eunit.hrl").


setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    setup_accounts(),
    ok.

setup_accounts() ->
    model_accounts:create_account(?UID1, ?PHONE1, ?UA),
    model_accounts:set_name(?UID1, ?NAME1),
    model_accounts:create_account(?UID2, ?PHONE2, ?UA),
    model_accounts:set_name(?UID2, ?NAME2),
    model_accounts:create_account(?UID3, ?PHONE3, ?UA),
    model_accounts:set_name(?UID3, ?NAME3),
    model_accounts:create_account(?UID4, ?PHONE4, ?UA),
    model_accounts:set_name(?UID4, ?NAME4),
    ok.

clear() ->
    tutil:cleardb(redis_accounts).

format_privacy_list_test() ->
    setup(),
    ?assertEqual(
        [
            #{uid => ?UID1, phone => <<"+", ?PHONE1/binary>>},
            #{uid => <<"20">>, phone => undefined}
        ],
        mod_export:format_privacy_list([?UID1, <<"20">>])
    ),
    ok.
