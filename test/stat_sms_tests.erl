%%%-------------------------------------------------------------------
%%% @author luke
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 18. Aug 2021 4:32 PM
%%%-------------------------------------------------------------------
-module(stat_sms_tests).
-author("luke").

-include_lib("eunit/include/eunit.hrl").
-include("sms.hrl").
-include("time.hrl").
-include("logger.hrl").

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


testing_test() ->
    ?assert(true).


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

    TableName = ?SCORE_DATA_TABLE,
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


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
setup_sms() ->
    tutil:setup(),
    ha_redis:start(),
    phone_number_util:init(undefined, undefined),
    clear_sms(),
    ok.


clear_sms() ->
    tutil:cleardb(redis_phone).


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
    DataKey = {VarType, VarName},
    {ErrCount, TotalCount} = case ets:lookup(?SCORE_DATA_TABLE, DataKey) of
        [{DataKey, ECount, TCount}] -> {ECount, TCount};
        [] -> {0, 0}
    end,
    stat_sms:compute_score(ErrCount, TotalCount).

