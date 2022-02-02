%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 01. Jun 2020 5:27 PM
%%%-------------------------------------------------------------------
-module(redis_migrate).
-author("nikola").

-include_lib("stdlib/include/assert.hrl").

-behavior(gen_server).
-include("account.hrl").
-include("logger.hrl").
-include("time.hrl").
-include("whisper.hrl").
-include("feed.hrl").
-include("client_version.hrl").


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

%% API
-export([
    start_migration/3,
    start_migration/4,
    stop/1,
    get_progress/1
]).


-type migrate_func() :: atom() | {module(), atom()}.
-type option() ::
    {execute, parallel | sequential} |
    {dry_run, true | false} |
    {scan_count, non_neg_integer()} |
    {interval, non_neg_integer()} |
    {params, any()}.
-type options() :: [option()].
-export_type([migrate_func/0, option/0, options/0]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                                          API                                                %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Start a migration with given name by iterating over all keys in RedisService and calling
% the Function for each key. Migration runs in parallel for each master and executed on
% all nodes in the erlang cluster.
%
% Function must have the following spec:
% -spec f(Key :: binary(), State :: #{}) -> ok | stop | {ok, NewState :: #{}} | {stop, NewState :: #{}}.
% The function will be called for each key stored in the RedisCluster. Function should ignore
% keys it is not interested in, and do some processing on keys it is interested in.
% Migration functions should be idempotent because a migration might have to be re-run on
% some range of keys due to Redis Master switch or other reasons.
% Migration functions can ask the migration to terminate by returning stop or {stop, State}.
% Migration functions can also store their own date in the State.
-spec start_migration(Name :: string(), RedisService :: atom(), Function :: migrate_func()) -> ok.
start_migration(Name, RedisService, Function) ->
    start_migration(Name, RedisService, Function, []).


-spec start_migration(Name, RedisService, Function, Options)
            -> ok when
            Name :: string(),
            RedisService :: atom(),
            Function :: migrate_func(),
            Options :: options().
start_migration(Name, RedisService, Function, Options) ->
    Args = [Name, RedisService, Function, Options],
    ProcName = {global, util:to_atom(Name)},
    {ok, Pid} = gen_server:start_link(ProcName, ?MODULE, Args, []),
    ?INFO("MainProcess for migration, ProcName: ~p, Pid: ~p", [ProcName, Pid]),
    ok.


-spec stop(ServerRef :: gen_server:start_ref()) -> ok.
stop(ServerRef) ->
    %% Stopping this gen_server should stop all its children - since all these are linked processes.
    gen_server:stop(ServerRef).


% Return the progress of this migration in percent as float.
-spec get_progress(Name :: string()) -> float().
get_progress(Name) ->
    gen_server:call(Name, {get_progress}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                                   gen_server API                                            %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([Name, RedisService, Function, Options]) ->
    ?INFO("Name: ~s RedisService: ~p, Function: ~p", [Name, RedisService, Function]),

    Nodes = get_execution_nodes(Options),
    NodesArr = list_to_tuple(Nodes),

    RedisMasters = get_masters(RedisService),
    ?INFO("redis masters: ~p", [RedisMasters]),
    {Mod, Func} = case Function of
        {M, F} -> {M, F};
        F -> {?MODULE, F}
    end,
    case erlang:function_exported(Mod, Func, 2) of
        false -> erlang:error("Function ~p:~p is not exported", [Mod, Func]);
        true -> ok
    end,

    EnumNodes = lists:zip(lists:seq(0, length(RedisMasters) - 1), RedisMasters),
    Job = #{
        service => RedisService,
        migrate_func => {Mod, Func},
        interval => proplists:get_value(interval, Options, 1000),
        scan_count => proplists:get_value(scan_count, Options, 100),
        dry_run => proplists:get_value(dry_run, Options, false),
        params => proplists:get_value(params, Options, undefined)
    },
    Pids = lists:map(
        fun ({Index, {RedisHost, RedisPort}}) ->
            % make job for each redis master
            AJob = Job#{
                redis_host => RedisHost,
                redis_port => RedisPort,
                main_pid => self()    %% main process to report the results back to.
            },

            % pick the next node (round robin) where to run the scan
            Node = element(1 + (Index rem size(NodesArr)), NodesArr),
            PName = Name ++ "." ++ integer_to_list(Index),
            %% TODO(murali@): make this a monitor to produce partial results.
            redis_migrate_worker:spawn_link(Node, [PName, AJob])
        end,
        EnumNodes),
    ?INFO("pids: ~p", [Pids]),
    ?INFO("nodes: ~p", [Nodes]),
    {ok, #{
        children => Pids,
        conclude_func => proplists:get_value(conclude_func, Options, undefined),
        reports => []
    }}.


handle_call({get_progress}, _From, State) ->
%%    _Cursor = State#{cursor},
    % TODO: compute the migration progress based on the cursor.
    {reply, 0.0, State};

handle_call(Any, From, State) ->
    ?ERROR("Unhandled message: ~p from: ~p", [Any, From]),
    {reply, ignore, State}.


handle_cast({report, ChildReport}, State) ->
    %% Store report received by the child process.
    NumChildren = length(maps:get(children, State)),
    CurReports = maps:get(reports, State),
    NewReports = CurReports ++ [ChildReport],
    NewState = State#{reports => NewReports},
    NumReports = length(NewReports),
    %% TODO: We should have a nicer way to check if all the child processes are done or not.
    %% If we received reports from all children - then process all of them.
    case NumReports =:= NumChildren of
        true ->
            gen_server:cast(self(), {process_reports});
        false ->
            ?INFO("Waiting for more reports, NumReports: ~p, NumChildren: ~p",
                [NumReports, NumChildren])
    end,
    {noreply, NewState};

handle_cast({process_reports}, State) ->
    %% TODO: Have the conclude function take the list of reports and then act accordingly.
    %% Process all the reports received.
    Reports = maps:get(reports, State),
    %% Iterate through all the reports and then combine the counters with the same key.
    FinalReport = lists:foldl(
        fun(Report1, AccReport) ->
            %% TODO: this is not great - assumes counter key-values are always list.
            Fun = fun(K,V1) -> [X+Y || {X,Y} <- lists:zip(V1, maps:get(K, AccReport, [0, 0]))] end,
            maps:map(Fun, Report1)
        end, #{}, Reports),
    %% Obtain the function to conclude and process this report.
    case maps:get(conclude_func, State, undefined) of
        undefined -> ?INFO("No conclude_func defined");
        {Mod, Func} ->
            ?INFO("Applying conclude_func, Mod: ~p, Func: ~p", [Mod, Func]),
            erlang:apply(Mod, Func, [FinalReport])
    end,
    {stop, normal, State};

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.

terminate(Reason, State) ->
    ?INFO("terminating ~p State: ~p", [Reason, State]),
    ok.


code_change(OldVersion, State, _Extra) ->
    ?INFO("OldVersion: ~p", [OldVersion]),
    {ok, State}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                                   internal                                                  %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


get_masters(Service) ->
    Client = ha_redis:get_client(Service),
    Nodes = ecredis:get_nodes(Client),
    [{Ip, Port} || {node, Ip, Port} <- Nodes].


all_nodes() ->
    [node() | nodes()].


get_execution_nodes(Options) ->
    case get_execute_option(Options) of
        parallel -> all_nodes();
        sequential -> [node()]
    end.


get_execute_option(Options) ->
    case proplists:get_value(execute, Options) of
        undefined -> sequential;
        parallel -> parallel;
        sequential -> sequential;
        Other -> erlang:error({wrong_execute_option, Other})
    end.



