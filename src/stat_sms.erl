%%%=============================================================================
%%% File: stat_sms.erl
%%% @author vipin
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% SMS related stats.
%%% @end
%%%=============================================================================

-module(stat_sms).
-author("vipin").

-include("logger.hrl").
-include("ha_types.hrl").
-include("sms.hrl").

%% API
-export([
    check_sms_reg/1,
    check_gw_stats/1,
    get_gwcc_atom_safe/2,
    relevant_gateways/1
]).

-ifdef(TEST).
%% debugging purposes
-include_lib("eunit/include/eunit.hrl").
-export([
    gather_scoring_data/3,
    get_gwcc_atom/2,
    get_recent_score/2,
    sms_stats_table_name/1,
    print_sms_stats/2,
    process_all_scores/1,
    compute_recent_score/2
]).
-endif.

-compile([{nowarn_unused_function, [
    {get_recent_score, 2}
]}]).


%%%=============================================================================
%%% API
%%%=============================================================================

-spec check_sms_reg(TimeWindow :: atom()) -> ok.
check_sms_reg(TimeWindow) ->
    ?INFO("~p Check SMS reg start", [TimeWindow]),
    Start = util:now_ms(),
    ets:new(sms_stats_table_name(TimeWindow), [named_table, ordered_set, public]),
    IncrementalTimestamp = util:now() div ?SMS_REG_TIMESTAMP_INCREMENT,
    %% We split the time into 15 minute increments (decided based on ?SMS_REG_TIMESTAMP_INCREMENT).
    %% From the current time, last to last increment represents SMS attempts that have had enough
    %% time to get verified. We consider them `recent` attempts and the rest `past` attempts in the
    %% last 24 hours.
    %%
    %% T = current time / 15 minute.
    %%
    %% T - 60 mins, T - 45 minutes, T - 30 minutes, T - 15 minutes, T = current increment.
    %% --------- past ----------->  <-- recent ---> <--- last ---> <---- current ----
    case TimeWindow of
        recent ->
            %% Last to Last time slot
            check_sms_reg_internal(TimeWindow, IncrementalTimestamp - 2,
                    IncrementalTimestamp - 3),
            check_gw_stats(false),
            check_gw_stats(true);
        past ->
            %% Last 94 full time slots
            check_sms_reg_internal(TimeWindow, IncrementalTimestamp - 3,
                    IncrementalTimestamp - 97)
    end,
    print_sms_stats(TimeWindow, ets:first(sms_stats_table_name(TimeWindow))),
    ets:delete(sms_stats_table_name(TimeWindow)),
    End = util:now_ms(),
    ?INFO("Check SMS reg took ~p ms", [End - Start]),
    ok.


-spec check_gw_stats(IsNew :: boolean()) -> ok.
check_gw_stats(IsNew) ->
    ?INFO("Check Gateway scores start"),
    Start = util:now_ms(),
    % make a new table for storing scoring stats
    ets:new(?SCORE_DATA_TABLE, [named_table, ordered_set, public]),
    CurrentIncrement = util:now() div ?SMS_REG_TIMESTAMP_INCREMENT,
    IncrementToProcess = CurrentIncrement - 2,
    % using the same 15 minute increments as explained above, start at `recent`
    % increment and iterate backwards in time up to 48 hours (192 increments).
    ?INFO("Processing scores from time slots ~p to ~p", [IncrementToProcess,
            IncrementToProcess - ?MAX_SCORING_INTERVAL_COUNT]),
    gather_scoring_data(IncrementToProcess, IncrementToProcess - ?MAX_SCORING_INTERVAL_COUNT, IsNew),
    % computes and prints all scores from raw counts
    process_all_scores(IsNew),
    ets:delete(?SCORE_DATA_TABLE),
    End = util:now_ms(),
    ?INFO("Check Gateway Scores took ~p ms", [End - Start]),
    ok.


%% Returns the current recent score
-spec get_recent_score(VarName :: atom(), IsNew :: boolean()) -> 
        {ok, integer()} | {error, insufficient_data}.
