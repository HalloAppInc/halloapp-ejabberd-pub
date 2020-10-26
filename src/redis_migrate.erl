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

-behavior(gen_server).
-include("logger.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

%% API
-export([
    start_migration/3,
    start_migration/4,
    start/2,
    stop/1,
    reset/1,
    get_progress/1,
    iterate/1,
    count_accounts/2,
    rename_reverse_contacts_run/2,
    rename_reverse_contacts_verify/2,
    rename_reverse_contacts_cleanup/2,
    remove_unregistered_numbers_run/2,
    remove_unregistered_numbers_verify/2,
    rename_privacy_list_run/2,
    rename_privacy_list_verify/2,
    rename_privacy_list_cleanup/2,
    expire_sync_keys_run/2,
    trigger_full_sync_run/2,
    expire_message_keys_run/2,
    extend_ttl_run/2,
    check_user_agent_run/2
]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                                          API                                                %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Start a migration with given name by iterating over all keys in RedisService and calling
% the Function for each key. Migration runs in parallel for each master and executed on
% all nodes in the erlang cluster.
%
% Function must have the following spec:
% -spec f(Key :: binary(), State :: #{}) -> NewState when NewState :: #{}.
% The function will be called for each key stored in the RedisCluster. Function should ignore
% keys it is not interested in, and do some processing on keys it is interested in.
% Migration functions should be idempotent because a migration might have to be re-run on
% some range of keys due to Redis Master switch or other reasons.
-spec start_migration(Name :: string(), RedisService :: atom(), Function :: atom()) -> ok.
start_migration(Name, RedisService, Function) ->
    start_migration(Name, RedisService, Function, []).


-spec start_migration(Name :: string(), RedisService :: atom(), Function :: atom(), Options)
            -> ok when
            Options :: [Option],
            Option ::
                {execute, parallel | sequential} |
                {dry_run, true | false} |
                {scan_count, non_neg_integer()} |
                {interval, non_neg_integer()}.
start_migration(Name, RedisService, Function, Options) ->
    ?INFO("Name: ~s RedisService: ~p, Function: ~p", [Name, RedisService, Function]),

    Nodes = get_execution_nodes(Options),
    NodesArr = list_to_tuple(Nodes),

    RedisMasters = get_masters(RedisService),
    ?INFO("redis masters: ~p", [RedisMasters]),

    EnumNodes = lists:zip(lists:seq(0, length(RedisMasters) - 1), RedisMasters),
    Job = #{
        service => RedisService,
        function_name => Function,
        interval => proplists:get_value(interval, Options, 1000),
        scan_count => proplists:get_value(scan_count, Options, 100),
        dry_run => proplists:get_value(dry_run, Options, false)
    },
    Pids = lists:map(
        fun ({Index, {RedisHost, RedisPort}}) ->
            % make job for each redis master
            AJob = Job#{
                redis_host => RedisHost,
                redis_port => RedisPort
            },

            % pick the next node (round robin) where to run the scan
            Node = element(1 + (Index rem size(NodesArr)), NodesArr),
            PName = Name ++ "." ++ integer_to_list(Index),
            spawn_link(Node, ?MODULE, start, [PName, AJob])
        end,
        EnumNodes),
    ?INFO("pids: ~p", [Pids]),
    ?INFO("nodes: ~p", [Nodes]),
    ok.


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
init(#{redis_host := RedisHost, redis_port := RedisPort,
        interval := Interval, dry_run := DryRun, scan_count := ScanCount} = Job) ->
    ?INFO("Migration started: pid: ~p, Job: ~p", [self(), Job]),
    process_flag(trap_exit, true),
    {ok, C} = eredis:start_link(RedisHost, RedisPort),
    ?INFO("connection ok: ~p", [C]),

    TRef = erlang:send_after(Interval, self(), {'$gen_cast', {iterate}}),
    State = Job#{
        cursor => <<"0">>,
        c => C,
        tref => TRef,
        dry_run => DryRun,
        scan_count => integer_to_binary(ScanCount)
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
    Function = maps:get(function_name, State),
    Interval = maps:get(interval, State),
    C = maps:get(c, State),
    Count = maps:get(scan_count, State),
    {ok, [NextCursor, Items]} = eredis:q(C, ["SCAN", Cursor, "COUNT", Count]),
    ?DEBUG("NextCursor: ~p, items: ~p", [NextCursor, length(Items)]),
    NewState1 = lists:foldl(
        fun (Key, Acc) ->
            erlang:apply(?MODULE, Function, [Key, Acc])
        end,
        State,
        Items),
    case NextCursor of
        <<"0">> ->
            ?INFO("scan done", []),
            {stop, normal, NewState1};
        _ ->
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


