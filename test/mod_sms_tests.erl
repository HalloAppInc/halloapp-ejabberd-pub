%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 31. Mar 2020 2:53 PM
%%%-------------------------------------------------------------------
-module(mod_sms_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").
-include("sms.hrl").
-include("time.hrl").
-include("logger.hrl").

-define(PHONE, <<"14703381473">>).
-define(TEST_PHONE, <<"16175550000">>).

-define(PHONE1, <<"12466960841">>). %% BB - Barbados
-define(PHONE2, <<"16504443079">>). %% US
-define(CODE1, <<"478146">>).
-define(GATEWAY1, gw1).
-define(GATEWAY2, gw2).
-define(SMSID1, <<"smsid1">>).
-define(SMSID2, <<"smsid2">>).
-define(SMSID3, <<"smsid3">>).
-define(RECEIPT, <<"{\"name\": \"value\"}">>).
-define(STATUS, sent).


simple_test() ->
    ?assert(true).

get_app_hash_test() ->
    ?assertEqual(?ANDROID_DEBUG_HASH, util_ua:get_app_hash("HalloApp/Android1.0.0D")),
    ?assertEqual(?ANDROID_RELEASE_HASH, util_ua:get_app_hash("HalloApp/Android1.0.0")),
    ?assertEqual(<<"">>, util_ua:get_app_hash("HalloApp/iOS1.2.93")),
    ?assertEqual(<<"">>, util_ua:get_app_hash("HalloApp/random")),
    ok.

generate_code_test() ->
    CodeBin = mod_sms:generate_code(?PHONE),
    Code = binary_to_integer(CodeBin),
    ?assert(Code >= 0),
    ?assert(Code =< 999999),
    ?assertEqual(<<"111111">>, mod_sms:generate_code(?TEST_PHONE)),
    ok.


is_too_soon_test() ->
    Now = util:now(),
    
    {false, _} = mod_sms:is_too_soon([]),
    OldResponses = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 10), status = sent}],
    %% Need 30 seconds gap.
    {true, _} = mod_sms:is_too_soon(OldResponses),
    OldResponses1 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 30 * ?SECONDS)}],
    {false, _} = mod_sms:is_too_soon(OldResponses1),
    
    OldResponses2 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 50 * ?SECONDS), status = sent},
                    #gateway_response{method = sms, attempt_ts = util:to_binary(Now - 21 * ?SECONDS), status = sent}],
    %% Need 60 seconds gap.
    {true, _} = mod_sms:is_too_soon(OldResponses2),
    OldResponses3 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 120 * ?SECONDS)},
                    #gateway_response{method = sms, attempt_ts = util:to_binary(Now - 60 * ?SECONDS)}],
    {false, _} = mod_sms:is_too_soon(OldResponses3).


setup_sms() ->
    tutil:setup(),
    ha_redis:start(),
    phone_number_util:init(undefined, undefined),
    clear_sms(),
    ok.

clear_sms() ->
    tutil:cleardb(redis_phone).

