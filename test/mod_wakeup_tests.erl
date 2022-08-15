%%%-------------------------------------------------------------------------------------------
%%% File    : mod_wakeup_tests.erl
%%%
%%% Copyright (C) 2022 HalloApp inc.
%%%-------------------------------------------------------------------------------------------

-module(mod_wakeup_tests).
-author('michelle').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").

-define(UID1, <<"10000000000000001">>).
-define(UID2, <<"10000000000000002">>).
-define(UID3, <<"10000000000000003">>).
-define(UID4, <<"10000000000000004">>).

-define(TREF, make_ref()).

setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    ha_redis:start(),
    ok.


remind_wakeup_test() ->
    setup(),
    % normal pushes reset wakeup push counter; wakeup pushes increment counter
    #{?UID1 := {0,TRef, _}} = mod_wakeup:remind_wakeup(?UID1, #{}, pb_feed_item),
    #{?UID1 := {1,TRef2, _}} = mod_wakeup:remind_wakeup(?UID1, #{}, pb_wake_up),
    ?assertNotEqual(TRef, TRef2),

    WakeupMap = #{?UID1 => {2, ?TREF, util:now()}},
    #{?UID1 := {0,TRef3, _}} = mod_wakeup:remind_wakeup(?UID1,  WakeupMap, pb_feed_item),
    #{?UID1 := {3,TRef4, _}} = mod_wakeup:remind_wakeup(?UID1,  WakeupMap, pb_wake_up),
    ?assertNotEqual(TRef3, TRef4),

    #{?UID1 := {2,_,_}, ?UID2 := {0,TRef5,_}} = mod_wakeup:remind_wakeup(?UID2, WakeupMap, pb_feed_item),
    #{?UID1 := {2,_,_}, ?UID2 := {1,TRef6,_}} = mod_wakeup:remind_wakeup(?UID2, WakeupMap, pb_wake_up),
    ?assertNotEqual(TRef5, TRef6),
    ok.


check_wakeup_test() ->
    setup(),
    Now = util:now(),
    tutil:meck_init(ejabberd_router, route, fun(_) -> ok end),
    tutil:meck_init(model_accounts, get_last_connection_time, fun(_) -> 1 end),

    #{} = mod_wakeup:check_wakeup(?UID1, #{}),
    
    % When push num attempts < 10, wake up push should be sent
    WakeupMap = #{?UID1 => {3, ?TREF, Now}, ?UID3 => {4, ?TREF, Now}, ?UID4 => {5, ?TREF, Now}},
    WakeupMap = mod_wakeup:check_wakeup(?UID1, WakeupMap),
    WakeupMap = mod_wakeup:check_wakeup(?UID2, WakeupMap),
    WakeupMap = mod_wakeup:check_wakeup(?UID3, WakeupMap),
    WakeupMap = mod_wakeup:check_wakeup(?UID4, WakeupMap),
    ?assert(meck:called(ejabberd_router, route,
            [#pb_msg{id = '_', to_uid = ?UID1, payload = #pb_wake_up{alert_type = alert}}])),
    ?assert(meck:called(ejabberd_router, route,
            [#pb_msg{id = '_', to_uid = ?UID3, payload = #pb_wake_up{alert_type = silent}}])),
    ?assert(meck:called(ejabberd_router, route,
            [#pb_msg{id = '_', to_uid = ?UID4, payload = #pb_wake_up{alert_type = alert}}])),

    % When push num attempts >= 10, stop trying
    WakeupMap2 = #{?UID1 => {11, ?TREF, Now}},
    #{} = mod_wakeup:check_wakeup(?UID1, WakeupMap2),
    WakeupMap2 = mod_wakeup:check_wakeup(?UID2, WakeupMap2),

    tutil:meck_finish(ejabberd_router),
    tutil:meck_finish(model_accounts),
    ok.

