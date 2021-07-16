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
    model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?UA),
    model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?UA),
    model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?UA),
    model_accounts:create_account(?UID4, ?PHONE4, ?NAME4, ?UA),
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
