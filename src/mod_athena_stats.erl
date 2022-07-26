%%%-------------------------------------------------------------------
%%% File: mod_athena_stats.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module to query stats on athena periodically.
%%%
%%%-------------------------------------------------------------------
-module(mod_athena_stats).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("time.hrl").
-include("proc.hrl").
-include("athena_query.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1, depends/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

-export([
    run_query/1,
    run_athena_queries/0,
    force_run_athena_queries/0, %% DEBUG-only
    check_queries/0,
    fetch_query_results/1,
    delete_query/1
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
    {ok, Tref} = timer:apply_interval(10 * ?SECONDS_MS, ?MODULE,
        check_queries, []),

    {ok, #{check_queries_tref => Tref, queries => #{}}}.

terminate(_Reason, #{check_queries_tref := Tref} = _State) ->
    ?INFO("Terminate: ~p", [?MODULE]),
    {ok, _} = timer:cancel(Tref),
    ok.

handle_call(check_queries, _From, State) ->
    {Result, State2} = check_queries_internal(State),
    {reply, Result, State2};
handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast({run_query, Query}, State) ->
    State2 = run_query_internal(Query, State),
    {noreply, State2};
handle_cast(run_athena_queries, State) ->
    Queries = get_athena_queries(),
    State2 = run_queries_internal(Queries, State),
    {noreply, State2};
handle_cast({fetch_query_results, ExecutionId}, State) ->
    {noreply, fetch_query_results_internal(ExecutionId, State)};
handle_cast({delete_query, Id}, #{queries := Queries} = State) ->
    State2 = State#{queries => maps:remove(Id, Queries)},
    {noreply, State2};
handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% api
%%====================================================================

-spec run_athena_queries() -> ok.
run_athena_queries() ->
    case calendar:local_time_to_universal_time(calendar:local_time()) of
        {_Date, {Hr, _Min, _Sec}} when Hr >= 12 andalso Hr =< 22 -> %% 5AM - 3PM PDT
            case model_whisper_keys:mark_e2e_stats_query() of
                true ->
                    gen_server:cast(?PROC(), run_athena_queries);
                false ->
                    ok
            end;
        _ -> ok
    end,
    ok.

run_query(Query) ->
    gen_server:cast(?PROC(), {run_query, Query}).


-spec force_run_athena_queries() -> ok.
force_run_athena_queries() ->
    gen_server:cast(?PROC(), run_athena_queries),
    ok.

-spec check_queries() -> ok.
check_queries() ->
    gen_server:call(?PROC(), check_queries).


-spec fetch_query_results(ExecutionId :: binary()) -> ok.
fetch_query_results(ExecutionId) ->
    ?INFO("~p", [ExecutionId]),
    gen_server:cast(?PROC(), {fetch_query_results, ExecutionId}),
    ok.

-spec delete_query(ExecutionId :: binary()) -> ok.
delete_query(ExecutionId) ->
    gen_server:cast(?PROC(), {delete_query, ExecutionId}).


%%====================================================================
%% internal functions
%%====================================================================

init_erlcloud() ->
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),
    ok.

-spec run_query_internal(Query :: athena_query(), State :: #{}) -> State2 :: #{}.
run_query_internal(Query, #{queries := Queries} = State) ->
    try
        #athena_query{query_bin = QueryBin} = Query,
        Token = util_id:new_uuid(),
        {ok, ExecToken} = erlcloud_athena:start_query_execution(Token,
            ?ATHENA_DB, QueryBin, ?ATHENA_RESULT_S3_BUCKET),
        ?INFO("ExecToken: ~p", [ExecToken]),
        Query2 = Query#athena_query{query_token = Token, result_token = ExecToken},

        State#{queries => maps:put(ExecToken, Query2, Queries)}
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("Error in run_athena_queries: ~p Stacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            State
    end.

-spec run_queries_internal(Queries ::  list(athena_query()), State :: #{}) -> State2 :: #{}.
run_queries_internal([], State) ->
    State;
run_queries_internal([Query | Rest], State) ->
    State2 = run_query_internal(Query, State),
    run_queries_internal(Rest, State2).


check_queries_internal(#{queries := Queries} = State) when map_size(Queries) =:= 0 ->
    {ok, State};
check_queries_internal(#{queries := Queries} = State) ->
    QueryExecutionIds = maps:keys(Queries),
    ?INFO("checking queries ~s", [QueryExecutionIds]),
    case erlcloud_athena:batch_get_query_execution(QueryExecutionIds) of
        {ok, Result} ->
            ?INFO("Result:~p", [Result]),
            Executions = maps:get(<<"QueryExecutions">>, Result, []),
            lists:foreach(
                fun (Execution) ->
                    Id = maps:get(<<"QueryExecutionId">>, Execution),
                    Query = maps:get(<<"Query">>, Execution),
                    Status = maps:get(<<"Status">>, Execution, #{}),
                    QState = maps:get(<<"State">>, Status, <<"UNKNOWN">>),
                    case QState of
                        <<"SUCCEEDED">> ->
                            ?INFO("Query SUCCEEDED ID: ~s Query: ~p", [Id, Query]),
                            fetch_query_results(Id);
                        <<"FAILED">> ->
                            ?ERROR("Query FAILED ID: ~s Query: ~p", [Id, Query]),
                            delete_query(Id);
                        _ ->
                            ?INFO("QueryId ~s State: ~s", [Id, QState])
                    end
                end,
                Executions
            ),
            {ok, State};
        {error, Reason} ->
            ?ERROR("reason: ~p", [Reason]),
            {ok, State}
    end.

fetch_query_results_internal(ExecutionId, #{queries := Queries} = State) ->
    try
        ?INFO("fetching results for ~s", [ExecutionId]),
        % remove the query
        {Query, Queries2} = maps:take(ExecutionId, Queries),

        {ok, Result} = erlcloud_athena:get_query_results(ExecutionId),
        Query2 = Query#athena_query{result = Result},

        process_result(Query2),
        State#{queries => Queries2}
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("Error in query_execution_results: ~p Stacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            State
    end.


process_result(#athena_query{query_bin = QueryBin, result = Result} = Query) ->
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    ?INFO("query: ~p", [QueryBin]),
    pretty_print_result(ResultRows),
    case Query#athena_query.result_fun of
        undefined -> ok;
        {Mod, Fun} ->
            %% Apply result function
            ok = erlang:apply(Mod, Fun, [Query])
    end.


pretty_print_result(Result) ->
    ?INFO("==========================================================="),
    pretty_print_internal(Result),
    ?INFO("==========================================================="),
    ok.


pretty_print_internal([#{<<"Data">> := []} | Rest]) ->
    pretty_print_internal(Rest);
pretty_print_internal([#{<<"Data">> := RowValues} | Rest]) ->
    FormatStr = lists:foldl(fun(_, Acc) -> Acc ++ " ~s |" end, "|", RowValues),
    ?INFO(FormatStr, RowValues),
    pretty_print_internal(Rest);
pretty_print_internal([]) ->
    ok.


get_athena_queries() ->
    Modules = get_athena_modules(),
    Queries = lists:foldl(
        fun(Module, Acc) ->
            [erlang:apply(Module, get_queries, []) | Acc]
        end, [], Modules),
    lists:flatten(Queries).


get_athena_modules() ->
    [
        athena_encryption,
        athena_group_encryption,
        athena_home_encryption,
        athena_push,
        athena_media,
        athena_call
    ].
