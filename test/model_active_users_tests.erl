%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 01. Jul 2020 1:37 PM
%%%-------------------------------------------------------------------
-module(model_active_users_tests).
-author("josh").

-include("time.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID, 1000000024384563984).
-define(NAME, <<"Name">>).
-define(USER_AGENT, <<"HalloApp/Android1.0">>).

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%

set_test() ->
    setup(),
    ?assertEqual(0, model_active_users:count_active_users_between(0, inf)),
    ok = model_accounts:set_last_activity(integer_to_binary(?UID), util:now_ms(), available),
    ?assertEqual(1, model_active_users:count_active_users_between(0, inf)).


count_test() ->
    setup(),
    ok = create_accounts(100),
    Now = util:now_ms(),
    Days1 = length([model_accounts:set_last_activity(
        integer_to_binary(?UID + Num), Now - random:uniform(?DAYS_MS), available
        ) || Num <- lists:seq(1,25)
    ]),
    Days7 = length([model_accounts:set_last_activity(
        integer_to_binary(?UID + Num), Now - ?WEEKS_MS + random:uniform(6 * ?DAYS_MS), available
    ) || Num <- lists:seq(26,50)
    ]),
    Days28 = length([model_accounts:set_last_activity(
        integer_to_binary(?UID + Num), Now - (28 * ?DAYS_MS) + random:uniform(14 * ?DAYS_MS), available
    ) || Num <- lists:seq(51,75)
    ]),
    Days30 = length([model_accounts:set_last_activity(
        integer_to_binary(?UID + Num), Now - (30 * ?DAYS_MS) + random:uniform(2 * ?DAYS_MS), available
    ) || Num <- lists:seq(76,100)
    ]),
    ?assertEqual(Days1, model_active_users:count_active_users_1day()),
    ?assertEqual(Days1 + Days7, model_active_users:count_active_users_7day()),
    ?assertEqual(Days1 + Days7 + Days28, model_active_users:count_active_users_28day()),
    ?assertEqual(Days1 + Days7 + Days28 + Days30, model_active_users:count_active_users_30day()),
    ?assertEqual(100, model_active_users:count_active_users_between(0, inf)).


%% -------------------------------------------- %%
%% Internal functions
%% -------------------------------------------- %%

setup() ->
    mod_redis:start(undefined, []),
    clear(),
    ok.


clear() ->
    ok = gen_server:cast(redis_accounts_client, flushdb).


create_accounts(0) ->
    ok;

create_accounts(Num) ->
    Uid = integer_to_binary(?UID + Num),
    Phone = integer_to_binary(16175280000 + Num),
    ok = model_accounts:create_account(Uid, Phone, ?NAME, ?USER_AGENT),
    create_accounts(Num - 1).

