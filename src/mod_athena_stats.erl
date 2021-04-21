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
    run_athena_queries/0,
    force_run_athena_queries/0, %% DEBUG-only
    fetch_query_results/1
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
    Queries = get_athena_queries(),
    {ok, #{queries => Queries}}.

terminate(_Reason, #{} = _State) ->
    ?INFO("Terminate: ~p", [?MODULE]),
    ok.

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

handle_cast(run_athena_queries, State) ->
    {noreply, run_athena_queries(State)};
handle_cast({fetch_query_results, Queries}, State) ->
    {noreply, fetch_query_results(Queries, State)};
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


-spec force_run_athena_queries() -> ok.
force_run_athena_queries() ->
    gen_server:cast(?PROC(), run_athena_queries),
    ok.


-spec fetch_query_results(Queries :: [athena_query()]) -> ok.
fetch_query_results(Queries) ->
    gen_server:cast(?PROC(), {fetch_query_results, Queries}),
    ok.


%%====================================================================
%% internal functions
%%====================================================================

init_erlcloud() ->
    {ok, _} = application:ensure_all_started(erlcloud),
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),
    ok.

run_athena_queries(#{queries := Queries} = State) ->
    try
        Queries1 = lists:map(
            fun(#athena_query{query_bin = QueryBin} = Query) ->
                Token = util:new_uuid(),
                ExecToken = erlcloud_athena:start_query_execution(Token,
                        ?ATHENA_DB, QueryBin, ?ATHENA_RESULT_S3_BUCKET),
                Query#athena_query{query_token = Token, result_token = ExecToken}
            end, Queries),

        %% Ideally, we need to periodically list execution results and search for execids.
        %% For now, fetch results after 10 minutes - since our queries are simple.
        {ok, _ResultTref} = timer:apply_after(10 * ?MINUTES_MS, ?MODULE,
                fetch_query_results, [Queries1]),

        State
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("Error in run_athena_queries: ~p Stacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            State
    end.


fetch_query_results(Queries, State) ->
    try
        QueriesWithResults = lists:map(
            fun(Query) ->
                {ok, Result} = erlcloud_athena:get_query_results(Query#athena_query.result_token),
                Query#athena_query{result = Result}
            end, Queries),

        lists:foreach(
            fun(#athena_query{query_bin = QueryBin, result = Result} = Query) ->
                ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
                ?INFO("query: ~p", [QueryBin]),
                pretty_print_result(ResultRows),
                case Query#athena_query.result_fun of
                    undefined -> ok;
                    {Mod, Fun} ->
                        %% Apply result function
                        ok = erlang:apply(Mod, Fun, [Query])
                end
            end, QueriesWithResults),
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
        athena_push
    ].