sms_stats_threshold_test() ->
    setup_sms(),
    CC1 = mod_libphonenumber:get_cc(?PHONE1),
    CC2 = mod_libphonenumber:get_cc(?PHONE2),
    % ?debugFmt("CC1: ~p, CC2: ~p", [CC1, CC2]),
    {ok, G1CC1} = stat_sms:get_gwcc_atom(?GATEWAY1, CC1), %% BB
    {ok, G1CC2} = stat_sms:get_gwcc_atom(?GATEWAY1, CC2),
    {ok, G2CC1} = stat_sms:get_gwcc_atom(?GATEWAY2, CC1),
    % ?debugFmt("G1CC1: ~p, G1CC2: ~p, G2CC1: ~p", [G1CC1, G1CC2, G2CC1]),
    
    % these shouldn't be counted; g1p1 gets enough data later on
    G1P2Extra = ?MIN_TEXTS_TO_SCORE_GW + 1,
    G1P2ExtraSuccesses = ?MIN_TEXTS_TO_SCORE_GW,
    AttemptIdListExtra12 = make_attempts(?PHONE2, ?GATEWAY1, ?SMSID2, G1P2Extra),
    0 = verify_attempts(G1P2ExtraSuccesses, ?PHONE2, AttemptIdListExtra12),
    timer:sleep(timer:seconds(?MIN_SCORING_TIME)),

    %% GW1-PHONE1 should use global score (< Threshold data points)
    G1P1Total = ?MIN_TEXTS_TO_SCORE_GW - 1,
    G1P1Successes = ?MIN_TEXTS_TO_SCORE_GW div 2,
    AttemptIdList11 = make_attempts(?PHONE1, ?GATEWAY1, ?SMSID1, G1P1Total),
    0 = verify_attempts(G1P1Successes, ?PHONE1, AttemptIdList11),
    
    %% GW1-PHONE2 should use specific score (> Threshold data points)
    G1P2Total = ?MIN_TEXTS_TO_SCORE_GW + 1,
    G1P2Successes = ?MIN_TEXTS_TO_SCORE_GW,
    AttemptIdList12 = make_attempts(?PHONE2, ?GATEWAY1, ?SMSID2, G1P2Total),
    0 = verify_attempts(G1P2Successes, ?PHONE2, AttemptIdList12),

    %% GW2-PHONE1 should be unable to use any score 
    %% (< Threshold GW2 data points globally)
    G2P1Total = ?MIN_TEXTS_TO_SCORE_GW - 1,
    G2P1Successes = ?MIN_TEXTS_TO_SCORE_GW div 2,
    AttemptIdList21 = make_attempts(?PHONE1, ?GATEWAY2, ?SMSID3, G2P1Total),
    0 = verify_attempts(G2P1Successes, ?PHONE1, AttemptIdList21),

    TableName = ?GW_SCORE_TABLE,
    CurrentIncrement = (util:now() div ?SMS_REG_TIMESTAMP_INCREMENT),
    ets:new(TableName, [named_table, ordered_set, public]),
    stat_sms:gather_scoring_data(CurrentIncrement, CurrentIncrement - ?MAX_SCORING_INTERVAL_COUNT),
    stat_sms:process_all_scores(),
    G1GlobalScore = ((G1P1Successes + G1P2Successes) * 100) div (G1P1Total + G1P2Total),
    G1P2Score = (G1P2Successes * 100) div G1P2Total,
    
    %% Validate Scores for each specific/global Country-Gateway Combo
    ?assertEqual({error, insufficient_data}, get_score(gwcc, G1CC1)),
    ?assertEqual({ok, G1GlobalScore}, get_score(gw, ?GATEWAY1)),

    ?assertEqual({ok, G1P2Score}, get_score(gwcc, G1CC2)),
    ?assertEqual({ok, G1GlobalScore}, get_score(gw, ?GATEWAY1)),

    ?assertEqual({error, insufficient_data}, get_score(gwcc, G2CC1)),
    ?assertEqual({error, insufficient_data}, get_score(gw, ?GATEWAY2)),
    ets:delete(TableName),
    ok.


%% returns number it ~didn't~ succeed.
verify_attempts(0, _Phone, _AttemptIdList) -> 0;
verify_attempts(NumToSucceed, _Phone, []) -> NumToSucceed;
verify_attempts(NumToSucceed, Phone, AttemptIdList) ->
    [AttemptId | OtherAttempts] = AttemptIdList,
    ok = model_phone:add_verification_success(Phone, AttemptId),
    verify_attempts(NumToSucceed-1, Phone, OtherAttempts).


make_attempts(Phone, Gateway, SmsId, NumAttempts) -> 
    make_attempts(Phone, Gateway, SmsId, NumAttempts, []).
