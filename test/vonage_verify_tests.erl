%%%-------------------------------------------------------------------
%%% File: vonage_verify_test.erl
%%% copyright (C) 2022, halloapp, inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(vonage_verify_tests).
-author(thomas).

-include_lib("eunit/include/eunit.hrl").
-include("ha_types.hrl").
-include("sms.hrl").


-define(PHONE, <<"14703381473">>).
-define(VONAGE_CODE, <<"999999">>).
-define(CODE, <<"041200">>).
-define(SID1, <<"deadbeefdeadbeef">>).
-define(SID2, <<"defacedadecade">>).


verify_test() ->
    % should have identical behavior to mbird_verify. (in fact this test is the exact same)
    setup(),
    tutil:meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    tutil:meck_init(vonage_verify, verify_code_internal,
        fun(_,Code,Sid) ->
            %?debugFmt("Verify attempt ~p\n",[Code]),
            Status = case Code =:= ?CODE of
                true -> accepted;
                false -> delivered
            end,
            GatewayResponse = #gateway_response{gateway_id = Sid, gateway = vonage_verify, status = Status},
            model_phone:add_gateway_callback_info(GatewayResponse),
            Status =:= accepted
        end),
    {ok, AttemptId1, _} = model_phone:add_sms_code2(?PHONE, ?VONAGE_CODE),
    ok = model_phone:add_gateway_response(?PHONE, AttemptId1,
        #gateway_response{gateway = vonage_verify, gateway_id = ?SID1, status = sent}),
    %% Sleep for 1 seconds so the timestamp for Attempt1 and Attempt2 is different.
    timer:sleep(timer:seconds(1)),
    {ok, AttemptId2, _} = model_phone:add_sms_code2(?PHONE, ?VONAGE_CODE),
    ok = model_phone:add_gateway_response(?PHONE, AttemptId2,
        #gateway_response{gateway = vonage_verify, gateway_id = ?SID2, status = sent}),
    match = mod_sms:verify_sms(?PHONE, ?CODE),
    ?assert(meck:called(vonage_verify, verify_code_internal, [?PHONE, ?CODE, '_'])),
    % confirm oldest to newest requests
    true = model_phone:get_verification_success(?PHONE, AttemptId1),
    false = model_phone:get_verification_success(?PHONE, AttemptId2),
    % confirm error with default vonage code
    nomatch = mod_sms:verify_sms(?PHONE, ?VONAGE_CODE),
    %% match without going through vonage_verify after prev validation
    match = mod_sms:verify_sms(?PHONE, ?CODE),

    %% Invalidate old codes.
    ok = model_phone:invalidate_old_attempts(?PHONE),
    %% this will now fail after invalidating old codes.
    nomatch = mod_sms:verify_sms(?PHONE, ?CODE),
    {ok, AllVerifyInfo} = model_phone:get_all_verification_info(?PHONE),
    nomatch = mbird_verify:verify_code(?PHONE, ?CODE, AllVerifyInfo),
    tutil:meck_finish(ejabberd_router),
    tutil:meck_finish(vonage_verify).


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

