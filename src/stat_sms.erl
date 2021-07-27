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
    check_sms_reg/1
]).

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
                    IncrementalTimestamp - 1);
        past ->
            %% Last 94 full time slots
            check_sms_reg_internal(TimeWindow, IncrementalTimestamp - 96,
                    IncrementalTimestamp - 2)
    end,
    print_sms_stats(TimeWindow, ets:first(sms_stats_table_name(TimeWindow))),
    ets:delete(sms_stats_table_name(TimeWindow)),
    End = util:now_ms(),
    ?INFO("Check SMS reg took ~p ms", [End - Start]),
    ok.

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
    %% TODO(vipin): Need to reduce size of the list returned.
    IncrementalAttemptList = model_phone:get_incremental_attempt_list(IncrementalTimestamp),
    lists:foreach(
        fun({Phone, AttemptId})  ->
            ?DEBUG("Checking Phone: ~p, AttemptId: ~p", [Phone, AttemptId]),
            case util:is_test_number(Phone) of
                true ->
                    ok;
                false ->
                    do_check_sms_reg(TimeWindow, Phone, AttemptId)
            end
        end, IncrementalAttemptList),
    check_sms_reg_internal(TimeWindow, IncrementalTimestamp + 1, FinalIncrement).


-spec do_check_sms_reg(TimeWindow :: atom(), Phone :: phone(),
        AttemptId :: binary()) -> ok.
do_check_sms_reg(TimeWindow, Phone, AttemptId) ->
    CC = mod_libphonenumber:get_cc(Phone),
    SMSResponse = model_phone:get_verification_attempt_summary(Phone, AttemptId),
    #gateway_response{gateway = Gateway, status = Status,
            verified = Success} = SMSResponse, 
    report_stat(TimeWindow, "otp_attempt", Gateway, CC, Status),
    inc_sms_stats(TimeWindow, gw, Gateway, total),
    inc_sms_stats(TimeWindow, cc, util:to_atom(CC), total),
    GatewayBin = util:to_binary(Gateway),
    GatewayCC = util:to_atom(<<GatewayBin/binary, <<"-">>/binary, CC/binary>>),
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


-spec print_sms_stats(TimeWindow :: atom(), Key :: term()) -> ok.
print_sms_stats(_TimeWindow, '$end_of_table') ->
    ok;

print_sms_stats(TimeWindow, Key) ->
    [{Key, Value}] = ets:lookup(sms_stats_table_name(TimeWindow), Key),
    {Var1, Var2, Var3} = Key,
    PrintList = [TimeWindow, Var2, Var3, Value],
    case Var1 of
        cc ->
            ?INFO("~p SMS Stats, Country: ~p, ~p: ~p", PrintList);
        gw ->
            ?INFO("~p SMS Stats, Gateway: ~p, ~p: ~p", PrintList);
        gwcc ->
            ?INFO("~p SMS Stats, Gateway Country Combo: ~p, ~p: ~p", PrintList)
    end,
    print_sms_stats(TimeWindow, ets:next(sms_stats_table_name(TimeWindow), Key)).
 

-spec sms_stats_table_name(atom()) -> atom().
sms_stats_table_name(TimeWindow) ->
    TimeWindowBinary = util:to_binary(TimeWindow),
    util:to_atom(<<<<"sms_stats">>/binary, TimeWindowBinary/binary>>).


-spec report_stat(atom(), string(), atom(), binary(), status()) -> ok.
report_stat(past, _Metrics, _Gateway, _CC, _Status) ->
    ok;

report_stat(recent, Metrics, Gateway, CC, Status) ->
    stat:count("HA/registration", Metrics, 1,
            [{gateway, Gateway}, {cc, CC}, {status, Status}]).


-spec inc_sms_stats(atom(), atom(), atom(), atom()) -> ok.
inc_sms_stats(TimeWindow, VariableType, Variable, CountType) ->
    Key = {VariableType, Variable, CountType},
    ets:update_counter(sms_stats_table_name(TimeWindow), Key, 1, {Key, 0}).