get_recent_score(VarName, IsNew) ->
    {ok, AggScore} = case IsNew of 
        true -> model_gw_score:get_recent_score(VarName, new); 
        false -> model_gw_score:get_recent_score(VarName) 
    end,
    case AggScore of
        undefined -> {error, insufficient_data};
        _ -> {ok, AggScore}
    end.


-spec get_gwcc_atom_safe(Gateway :: atom(), CC :: binary()) -> GatewayCC :: atom().
get_gwcc_atom_safe(Gateway, CC) ->
    GatewayCC = case get_gwcc_atom(Gateway, CC) of
        {ok, GWCC} -> GWCC;
        {error, undefined} -> 
            ?ERROR("unable to create gwcc atom from ~p and ~p", [Gateway, CC]),
            undefined
    end,
    GatewayCC.

%%%=============================================================================
%%% INTERNAL FUNCTIONS
%%%=============================================================================

-spec check_sms_reg_internal(TimeWindow :: atom(), IncrementalTimestamp :: integer(),
        FinalIncrement :: integer()) -> ok.
check_sms_reg_internal(_TimeWindow, FinalIncrement, FinalIncrement) ->
    ?DEBUG("Stopping"),
    ok;

check_sms_reg_internal(TimeWindow, IncrementalTimestamp, FinalIncrement) ->
    ?INFO("~p Processing time slot: ~p, increment: ~p", [TimeWindow,
            IncrementalTimestamp, FinalIncrement]),
    IncrementalAttemptList = model_phone:get_incremental_attempt_list(IncrementalTimestamp),
    lists:foreach(
        fun({Phone, AttemptId})  ->
            ?DEBUG("Checking Phone: ~p, AttemptId: ~p", [Phone, AttemptId]),
            case util:is_test_number(Phone) orelse util:is_google_number(Phone) of
                true ->
                    ok;
                false ->
                    do_check_sms_reg(TimeWindow, Phone, AttemptId)
            end
        end, IncrementalAttemptList),
    check_sms_reg_internal(TimeWindow, IncrementalTimestamp - 1, FinalIncrement).


-spec gather_scoring_data(CurrentIncrement :: integer(), FinalIncrement :: integer(), IsNew :: boolean()) -> ok.
gather_scoring_data(FinalIncrement, FinalIncrement, _IsNew) ->
    ok;

gather_scoring_data(CurrentIncrement, FinalIncrement, IsNew) ->
    % moving backwards in time, FirstIncrement always >= CurrentIncrement
    LogMsg = "Processing scores in time slot: ~p, until: ~p",
    LogList = [CurrentIncrement, FinalIncrement],
    case CurrentIncrement rem 25 =:= 0 of
        true -> ?INFO(LogMsg, LogList);
        false -> ?DEBUG(LogMsg, LogList)
    end,
    % FinalIncrement + ?MAX_SCORING_INTERVAL_COUNT is the first increment examined (recent)
    % because FinalIncrement = FirstIncrement - MAX_INTERVALS
    NumExaminedIncrements = (FinalIncrement + ?MAX_SCORING_INTERVAL_COUNT) - CurrentIncrement,
    ShouldContinue = process_incremental_scoring_data(CurrentIncrement, NumExaminedIncrements, IsNew),
    case ShouldContinue of
        true -> gather_scoring_data(CurrentIncrement - 1, FinalIncrement, IsNew);
        false -> ok
    end.


-spec process_incremental_scoring_data(CurrentIncrement :: integer(),
        NumExaminedIncrements :: integer(), IsNew :: boolean()) -> boolean().
