%%%-------------------------------------------------------------------
%%% File: athena_push.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module with all athena push queries.
%%%
%%%-------------------------------------------------------------------
-module(athena_push).
-behavior(athena_query).
-author('murali').

-include("time.hrl").
-include("athena_query.hrl").

%% All query functions must end with query.
-export([
    %% callback for behavior function.
    get_queries/0,

    %% query functions for debug!
    push_success_rates/3,

    %% result processing functions.
    record_dec/1
]).

%%====================================================================
%% mod_athena_stats callback
%%====================================================================

get_queries() ->
    QueryTimeMs = util:now_ms() - ?WEEKS_MS,
    QueryTimeMsBin = util:to_binary(QueryTimeMs),
    [
        push_success_rates(?ANDROID, QueryTimeMsBin, <<"HalloApp/Android0.130">>),
        push_success_rates(?IOS, QueryTimeMsBin, <<"HalloApp/iOS1.3.96">>)
    ].


%%====================================================================
%% encryption queries
%%====================================================================

%% Query gets the push success rates by push_type
%% TODO(murali@): these queries by version might also be useful.
-spec push_success_rates(Platform :: binary(),
        TimestampMsBin :: binary(), ClientVersion :: binary()) -> athena_query().
push_success_rates(Platform, TimestampMsBin, ClientVersion) ->
    QueryBin = <<"
        SELECT \"server_push_sent\".\"push_type\" as push_type,
            ROUND(COUNT(\"client_push_received\".\"push_received\".\"id\") * 100.0 / COUNT(*), 2) as success_rate,
            COUNT(\"client_push_received\".\"push_received\".\"id\") as success_count, COUNT(*) as total_count
        FROM \"default\".\"server_push_sent\"
        LEFT JOIN \"default\".\"client_push_received\"
        ON \"default\".\"server_push_sent\".\"push_id\"=\"default\".\"client_push_received\".\"push_received\".\"id\"
        WHERE \"server_push_sent\".\"timestamp_ms\">='", TimestampMsBin/binary, "'
            AND \"server_push_sent\".\"platform\"='", Platform/binary, "'
            AND \"server_push_sent\".\"client_version\">'", ClientVersion/binary, "'
        GROUP BY \"server_push_sent\".\"push_type\" ">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => util:to_list(Platform)},
        result_fun = {?MODULE, record_dec},
        metrics = ["push_success_rate"]
    }.


%% TODO(murali@): unify result code in athena_queries
-spec record_dec(Query :: athena_query()) -> ok.
record_dec(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [PushType, DecSuccessRateStr, _, _] = maps:get(<<"Data">>, ResultRow),
            {DecSuccessRate, <<>>} = string:to_float(DecSuccessRateStr),
            stat:count("HA/push", Metric1, DecSuccessRate,
                    [{"push_type", util:to_list(PushType)} | TagsAndValues])
        end, ActualResultRows),
    ok.