get_masters(Service) ->
    Client = get_redis_client(Service),
    {ok, {ok, Result}} = gen_server:call(Client, {q, ["CLUSTER", "SLOTS"]}),
    get_masters_from_slots(Result).


get_masters_from_slots([]) ->
    [];
get_masters_from_slots([H | T]) ->
    [_SlotStart, _SlotEnd, [MasterIP, MasterPort, _Hash] | _Slaves] = H,
    [{binary_to_list(MasterIP), binary_to_integer(MasterPort)} | get_masters_from_slots(T)].


% TODO: move to some util_redis
get_redis_client(Service) ->
    list_to_atom(atom_to_list(Service) ++"_client").


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

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                                 Migration functions                                        %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


count_accounts(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    % TODO: implement
    State.


rehash_phones(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    % TODO: implement
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Rename reverse contact keys                                %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%% Stage 1. Move the data.
rename_reverse_contacts_run(Key, State) ->
    migrate_contact_data:rename_reverse_contacts_run(Key, State).


%%% Stage 2. Check if the migrated data is in sync
rename_reverse_contacts_verify(Key, State) ->
    migrate_contact_data:rename_reverse_contacts_verify(Key, State).


%%% Stage 3. Delete the old data
rename_reverse_contacts_cleanup(Key, State) ->
    migrate_contact_data:rename_reverse_contacts_cleanup(Key, State).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                       Remove unregistered numbers                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Stage1: Remove the unregistered phone numbers in our database.
remove_unregistered_numbers_run(Key, State) ->
    migrate_contact_data:remove_unregistered_numbers_run(Key, State).


%%% Stage 2. Check if the remaining data is correct.
remove_unregistered_numbers_verify(Key, State) ->
    migrate_contact_data:remove_unregistered_numbers_verify(Key, State).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Rename privacy lists                                     %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%% Stage 1. Rename the privacylists.
rename_privacy_list_run(Key, State) ->
    migrate_privacy_data:run(Key, State).


%%% Stage 2. Check if the migrated data is in sync
rename_privacy_list_verify(Key, State) ->
    migrate_privacy_data:verify(Key, State).


%%% Stage 3. Delete the old data
rename_privacy_list_cleanup(Key, State) ->
    migrate_privacy_data:cleanup(Key, State).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Expire sync keys                                     %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%% Stage 1. Set expiry for sync keys.
expire_sync_keys_run(Key, State) ->
    migrate_contact_data:expire_sync_keys_run(Key, State).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                            Trigger full sync                                       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_full_sync_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            case DryRun of
                true ->
                    ?INFO("would send empty hash to: ~p", [Uid]);
                false ->
                    ok = mod_contacts:trigger_full_contact_sync(Uid),
                    ?INFO("sent empty hash to: ~p", [Uid])
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Expire sync keys                                     %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%% Stage 1. Set expiry for message keys.
expire_message_keys_run(Key, State) ->
    migrate_message_data:expire_message_keys_run(Key, State).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Extend ttl for feed keys                                 %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%% Stage 1. Extend ttl for feed keys.
extend_ttl_run(Key, State) ->
    migrate_feed_data:extend_ttl_run(Key, State).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check user_agent for all acc keys.                         %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_user_agent_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, Result} = q(redis_accounts_client, ["HGET", FullKey, <<"ua">>]),
            case Result of
                undefined ->
                    ?ERROR("Uid: ~p, user agent is still empty!", [Uid]);
                _ -> ok
            end;
        _ -> ok
    end,
    State.

q(Client, Command) -> util_redis:q(Client, Command).