process_incremental_scoring_data(CurrentIncrement, NumExaminedIncrements, IsNew) ->
    %% TODO(vipin): Need to reduce size of the list returned.
    IncrementalAttemptList = model_phone:get_incremental_attempt_list(CurrentIncrement),
    % TODO(Luke) - Implement a map here to track which metrics have used this increment
    % instead of the global counter
    IncRequired = NumExaminedIncrements < ?MIN_SCORING_INTERVAL_COUNT,
    IncrementMap = #{must_inc => IncRequired},
    lists:foldl(
        fun({Phone, AttemptId}, AccIncMap)  ->
            process_attempt_score(Phone, AttemptId, AccIncMap, IsNew)
        end, IncrementMap, IncrementalAttemptList),
    case IsNew of
        false -> ok;
        true -> 
            % Now before the next interval, determine which gateways are possibly relevant
            % in finding a best gateway, and continue sampling from them.
            % Sampling more for these gateways will make us more confident in their true performance,
            % allowing us to eventually conclude statistical significance.

            % GatewayScores maps locations to a map of scoring data by code for each location.
            GatewayScores = ets:foldl(fun({{Type, Code}, ErrorCount, TotalCount, _, _}, Acc) -> 
                maps:update_with(get_location(Type, Code), 
                    fun(Old) -> 
                        Old#{Code => {(TotalCount - ErrorCount) / TotalCount, TotalCount}} 
                    end, #{Code => {(TotalCount - ErrorCount) / TotalCount, TotalCount}}, Acc)
            end, #{}, ?SCORE_DATA_TABLE),

            % Compare all gateways in each country / globally to find ones which are in the running
            % with the current amount sampled.
            RelevantGatewaysByLocation = maps:map(fun(_K, V) -> relevant_gateways(V) end, GatewayScores),

            % Set relevance flag for all gateways. Relevance = true => we need more data.
            ets:foldl(fun({{Type, Code}, _, _, _, _}, _Acc) -> 
                Location = get_location(Type, Code),
                RelevantGateways = maps:get(Location, RelevantGatewaysByLocation),
                IsNowRelevant = case length(RelevantGateways) of
                    % If there are two or more candidates we want to continue sampling from relevant
                    % gateways until there is only one. Once there is one gateway found to be significantly
                    % better than all others, we stop sampling.
                    Count when Count >= 2 -> lists:member(Code, RelevantGateways);
                    _ -> false
                end,
                ets:update_element(?SCORE_DATA_TABLE, {Type, Code}, {?IS_RELEVANT_POS, IsNowRelevant})
            end, undefined, ?SCORE_DATA_TABLE),
            ok
    end,
    IncRequired or any_key_needs_data().

-spec any_key_needs_data() -> boolean().
any_key_needs_data() -> any_key_needs_data(ets:first(?SCORE_DATA_TABLE)).
any_key_needs_data('$end_of_table') -> false;
any_key_needs_data(Key) -> needs_more_data(Key) orelse any_key_needs_data(ets:next(?SCORE_DATA_TABLE,Key)).


-spec process_attempt_score(Phone :: phone(), AttemptId :: binary(), IncrementMap :: map(), IsNew :: boolean()) -> map().
process_attempt_score(Phone, AttemptId, IncrementMap, IsNew) -> 
    ?DEBUG("Checking Phone: ~p, AttemptId: ~p", [Phone, AttemptId]),
    IncrementMap2 = case util:is_test_number(Phone) orelse util:is_google_number(Phone) of
        true ->
            IncrementMap;
        false ->
            process_scoring_datum(Phone, AttemptId, IncrementMap, IsNew)
    end,
    IncrementMap2.


-spec process_scoring_datum(Phone :: phone(), AttemptId :: binary(), IncrementMap :: map(), IsNew :: boolean()) -> map().
process_scoring_datum(Phone, AttemptId, IncrementMap, IsNew) ->
    CC = mod_libphonenumber:get_cc(Phone),
    SMSResponse = model_phone:get_verification_attempt_summary(Phone, AttemptId),
    #gateway_response{gateway = Gateway, status = _Status, verified = Success} = SMSResponse,
    GatewayCC = case get_gwcc_atom(Gateway, CC) of
        {ok, GWCC} -> GWCC;
        {error, undefined} -> 
            ?ERROR("unable to create gwcc atom from ~p and ~p", [Gateway, CC]),
            undefined
    end,
    % possibly increment global score
    IncrementMap2 = case should_inc(gw, Gateway, IncrementMap) of
        true -> 
            inc_scoring_data(gw, Gateway, Success, IsNew),
            IncrementMap#{Gateway => true};
        false -> IncrementMap
    end,
    % possibly increment country-specific score
    IncrementMap3 = case should_inc(gwcc, GatewayCC, IncrementMap2) of
        true -> 
            inc_scoring_data(gwcc, GatewayCC, Success, IsNew),
            IncrementMap2#{GatewayCC => true};
        false -> IncrementMap2
    end,
    case IsNew of
        false ->
            ets:update_counter(?SCORE_DATA_TABLE, {gw, Gateway}, {?TOTAL_SEEN_POS, 1}, 
                    {{gw, Gateway}, 0, 0, 0}),
            ets:update_counter(?SCORE_DATA_TABLE, {gwcc, GatewayCC}, {?TOTAL_SEEN_POS, 1}, 
                    {{gwcc, GatewayCC}, 0, 0, 0});
        true ->
            ets:update_counter(?SCORE_DATA_TABLE, {gw, Gateway}, {?TOTAL_SEEN_POS, 1}, 
                    {{gw, Gateway}, 0, 0, 0, false}),
            ets:update_counter(?SCORE_DATA_TABLE, {gwcc, GatewayCC}, {?TOTAL_SEEN_POS, 1}, 
                    {{gwcc, GatewayCC}, 0, 0, 0, false})
    end,
    IncrementMap3.


-spec do_check_sms_reg(TimeWindow :: atom(), Phone :: phone(),AttemptId :: binary()) -> ok.
do_check_sms_reg(TimeWindow, Phone, AttemptId) ->
    CC = mod_libphonenumber:get_cc(Phone),
    SMSResponse = model_phone:get_verification_attempt_summary(Phone, AttemptId),
    #gateway_response{gateway = Gateway, status = Status,
            verified = Success} = SMSResponse,
    report_stat(TimeWindow, "otp_attempt", Gateway, CC, Status),
    inc_sms_stats(TimeWindow, gw, Gateway, total),
    inc_sms_stats(TimeWindow, cc, util:to_atom(CC), total),
    GatewayCC = case get_gwcc_atom(Gateway, CC) of
        {ok, GWCC} -> GWCC;
        {error, undefined} -> 
            ?ERROR("unable to create gwcc atom from ~p and ~p", [Gateway, CC]),
            undefined
    end,
    inc_sms_stats(TimeWindow, gwcc, GatewayCC, total),
    case {Gateway, Status, Success} of
        {_, _, _} when Gateway =:= undefined orelse Success =:= false ->
            %% SMS attempt failure
            report_stat(TimeWindow, "otp_attempt_error", Gateway, CC, Status),
            inc_sms_stats(TimeWindow, gw, Gateway, error),
            inc_sms_stats(TimeWindow, cc, util:to_atom(CC), error),
            inc_sms_stats(TimeWindow, gwcc, GatewayCC, error),
            ?INFO("CC: ~p, Phone: ~p AttemptId: ~p failed via Gateway: ~p, Status: ~p",
                    [CC, Phone, AttemptId, Gateway, Status]);
        {_, _, true} ->
            %% SMS attempt success.
            ok
    end.


-spec inc_scoring_data(VariableType :: atom(), VariableName :: atom(), Success :: boolean(), IsNew :: boolean()) -> ok.
inc_scoring_data(VariableType, VariableName, Success, IsNew) ->
    ?DEBUG("Type: ~p Name: ~p Success: ~p", [VariableType, VariableName, Success]),
    DataKey = {VariableType, VariableName},
    case IsNew of
        false -> ets:update_counter(?SCORE_DATA_TABLE, DataKey, {?TOTAL_POS, 1}, {DataKey, 0, 0, 0});
        true -> ets:update_counter(?SCORE_DATA_TABLE, DataKey, {?TOTAL_POS, 1}, {DataKey, 0, 0, 0, false})
    end,
    case Success of
        _ when Success =:= undefined orelse Success =:= false->
            % intentionally not providing a default value here; total and 
            % error counter use the same key, so if it's not supplied by
            % the above update_counter something's gone seriously wrong
            ets:update_counter(?SCORE_DATA_TABLE, DataKey, {?ERROR_POS, 1});
        true -> ok
    end,
    ok.


-spec inc_sms_stats(atom(), atom(), atom(), atom()) -> ok.
inc_sms_stats(TimeWindow, VariableType, Variable, CountType) ->
    TableName = sms_stats_table_name(TimeWindow),
    Key = {VariableType, Variable, CountType},
    ets:update_counter(TableName, Key, 1, {Key, 0}),
    ok.


-spec should_inc(VariableType :: atom(), VariableName :: atom(),
        IncrementMap :: map()) -> boolean().
should_inc(_, _, #{must_inc := true}) -> true;

% checks if the variable needs more data and if the increment has been used yet
should_inc(VariableType, VariableName, IncrementMap) ->
    DataKey = {VariableType, VariableName},
    WantMoreData = needs_more_data(DataKey),

    % HaveInspectedIncrement captures whether or not we've already used some data
    % for this variable (i.e. gateway-cc combo or gw) from the current interval
    % If so, then we will finish logging data from the current interval
    HaveUsedIncrement = case IncrementMap of
        #{VariableName := true} -> true;
        _ -> false
    end,

    % true if we want more data or if we've already used this increment
    WantMoreData orelse HaveUsedIncrement.


%% evaluates if the given variable has more than the minimum required number of 
%% data points (currently 20), or we need more data to decide the winner.
-spec needs_more_data(VariableKey :: tuple()) -> boolean().
needs_more_data(VariableKey) ->
    case ets:lookup(?SCORE_DATA_TABLE, VariableKey) of
        [{_VariableKey, _ErrCount, TotalCount, _TSeen}] 
            when TotalCount < ?MIN_TEXTS_TO_SCORE_GW -> true;
        [{_VariableKey, _ErrCount, TotalCount, _TSeen}] 
            when TotalCount >= ?MIN_TEXTS_TO_SCORE_GW -> false;
        % New behavior occurs here when ?SCORE_DATA_TABLE has 5 values in each row - 
        % this is only when the new version of gather_scoring_data is called
        [{_VariableKey, _ErrCount, TotalCount, _TSeen, _IsRelevant}] 
             when TotalCount < ?MIN_TEXTS_TO_SCORE_GW -> true;
        [{_VariableKey, _ErrCount, TotalCount, _TSeen, IsRelevant}] 
             % even if we've sampled the minimum number of texts, we still want to sample gateways that could be relevant.
             when TotalCount >= ?MIN_TEXTS_TO_SCORE_GW -> IsRelevant;
        [] -> true
    end.


-spec print_sms_stats(TimeWindow :: atom(), Key :: term()) -> ok.
print_sms_stats(_TimeWindow, '$end_of_table') ->
    ok;

print_sms_stats(TimeWindow, Key) ->
    [{Key, Value}] = ets:lookup(sms_stats_table_name(TimeWindow), Key),
    {Var1, Var2, Var3} = Key,
    PrintList = [TimeWindow, Var2, Var3, Value],
    case Var1 of
        cc ->
            ?INFO("~p SMS_Stats, Country: ~p, ~p: ~p", PrintList),
            check_possible_spam(TimeWindow, Var2, Var3, Value);
        gw ->
            ?INFO("~p SMS_Stats, Gateway: ~p, ~p: ~p", PrintList);
        gwcc ->
            ?INFO("~p SMS_Stats, Gateway_Country_Combo: ~p, ~p: ~p", PrintList)
    end,
    print_sms_stats(TimeWindow, ets:next(sms_stats_table_name(TimeWindow), Key)).


%% iterates through all 'total' entries, calculates the corresponding score, and prints
-spec process_all_scores(IsNew :: boolean()) -> ok.
process_all_scores(IsNew) ->
    case IsNew of
        false -> ok;
        true -> ?INFO("stat_sms new version: final statistics")
    end,
    Entries = case IsNew of
        false -> ets:match(?SCORE_DATA_TABLE, {{'$1', '$2'}, '$3', '$4', '$5'});
        true -> ets:match(?SCORE_DATA_TABLE, {{'$1', '$2'}, '$3', '$4', '$5', '$6'})
    end,
    lists:foreach(fun compute_and_print_score/1, Entries).

-spec compute_and_print_score(VarTypeNameTotal :: list()) -> ok.
compute_and_print_score([VarType | [VarName | [ErrCount | [TotalCounted | [TotalSeen | Remainder]]]]]) ->
    %% Pattern match above is used because Remainder could either be [] or the last element of a row from the new version.
    %% This is much nicer than writing this function twice but still TODO: fix.
    SuccessCount = TotalCounted - ErrCount,
    Category = get_category(VarType),
    Score = case compute_recent_score(ErrCount, TotalCounted) of
        {ok, S} when S < ?MIN_SMS_CONVERSION_SCORE ->
            %% TODO: change the INFO to ERROR once spam noise has subsided.
            LogMsg = "Low SMS conversion, ~s: ~p, score: ~p (~p/~p)",
            LogList = [Category, VarName, S, SuccessCount, TotalCounted],
            %% Print as Error once every 4 hours. Assumption is that this method is run every
            %% 15 minutes. Print as Info otherwise.
            CurrentTime = util:now(),
            case ((CurrentTime div ?HOURS) rem 24 =:= 0) andalso
                ((CurrentTime div (15 * ?MINUTES)) rem 4 =:= 0) of
                true -> ?ERROR(LogMsg, LogList);
                false -> ?INFO(LogMsg, LogList)
            end,
            S;
        {ok, S} ->
            S;
        {error, insufficient_data} -> nan
    end,
   
    Relevance = case Remainder of
        [] ->
            update_redis_score(VarName, Score),
            not_new_version;
        [IsRelevant] ->
            update_redis_score(VarName, Score, TotalCounted),
            IsRelevant
    end,
    case Score of 
        nan -> ?DEBUG("SMS_Stats, ~s: ~p, score: ~p (~p/~p) seen: ~p (relevant?: ~p)", 
            [Category, VarName, Score, SuccessCount, TotalCounted, TotalSeen, Relevance]);
        _ -> ?INFO("SMS_Stats, ~s: ~p, score: ~p (~p/~p) seen: ~p (relevant?: ~p)", 
            [Category, VarName, Score, SuccessCount, TotalCounted, TotalSeen, Relevance])
    end,
    ok.


-spec compute_recent_score(ErrCount :: integer(), TotalCount :: integer()) -> 
        {ok, Score :: integer()} | {error, insufficient_data}.
compute_recent_score(ErrCount, TotalCount) ->
    case TotalCount >= ?MIN_TEXTS_TO_SCORE_GW of
        true -> {ok, ((TotalCount - ErrCount) * 100) div TotalCount};
        false -> {error, insufficient_data}
    end.


-spec update_redis_score(VarName :: atom(), RecentScore :: integer()) -> ok.
update_redis_score(VarName, RecentScore)->
    {ok, OldAggScore} = model_gw_score:get_aggregate_score(VarName),
    NewAggScore = case {RecentScore, OldAggScore} of 
        {nan, _} -> OldAggScore;
        {_, undefined} -> RecentScore;
        {_, _} -> combine_scores(RecentScore, OldAggScore)
    end,
    StoreRecentScore = case RecentScore of
        nan -> undefined;
        _ -> RecentScore  
    end,
    model_gw_score:store_score(VarName, StoreRecentScore, NewAggScore),
    ok.

update_redis_score(VarName, RecentScore, RecentCount)->
    {ok, OldAggScore, OldCount} = model_gw_score:get_aggregate_stats(VarName),
    % if we don't have enough samples, keep the old score/count
    % otherwise, replace with the new score and count.
    {NewScore, NewCount} = case RecentScore of 
        nan -> {OldAggScore, OldCount};
        _ -> {RecentScore, RecentCount}
    end,
    RecentScore2 = case RecentScore of
        nan -> undefined;
        _ -> RecentScore
    end,
    %% TODO(vipin): Need to store `RecentCount` also in redis.
    model_gw_score:store_score(VarName, RecentScore2, NewScore, NewCount),
    ok.

-spec combine_scores(RecentScore :: integer(), AggScore :: integer()) -> integer().
combine_scores(RecentScore, AggScore) ->
    NewScore = (RecentScore * ?RECENT_SCORE_WEIGHT) + 
        (AggScore * (1.0 - ?RECENT_SCORE_WEIGHT)),
    trunc(NewScore) div 1.

% retrieves location from either gateway atom or gwcc atom.
 -spec get_location(Type :: atom(), Code :: atom()) -> atom() | binary().
 get_location(Type, Code) ->
     Code_bin = util:to_binary(Code),
     case Type of
         gw -> global;
         gwcc -> binary:part(Code_bin, {byte_size(Code_bin), -2})
     end.


-spec get_category(VarType :: atom()) -> string().
get_category(gw) ->
    "Gateway";
get_category(gwcc) ->
    "Gateway_Country_Combo".


-spec get_gwcc_atom(Gateway :: atom(), CC :: binary()) -> {ok, atom()} | {error, undefined}.
get_gwcc_atom(Gateway, CC) ->
    GatewayBin = util:to_binary(Gateway),
    GatewayCC = util:to_atom(<<GatewayBin/binary, <<"_">>/binary, CC/binary>>),
    case GatewayCC of
        undefined -> {error, undefined};
        _ -> {ok, GatewayCC}
    end.


-spec sms_stats_table_name(atom()) -> atom().
sms_stats_table_name(TimeWindow) ->
    TimeWindowBinary = util:to_binary(TimeWindow),
    %% Possible values of TimeWindow is `recent` and `past`. Number of created atoms is bounded.
    util:to_atom(<<<<"sms_stats">>/binary, TimeWindowBinary/binary>>).


-spec report_stat(atom(), string(), atom(), binary(), status()) -> ok.
report_stat(past, _Metrics, _Gateway, _CC, _Status) ->
    ok;

report_stat(recent, Metrics, Gateway, CC, Status) ->
    stat:count("HA/registration", Metrics, 1,
            [{gateway, Gateway}, {cc, CC}, {status, Status}]).


-spec check_possible_spam(TimeWindow :: atom(), CC :: atom(), CountType :: atom(), 
        TotalCount :: integer()) -> ok.
check_possible_spam(TimeWindow, CC, total, TotalCount) when TotalCount >= ?SPAM_THRESHOLD_PER_INCREMENT ->
    ErrCount = case ets:lookup(sms_stats_table_name(TimeWindow), {cc, CC, error}) of
        [{{cc, CC, error}, Count}] -> Count;
        [] -> 0
    end,
    ?DEBUG("CC: ~p, Total: ~p, Error: ~p", [CC, TotalCount, ErrCount]),
    case ErrCount =:= TotalCount of
        true ->
            ?ERROR("Possible OTP spam, CC: ~p, Invoked: ~p unconverted otp requests in recent 15 mins",
                [CC, TotalCount]),
            ok;
        false -> ok
    end,
    ok;
check_possible_spam(_TimeWindow, _CC, _CountType, _TotalCount) ->
    ok.

-spec relevant_gateways(GatewayScores :: #{atom() => {float(), integer()}}) -> [atom()].
 relevant_gateways(GatewayScores) -> 
     Gateways = maps:keys(GatewayScores),

     % Only choose from gateways that have been scored and have a reasonable score.
     SampledGateways = lists:filter(fun(GW) -> 
         {Score, Count} = maps:get(GW, GatewayScores), 
         Count >= ?MIN_TEXTS_TO_SCORE_GW andalso Score >= (?MIN_SMS_CONVERSION_SCORE / 100)
     end, Gateways),

     % Select all gateways with enough samples that aren't worse than another gateway with enough samples.
     lists:filter(
         fun(GW) ->
             lists:all(fun(Other) ->
                  Other == GW orelse
                  not statscalc:is_statistically_worse(maps:get(GW, GatewayScores), maps:get(Other, GatewayScores))
             end, SampledGateways)
         end,
     SampledGateways).
