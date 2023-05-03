%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 30. Jul 2020 2:54 PM
%%%-------------------------------------------------------------------
-module(ejabberd_auth_tests).
-author("josh").

-include_lib("tutil.hrl").
-include("password.hrl").

-define(UID, <<"1">>).
-define(PHONE, <<"16175280000">>).
-define(SERVER, <<"s.halloapp.net">>).
-define(SPUB, <<"spub">>).
-define(NAME, <<"Testname">>).
-define(UA, <<"HalloApp/iPhone1.0">>).
-define(CAMPAIGN_ID, <<"cmpn">>).
-define(CODE, <<"111111">>).


%%====================================================================
%% Tests
%%====================================================================

check_spub(_) ->
    ok = ejabberd_auth:set_spub(?UID, ?SPUB),
    {ok, S} = model_auth:get_spub(?UID),
    SPub = S#s_pub.s_pub,
    [?_assert(SPub /= <<"">>),
    ?_assert(ejabberd_auth:check_spub(?UID, ?SPUB)),
    ?_assertNot(ejabberd_auth:check_spub(?UID, <<"nopass">>))].


check_and_register(_) ->
    {ok, Uid1, Result1} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?SPUB, ?UA, ?CAMPAIGN_ID),
    {ok, Uid2, Result2} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?SPUB, ?UA, ?CAMPAIGN_ID),
    [?_assertEqual(Uid1, Uid2),
    ?_assertEqual(Result1, register),
    ?_assertEqual(Result2, login)].


ha_try_register(_) ->
    {ok, SPub, Uid, register} = ejabberd_auth:ha_try_register(?PHONE, <<>>, ?SPUB, ?UA, <<>>),
    [?_assertEqual(?SPUB, SPub),
    ?_assert(model_accounts:account_exists(Uid)),
    ?_assert(ejabberd_auth:check_spub(Uid, ?SPUB)),
    ?_assertEqual({ok, ?PHONE}, model_accounts:get_phone(Uid)),
    ?_assertEqual({ok, Uid}, model_phone:get_uid(?PHONE, ?HALLOAPP)),
    ?_assertEqual({ok, ?UA}, model_accounts:get_signup_user_agent(Uid)),
    ?_assertEqual(?HALLOAPP, util_uid:get_app_type(Uid))].

ka_try_register(_) ->
    {ok, SPub, Uid, register} = ejabberd_auth:ha_try_register(?PHONE, <<>>, ?SPUB, <<"Katchup/iOS1.2.93">>, <<>>),
    [?_assertEqual(?SPUB, SPub),
    ?_assert(model_accounts:account_exists(Uid)),
    ?_assert(ejabberd_auth:check_spub(Uid, ?SPUB)),
    ?_assertEqual({ok, ?PHONE}, model_accounts:get_phone(Uid)),
    ?_assertEqual({ok, Uid}, model_phone:get_uid(?PHONE, ?KATCHUP)),
    ?_assertEqual({ok, <<"Katchup/iOS1.2.93">>}, model_accounts:get_signup_user_agent(Uid)),
    ?_assertEqual(?KATCHUP, util_uid:get_app_type(Uid))].


try_enroll(_) ->
    {ok, AttemptId, _} = ejabberd_auth:try_enroll(?PHONE, ?HALLOAPP, ?CODE, <<>>),
    [?_assertEqual({ok, ?CODE}, model_phone:get_sms_code2(?PHONE, ?HALLOAPP, AttemptId))].


user_exists(_) ->
    UserDoesntExist = ejabberd_auth:user_exists(?UID),
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?SPUB, ?UA, ?CAMPAIGN_ID),
    UserExists = ejabberd_auth:user_exists(Uid),
    [?_assertNot(UserDoesntExist),
    ?_assert(UserExists)].


remove_user(_) ->
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?SPUB, ?UA, ?CAMPAIGN_ID),
    Exists = ejabberd_auth:user_exists(Uid),
    ok = ejabberd_auth:remove_user(Uid, ?SERVER),
    [?_assert(Exists),
    ?_assertNot(ejabberd_auth:user_exists(Uid))].


ejabberd_auth_test_() ->
    % ! NOTE: This tutil:setup_foreach call is included to demonstrate usage of the tutil function,
    % ! but the same functionality could be accomplished by simply having the pertinent functions end
    % ! in _testset (as there is no special cleanup or control being passed, and the setup function
    % ! is called setup/0). In fact, the auto-run magic calls this exact function with setup/0 and 
    % ! the list of _testset functions to run them.
    [tutil:setup_foreach(fun setup/0, [
        fun check_spub/1,
        fun ha_try_register/1,
        fun ka_try_register/1,
        fun try_enroll/1,
        fun remove_user/1
        ]),
    tutil:setup_once(
        fun() ->
            tutil:combine_cleanup_info([
                setup(),
                tutil:setup([{meck, ejabberd_sm, kick_user, fun(_, _) -> 1 end}])
            ])
        end,
        fun check_and_register/1
        ),
    tutil:setup_once(
        fun() ->
            tutil:combine_cleanup_info([
                setup(),
                tutil:setup([{meck, ejabberd_router, is_my_host, fun(_) -> true end}])
            ])
        end,
        fun user_exists/1
        )].

%%====================================================================
%% Internal functions
%%====================================================================

setup() ->
    tutil:setup([
        {start, stringprep},
        {redis, [redis_auth, redis_phone, redis_accounts]}
    ]).