make_attempts(_Phone, _Gateway, _SmsId, 0, Acc) -> Acc;
make_attempts(Phone, Gateway, SmsId, NumAttempts, Acc) ->
    {ok, AttemptId, _} = model_phone:add_sms_code2(Phone, ?CODE1),
    ok = model_phone:add_gateway_response(Phone, AttemptId,
        #gateway_response{gateway=Gateway, gateway_id=SmsId, status=?STATUS, response=?RECEIPT}),
    make_attempts(Phone, Gateway, SmsId, NumAttempts-1, [AttemptId |Acc]).


%% calculates requested score and enforces minimum data requirement
-spec get_score(TotalKey :: tuple(), ErrKey :: tuple()) -> {ok, Score :: integer()} | 
        {error, insufficient_data}.
get_score(VarType, VarName) ->
    TotalKey = {VarType, VarName, total},
    ErrKey = {VarType, VarName, error},
    TotalCount = case ets:lookup(?GW_SCORE_TABLE, TotalKey) of
        [{TotalKey, TCount}] -> TCount;
        [] -> 0
    end,
    ErrCount = case ets:lookup(?GW_SCORE_TABLE, ErrKey) of
        [{ErrKey, ECount}] -> ECount;
        [] -> 0
    end,
    case TotalCount >= ?MIN_TEXTS_TO_SCORE_GW of
        true -> {ok, ((TotalCount - ErrCount) * 100) div TotalCount};
        false -> {error, insufficient_data}
    end.


    % twilio_test() ->
%     State = mod_sms:make_state(),
%     Body = mod_sms:compose_twilio_body(<<"123">>, "test"),
%     ?assertEqual("To=%2B123&From=%2B" ++ string:slice(?FROM_PHONE, 1) ++ "&Body=test", Body),
%     ?assertNotEqual("", mod_sms:get_twilio_account_sid(State)),
%     ?assertNotEqual("", mod_sms:get_twilio_auth_token(State)),
% %%    ?debugVal(Body),
%     ok.


choose_other_gateway_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(twilio, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(twilio_verify, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(mbird, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    {error, _, sms_fail} = mod_sms:smart_send(?PHONE, ?PHONE, <<>>, <<>>, sms, []),
    % check if all gateways were attempted
    ?assert(meck:called(twilio, send_sms, ['_','_','_','_'])),
    ?assert(meck:called(twilio_verify, send_sms, ['_','_','_','_'])),
    ?assert(meck:called(mbird, send_sms, ['_','_','_','_'])),
    meck_finish(mbird),
    meck_finish(twilio),
    meck_finish(twilio_verify),
    % check eventual success if starting at a failed gateway, but other works
    TwilGtwy = #gateway_response{gateway = twilio, method = sms},
    MbirdGtwy = #gateway_response{gateway = mbird, method = sms},
    TVerifyGtwy = #gateway_response{gateway = twilio_verify, method = sms},
    meck_init(mbird, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(twilio, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(twilio_verify, send_sms, fun(_,_,_,_) -> {ok, TVerifyGtwy} end),
    {ok, #gateway_response{gateway = twilio_verify}} =
        mod_sms:smart_send(?PHONE, ?PHONE, <<>>, <<>>, sms, [TwilGtwy, TVerifyGtwy, MbirdGtwy]),
    ?assert(meck:called(twilio, send_sms, ['_','_','_','_']) orelse
            meck:called(mbird, send_sms, ['_','_','_','_']) orelse
            meck:called(twilio_verify, send_sms, ['_','_','_','_'])),
    % Test restricted country gateways
    meck_init(mod_libphonenumber, get_cc, fun(_) -> <<"CN">> end),
    {ok, #gateway_response{gateway = twilio_verify}} =
        mod_sms:smart_send(?PHONE, ?PHONE, <<>>, <<>>, sms, []),
    meck_finish(mod_libphonenumber),
    meck_finish(twilio),
    meck_finish(twilio_verify),
    meck_finish(mbird),
    meck_finish(ejabberd_router).


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_whisper),
    ok.


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod, [passthrough]),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).

