%%%-------------------------------------------------------------------
%%% File: mod_athena_stats.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module to query stats on athena periodically.
%%% We only log them as of now.
%%%
%%%-------------------------------------------------------------------
-module(mod_athena_stats).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("time.hrl").
-include("proc.hrl").

%% TODO: rename db?
-define(IOS, <<"ios">>).
-define(ANDROID, <<"android">>).
-define(ATHENA_DB, <<"default">>).
-define(ATHENA_RESULT_S3_BUCKET, <<"s3://ha-athena-results">>).

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1, depends/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

-export([
    query_encryption_stats/0,
    query_execution_results/2
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?PROC()),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Host) ->
    ?INFO("Start: ~p", [?MODULE]),
    init_erlcloud(),
    {ok, #{}}.

terminate(_Reason, #{} = _State) ->
    ?INFO("Terminate: ~p", [?MODULE]),
    ok.

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_cast(query_encryption_stats, State) ->
    {noreply, query_encryption_stats(State)};
handle_cast({query_execution_results, Queries, Tokens}, State) ->
    {noreply, query_execution_results(Queries, Tokens, State)};
handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% api
%%====================================================================

-spec query_encryption_stats() -> ok.
query_encryption_stats() ->
    gen_server:cast(?PROC(), query_encryption_stats),
    ok.

-spec query_execution_results(Queries :: [binary()], ExecIds :: [binary()]) -> ok.
query_execution_results(Queries, ExecIds) ->
    gen_server:cast(?PROC(), {query_execution_results, Queries, ExecIds}),
    ok.


%%====================================================================
%% internal functions
%%====================================================================

init_erlcloud() ->
    {ok, _} = application:ensure_all_started(erlcloud),
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),
    ok.


query_encryption_stats(State) ->
    try
        QueryTimeMs = util:now_ms() - ?WEEKS_MS,
        QueryTimeMsBin = util:to_binary(QueryTimeMs),
        %% TODO(murali@): cleanup this function to be more simpler
        %% Get all exported functions from athena_queries and run them all with both ios and android.

        %% Android success rates
        Query1 = athena_queries:e2e_success_failure_rates_query(?ANDROID, QueryTimeMsBin),
        Token1 = util:new_uuid(),
        {ok, ExecId1} = erlcloud_athena:start_query_execution(Token1, ?ATHENA_DB, Query1, ?ATHENA_RESULT_S3_BUCKET),

        %% iOS success rates
        Query2 = athena_queries:e2e_success_failure_rates_query(?IOS, QueryTimeMsBin),
        Token2 = util:new_uuid(),
        {ok, ExecId2} = erlcloud_athena:start_query_execution(Token2, ?ATHENA_DB, Query2, ?ATHENA_RESULT_S3_BUCKET),

        %% Android decryption reason rates
        Query3 = athena_queries:e2e_decryption_reason_rates_query(?ANDROID, QueryTimeMsBin),
        Token3 = util:new_uuid(),
        {ok, ExecId3} = erlcloud_athena:start_query_execution(Token3, ?ATHENA_DB, Query3, ?ATHENA_RESULT_S3_BUCKET),

        %% iOS decryption reason rates
        Query4 = athena_queries:e2e_decryption_reason_rates_query(?IOS, QueryTimeMsBin),
        Token4 = util:new_uuid(),
        {ok, ExecId4} = erlcloud_athena:start_query_execution(Token4, ?ATHENA_DB, Query4, ?ATHENA_RESULT_S3_BUCKET),

        %% Android e2e decryption report metrics
        Query5 = athena_queries:e2e_decryption_report_query(?ANDROID, QueryTimeMsBin),
        Token5 = util:new_uuid(),
        {ok, ExecId5} = erlcloud_athena:start_query_execution(Token5, ?ATHENA_DB, Query5, ?ATHENA_RESULT_S3_BUCKET),

        %% iOS e2e decryption report metrics
        Query6 = athena_queries:e2e_decryption_report_query(?IOS, QueryTimeMsBin),
        Token6 = util:new_uuid(),
        {ok, ExecId6} = erlcloud_athena:start_query_execution(Token6, ?ATHENA_DB, Query6, ?ATHENA_RESULT_S3_BUCKET),

        %% Android e2e decryption report metrics with zero rerequest count
        Query7 = athena_queries:e2e_decryption_report_without_rerequest_query(?ANDROID, QueryTimeMsBin),
        Token7 = util:new_uuid(),
        {ok, ExecId7} = erlcloud_athena:start_query_execution(Token7, ?ATHENA_DB, Query7, ?ATHENA_RESULT_S3_BUCKET),

        %% iOS e2e decryption report metrics with zero rerequest count
        Query8 = athena_queries:e2e_decryption_report_without_rerequest_query(?IOS, QueryTimeMsBin),
        Token8 = util:new_uuid(),
        {ok, ExecId8} = erlcloud_athena:start_query_execution(Token8, ?ATHENA_DB, Query8, ?ATHENA_RESULT_S3_BUCKET),

        Queries = [Query1, Query2, Query3, Query4, Query5, Query6, Query7, Query8],
        ExecIds = [ExecId1, ExecId2, ExecId3, ExecId4, ExecId5, ExecId6, ExecId7, ExecId8],

        %% Ideally, we need to periodically list execution results and search for execids.
        %% For now, fetch results after 10 minutes - since our queries are simple.
        {ok, _ResultTref} = timer:apply_after(10 * ?MINUTES_MS, ?MODULE,
                query_execution_results, [Queries, ExecIds]),

        State
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("Error in query_encryption_stats: ~p Stacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            State
    end.


query_execution_results(Queries, ExecIds, State) ->
    try
        Results = lists:map(fun erlcloud_athena:get_query_results/1, ExecIds),
        lists:foreach(
            fun({Query, {ok, Result}}) ->
                ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
                ?INFO("query: ~p", [Query]),
                pretty_print_result(ResultRows)
                %% TODO(murali@): send this to opentsdb.
            end, lists:zip(Queries, Results)),
        State
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("Error in query_execution_results: ~p Stacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            State
    end.


pretty_print_result(Result) ->
    ?INFO("==========================================================="),
    pretty_print_internal(Result),
    ?INFO("==========================================================="),
    ok.


pretty_print_internal([#{<<"Data">> := RowValues} | Rest]) ->
    case RowValues of
        [] -> ok;
        _ ->
            FormatStr = lists:foldl(fun(_, Acc) -> Acc ++ " ~s |" end, "|", RowValues),
            ?INFO(FormatStr, RowValues)
    end,
    pretty_print_internal(Rest);
pretty_print_internal([]) ->
    ok.

