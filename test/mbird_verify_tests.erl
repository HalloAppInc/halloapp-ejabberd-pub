%%%-------------------------------------------------------------------
%%% File: mbird_verify_tests.erl
%%% Copyright (C) 2021, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mbird_verify_tests).
-author("michelle").

-include_lib("eunit/include/eunit.hrl").
-include("sms.hrl").

-define(PHONE, <<"14703381473">>).
-define(MBIRD_CODE, <<"000000">>).
-define(CODE, <<"041200">>).
-define(SID1, <<"sid1">>).
-define(SID2, <<"sid2">>).


verify_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(mbird_verify, verify_code_internal,
        fun(_,Code,Sid) ->
            Status = case Code =:= ?CODE of
                true -> accepted;
                false -> delivered
            end,
            GatewayResponse = #gateway_response{gateway_id = Sid, gateway = mbird_verify, status = Status},
            model_phone:add_gateway_callback_info(GatewayResponse),
            Status =:= accepted
        end),
    meck:new(mod_sms, [passthrough]),
    {ok, AttemptId1, _} = model_phone:add_sms_code2(?PHONE, ?MBIRD_CODE),
    ok = model_phone:add_gateway_response(?PHONE, AttemptId1,
        #gateway_response{gateway = mbird_verify, gateway_id = ?SID1, status = sent}),
    %% Sleep for 1 seconds so the timestamp for Attempt1 and Attempt2 is different.
    timer:sleep(timer:seconds(1)),
    {ok, AttemptId2, _} = model_phone:add_sms_code2(?PHONE, ?MBIRD_CODE),
    ok = model_phone:add_gateway_response(?PHONE, AttemptId2,
        #gateway_response{gateway = mbird_verify, gateway_id = ?SID2, status = sent}),
    match = mod_sms:verify_sms(?PHONE, ?CODE),
    ?assert(meck:called(mbird_verify, verify_code_internal, [?PHONE, ?CODE, '_'])),
    % confirm oldest to newest requests
    true = model_phone:get_verification_success(?PHONE, AttemptId1),
    false = model_phone:get_verification_success(?PHONE, AttemptId2),
    % confirm error with default mbird code
    nomatch = mod_sms:verify_sms(?PHONE, ?MBIRD_CODE),
    %% match without going through mbird_verify after prev validation
    match = mod_sms:verify_sms(?PHONE, ?CODE),

    %% Invalidate old codes.
    ok = model_phone:invalidate_old_attempts(?PHONE),
    %% this will now fail after invalidating old codes.
    nomatch = mod_sms:verify_sms(?PHONE, ?CODE),
    {ok, AllVerifyInfo} = model_phone:get_all_verification_info(?PHONE),
    nomatch = mbird_verify:verify_code(?PHONE, ?CODE, AllVerifyInfo),
    meck_finish(mod_sms),
    meck_finish(mbird_verify),
    meck_finish(ejabberd_router).


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_phone).


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod, [passthrough]),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).

