%%%----------------------------------------------------------------------
%%% File    : redis_migrate_worker.erl
%%%
%%% Copyright (C) 2021 HalloApp inc.
%%%
%%%----------------------------------------------------------------------
-module(redis_migrate_worker).
-include_lib("stdlib/include/assert.hrl").

-behavior(gen_server).
-include("logger.hrl").
-include("time.hrl").


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

%% API
-export([
    spawn_link/2,
    start/2,
    stop/1,
    reset/1,
    get_progress/1,
    iterate/1
]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                                          API                                                %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


-spec spawn_link(Node :: atom(), Args :: list()) -> gen_server:start_ref().
spawn_link(Node, Args) ->
    spawn_link(Node, ?MODULE, start, Args).


-spec start(Name :: string(), Job :: map()) -> gen_server:start_ref().
start(Name, Job) ->
    ?INFO("Starting migration ~s on Node: ~p, Job: ~p", [Name, node(), Job]),
    gen_server:start({global, Name}, ?MODULE, Job, []).


-spec stop(ServerRef :: gen_server:start_ref()) -> ok.
stop(ServerRef) ->
    gen_server:stop(ServerRef).


% Reset the scan of particular shard of the migration
-spec reset(Name :: string()) -> ok.
reset(Name) ->
    gen_server:call({global, Name}, {reset}).


% Return the progress of this migration in percent as float.
-spec get_progress(Name :: string()) -> float().
get_progress(Name) ->
    gen_server:call({global, Name}, {get_progress}).


iterate(Name) ->
    gen_server:call({global, Name}, {iterate}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                                   gen_server API                                            %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


-spec init(Job :: #{}) -> {ok, any()}.
init(#{redis_host := RedisHost, redis_port := RedisPort, interval := Interval,
        dry_run := DryRun, scan_count := ScanCount, params := Params} = Job) ->
    ?INFO("Migration started: pid: ~p, Job: ~p", [self(), Job]),
    {ok, C} = ecredis:start_link(RedisHost, RedisPort),
    ?INFO("connection ok: ~p", [C]),

    TRef = erlang:send_after(Interval, self(), {'$gen_cast', {iterate}}),
    State = Job#{
        cursor => <<"0">>,
        c => C,
        tref => TRef,
        dry_run => DryRun,
        scan_count => integer_to_binary(ScanCount),
        params => Params
    },
    {ok, State}.


handle_call({get_progress}, _From, State) ->
%%    _Cursor = State#{cursor},
    % TODO: compute the migration progress based on the cursor.
    {reply, 0.0, State};


handle_call({reset}, From, State) ->
    ?INFO("resetting from ~p", [From]),
    NewState = State#{cursor := <<"0">>},
    {reply, ok, NewState};


handle_call(Any, From, State) ->
    ?ERROR("Unhandled message: ~p from: ~p", [Any, From]),
    {reply, ignore, State}.


handle_cast({iterate}, State) ->
    Cursor = maps:get(cursor, State),
    {Mod, Func} = maps:get(migrate_func, State),
    Interval = maps:get(interval, State),
    C = maps:get(c, State),
    Count = maps:get(scan_count, State),
    {ok, [NextCursor, Items]} = ecredis:q(C, ["SCAN", Cursor, "COUNT", Count]),
    ?DEBUG("NextCursor: ~p, items: ~p", [NextCursor, length(Items)]),
    {Result, NewState1} = iterate_keys(
        fun (Key, S) -> erlang:apply(Mod, Func, [Key, S]) end,
        State,
        Items),

    case {Result, NextCursor} of
        {stop, _} ->
            ?INFO("scan aborted by stop"),
            send_report(NewState1),
            {stop, normal, NewState1};
        {ok, <<"0">>} ->
            ?INFO("scan done - all keys scanned"),
            send_report(NewState1),
            {stop, normal, NewState1};
        {ok, _} ->
            TRef = erlang:send_after(Interval, self(), {'$gen_cast', {iterate}}),
            NewState2 = NewState1#{
                cursor := NextCursor,
                tref := TRef
            },
            {noreply, NewState2}
    end;

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


-spec iterate_keys(fun(), State :: map(), Keys :: list(string())) ->
    {ok, State :: map()} | {stop, State :: map()}.
iterate_keys(_Func, State, []) ->
    {ok, State};
iterate_keys(Func, State, [Key | Rest]) ->
    {Res, State3} = case Func(Key, State) of
        ok -> {ok, State};
        stop -> {stop, State};
        {ok, State2} -> {ok, State2};
        {stop, State2} -> {stop, State2};
        _ -> {ok, State}
    end,
    case Res of
        stop ->
            ?INFO("terminating migration by stop request ~p", [State3]),
            {stop, State3};
        ok ->
            iterate_keys(Func, State3, Rest)
    end.


-spec send_report(State :: #{}) -> ok.
send_report(State) ->
    CountersReport = maps:get(counters, State, #{}),
    MainPid = maps:get(main_pid, State, undefined),
    case MainPid of
        undefined -> ?ERROR("Invalid MainPid, State: ~p", [State]);
        _ ->
            gen_server:cast(MainPid, {report, CountersReport})
    end,
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                                 Migration functions                                        %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



