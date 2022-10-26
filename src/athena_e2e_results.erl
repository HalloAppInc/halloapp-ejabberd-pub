%%%-------------------------------------------------------------------------------
%%% File: athena_e2e_results.erl
%%%
%%% copyright (C) 2021, HalloAppInc
%%%
%%% Module with all query result processing functions for e2e athena queries.
%%%-------------------------------------------------------------------------------
-module(athena_e2e_results).
-author('murali').

-include("logger.hrl").
-include("athena_query.hrl").

%% API
-export([
    record_enc_and_dec/1,
    record_dec_report/1
]).

-spec record_enc_and_dec(Query :: athena_query()) -> ok.
record_enc_and_dec(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1, Metric2] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [Version, EncSuccessRateStr, _, DecSuccessRateStr, _] = maps:get(<<"Data">>, ResultRow),
            {EncSuccessRate, <<>>} = string:to_float(EncSuccessRateStr),
            {DecSuccessRate, <<>>} = string:to_float(DecSuccessRateStr),
            case Version =/= <<>> andalso Version =/= "" of
                true ->
                    stat:count("HA/e2e", Metric1, EncSuccessRate,
                        [{"version", util:to_list(Version)} | TagsAndValues]),
                    stat:count("HA/e2e", Metric2, DecSuccessRate,
                        [{"version", util:to_list(Version)} | TagsAndValues]),
                    ok;
                false -> ok
            end
        end, ActualResultRows),
    ok.


-spec record_dec_report(Query :: athena_query()) -> ok.
record_dec_report(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [Platform, Version, DecSuccessRateStr, _, TotalMsgsStr] = maps:get(<<"Data">>, ResultRow),
            {DecSuccessRate, <<>>} = string:to_float(DecSuccessRateStr),
            case Version =/= <<>> andalso Version =/= "" of
                true ->
                    stat:count("HA/e2e", Metric1, DecSuccessRate,
                        [{"version", util:to_list(Version)},
                        {"platform", util:to_list(Platform)} | TagsAndValues]),
                    TotalMsgs = util:to_integer(TotalMsgsStr),
                    stat:count("HA/e2e", Metric1 ++ "_count", TotalMsgs,
                        [{"version", util:to_list(Version)},
                        {"platform", util:to_list(Platform)} | TagsAndValues]),
                    ok;
                false -> ok
            end
        end, ActualResultRows),
    ok.

