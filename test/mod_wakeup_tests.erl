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
-define(TREF, make_ref()).

setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    ha_redis:start(),
    ok.


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod, [passthrough]),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).


remind_wakeup_test() ->
    setup(),
    % normal pushes reset wakeup push counter; wakeup pushes increment counter
    #{?UID1 := {0,TRef}} = mod_wakeup:remind_wakeup(?UID1, #{}, pb_feed_item),
    #{?UID1 := {1,TRef2}} = mod_wakeup:remind_wakeup(?UID1, #{}, pb_wake_up),
    ?assertNotEqual(TRef, TRef2),

    WakeupMap = #{?UID1 => {2, ?TREF}},
    #{?UID1 := {0,TRef3}} = mod_wakeup:remind_wakeup(?UID1,  WakeupMap, pb_feed_item),
    #{?UID1 := {3,TRef4}} = mod_wakeup:remind_wakeup(?UID1,  WakeupMap, pb_wake_up),
    ?assertNotEqual(TRef3, TRef4),

    #{?UID1 := {2,_}, ?UID2 := {0,TRef5}} = mod_wakeup:remind_wakeup(?UID2, WakeupMap, pb_feed_item),
    #{?UID1 := {2,_}, ?UID2 := {1,TRef6}} = mod_wakeup:remind_wakeup(?UID2, WakeupMap, pb_wake_up),
    ?assertNotEqual(TRef5, TRef6),
    ok.


cancel_wakeup_test() ->
    setup(),
    #{} = mod_wakeup:cancel_wakeup(?UID1, #{}),
    #{} = mod_wakeup:cancel_wakeup(?UID1, #{?UID1 => {1, ?TREF}}),
    WakeupMap = #{?UID1 => {1, ?TREF}, ?UID2 => {1, ?TREF}},
    #{?UID2 := {1, _}} = mod_wakeup:cancel_wakeup(?UID1, WakeupMap),
    ok.


check_wakeup_test() ->
    meck_init(ejabberd_router, route, fun(_) -> ok end),

    #{} = mod_wakeup:check_wakeup(?UID1, #{}),
    
    % When push num attempts < 10, wake up push should be sent
    WakeupMap = #{?UID1 => {2, ?TREF}},
    WakeupMap = mod_wakeup:check_wakeup(?UID1, WakeupMap),
    WakeupMap = mod_wakeup:check_wakeup(?UID2, WakeupMap),
    ?assert(meck:called(ejabberd_router, route, [#pb_msg{id = '_', to_uid = ?UID1, payload = #pb_wake_up{}}])),

    % When push num attempts >= 10, stop trying
    WakeupMap2 = #{?UID1 => {11, ?TREF}},
    #{} = mod_wakeup:check_wakeup(?UID1, WakeupMap2),
    WakeupMap2 = mod_wakeup:check_wakeup(?UID2, WakeupMap2),

    meck_finish(ejabberd_router),
    ok.
