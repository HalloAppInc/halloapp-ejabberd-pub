%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% SMS related stats.
%%% @end
%%%-------------------------------------------------------------------
-module(stat_sms).
-author("vipin").

-include("logger.hrl").
-include("sms.hrl").


%% API
-export([
    check_sms_reg/1
]).


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
        recent -> check_sms_reg2(TimeWindow, IncrementalTimestamp - 2, 1);    %% Last to Last time slot
        past -> check_sms_reg2(TimeWindow, IncrementalTimestamp - 96, 94)     %% Last 94 full time slots
    end,
    print_sms_stats(TimeWindow, ets:first(sms_stats_table_name(TimeWindow))),
    ets:delete(sms_stats_table_name(TimeWindow)),
    End = util:now_ms(),
    ?INFO("Check SMS reg took ~p ms", [End - Start]),
    ok.

sms_stats_table_name(TimeWindow) ->
    TW = util:to_binary(TimeWindow),
    util:to_atom(<<<<"sms_stats">>/binary, TW/binary>>).

print_sms_stats(TimeWindow, '$end_of_table') ->
    ok;
print_sms_stats(TimeWindow, Key) ->
    [{Key, Value}] = ets:lookup(sms_stats_table_name(TimeWindow), Key),
    {Var1, Var2, Var3} = Key,
    PrintList = [TimeWindow, Var2, Var3, Value],
    case Var1 of
        cc -> ?INFO("~p SMS Stats, Country: ~p, ~p: ~p", PrintList);
        gw -> ?INFO("~p SMS Stats, Gateway: ~p, ~p: ~p", PrintList);
        gwcc -> ?INFO("~p SMS Stats, Gateway Country Combo: ~p, ~p: ~p", PrintList)
    end,
    print_sms_stats(TimeWindow, ets:next(sms_stats_table_name(TimeWindow), Key)).
 
-spec check_sms_reg2(TimeWindow :: atom(), IncrementalTimestamp :: integer(), Increment :: integer()) -> ok.
check_sms_reg2(_TimeWindow, _IncrementalTimestamp, 0) ->
    ?DEBUG("Stopping"),
    ok;
check_sms_reg2(TimeWindow, IncrementalTimestamp, Increment) ->
    ?INFO("~p Processing increment: ~p", [TimeWindow, Increment]),
    ToInspect = IncrementalTimestamp - Increment,
    %% TODO(vipin): Need to reduce size of the list returned.
    List = model_phone:get_incremental_attempt_list(ToInspect),
    lists:foreach(fun({Phone, AttemptId}) ->
        ?INFO("Checking Phone: ~p, AttemptId: ~p", [Phone, AttemptId]),
        case util:is_test_number(Phone) of
            false ->
                SMSResponse = model_phone:get_verification_attempt_summary(Phone, AttemptId),
                CC = mod_libphonenumber:get_cc(Phone),
                #gateway_response{gateway = Gateway, status = Status, verified = Success} = SMSResponse, 
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
                end;
            true ->
                ok
        end
        end,
        List),
    check_sms_reg2(TimeWindow, IncrementalTimestamp, Increment - 1).

report_stat(TimeWindow, Metrics, Gateway, CC, Status) ->
    case TimeWindow of
        recent ->
            stat:count("HA/registration", Metrics, 1, [{gateway, Gateway}, {cc, CC}, {status, Status}]);
        _ -> ok
    end.


-spec inc_sms_stats(TimeWindow :: atom(), VariableType :: atom(), Variable :: atom(), CountType :: atom()) -> ok.
inc_sms_stats(TimeWindow, VariableType, Variable, CountType) ->
    Key = {VariableType, Variable, CountType},
    ets:update_counter(sms_stats_table_name(TimeWindow), Key, 1, {Key, 0}).


