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
-include("xmpp.hrl").
-include("packets.hrl").
-include("time.hrl").

%% TODO: rename db?
-define(iOS, <<"ios">>).
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
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()),
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(get_proc()),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).


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
    gen_server:cast(get_proc(), query_encryption_stats),
    ok.

-spec query_execution_results(Queries :: [binary()], ExecIds :: [binary()]) -> ok.
query_execution_results(Queries, ExecIds) ->
    gen_server:cast(get_proc(), {query_execution_results, Queries, ExecIds}),
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
        
        {{_Year, _Month, Day},{_Hour, _Min, _Sec}} = erlang:localtime(),
        QueryDate = util:to_binary(Day - 7),

        %% Android success rates
        Query1 = get_success_rates_query(?ANDROID, QueryDate),
        Token1 = util:new_uuid(),
        {ok, ExecId1} = erlcloud_athena:start_query_execution(Token1, ?ATHENA_DB, Query1, ?ATHENA_RESULT_S3_BUCKET),

        %% iOS success rates
        Query2 = get_success_rates_query(?iOS, QueryDate),
        Token2 = util:new_uuid(),
        {ok, ExecId2} = erlcloud_athena:start_query_execution(Token2, ?ATHENA_DB, Query2, ?ATHENA_RESULT_S3_BUCKET),

        %% Android decryption reason rates
        Query3 = get_decryption_reason_rates_query(?ANDROID, QueryDate),
        Token3 = util:new_uuid(),
        {ok, ExecId3} = erlcloud_athena:start_query_execution(Token3, ?ATHENA_DB, Query3, ?ATHENA_RESULT_S3_BUCKET),

        %% Android decryption reason rates
        Query4 = get_decryption_reason_rates_query(?iOS, QueryDate),
        Token4 = util:new_uuid(),
        {ok, ExecId4} = erlcloud_athena:start_query_execution(Token4, ?ATHENA_DB, Query4, ?ATHENA_RESULT_S3_BUCKET),

        Queries = [Query1, Query2, Query3, Query4],
        ExecIds = [ExecId1, ExecId2, ExecId3, ExecId4],

        %% Ideally, we need to periodically list execution results and search for execids.
        %% For now, fetch results after 5 minutes - since our queries are simple.
        {ok, _ResultTref} = timer:apply_after(5 * ?MINUTES_MS, ?MODULE,
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
                ?INFO("result: ~p", [ResultRows])
                %% TODO(murali@): send this to opentsdb.
            end, list:zip(Queries, Results)),
        State
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("Error in query_execution_results: ~p Stacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            State
    end.



-spec get_success_rates_query(Platform :: binary(), Date :: binary()) -> binary().
get_success_rates_query(Platform, Date) ->
    Query = <<"
        SELECT enc_success.version, enc_success.success_rate as enc_success_rate,
            enc_success.total_count as enc_total_count, dec_success.success_rate as dec_success_rate,
            dec_success.total_count as dec_total_count
        FROM
            (SELECT success.version, ROUND(success.count * 100 / total.count, 2) as success_rate, total.count as total_count
            FROM
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_encryption\"
                    where platform='", Platform/binary, "' AND result='success' AND \"date\" >= '", Date/binary, "'
                    GROUP BY version) as success
            JOIN
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_encryption\"
                    where platform='", Platform/binary, "' AND \"date\" >= '", Date/binary, "'
                    GROUP BY version) as total
                on success.version=total.version) as enc_success
        JOIN
            (SELECT success.version, ROUND(success.count * 100 / total.count, 2) as success_rate, total.count as total_count
            FROM
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_decryption\"
                    where platform='", Platform/binary, "' AND result='success' AND \"date\" >= '", Date/binary, "'
                    GROUP BY version) as success
            JOIN
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_decryption\"
                    where platform='", Platform/binary, "' AND \"date\" >= '", Date/binary, "'
                    GROUP BY version) as total  on success.version=total.version) as dec_success
        on enc_success.version=dec_success.version
        ORDER BY enc_success.version DESC;">>,
    Query.


-spec get_decryption_reason_rates_query(Platform :: binary(), Date :: binary()) -> binary().
get_decryption_reason_rates_query(Platform, Date) ->
    Query = <<"
        SELECT reason.version, reason.result,
            ROUND(reason.count * 100.0 / total.count, 2) as reason_rate,
            reason.count as reason_count, total.count as total_count
        FROM
            (SELECT version, result, SUM(cast(count AS INTEGER)) as count
            FROM \"default\".\"client_crypto_decryption\"
                where platform='", Platform/binary, "' AND result!='success' AND \"date\" >= '", Date/binary, "'
                GROUP BY version, result) as reason
            JOIN
            (SELECT version, SUM(cast(count AS INTEGER)) as count
            FROM \"default\".\"client_crypto_decryption\"
                where platform='", Platform/binary, "' AND result!='success' AND \"date\" >= '", Date/binary, "'
                GROUP BY version) as total  on reason.version=total.version
        ORDER BY reason.version DESC, reason.count DESC;">>,
    Query.

