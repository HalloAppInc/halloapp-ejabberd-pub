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
-include("client_version.hrl").

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
    check_user_agent_run/2,
    count_users_by_version_run/2,
    check_users_by_whisper_keys/2,
    check_accounts_run/2,
    check_phone_numbers_run/2,
    refresh_otp_keys_run/2,
    update_version_keys_run/2,
    find_inactive_accounts/2
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
    Client = util_redis:get_redis_client(Service),
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
            {ok, Result} = q(ecredis_accounts, ["HGET", FullKey, <<"ua">>]),
            case Result of
                undefined ->
                    ?ERROR("Uid: ~p, user agent is still empty!", [Uid]);
                _ -> ok
            end;
        _ -> ok
    end,
    State.

q(Client, Command) -> util_redis:q(Client, Command).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Compute user counts by version                            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

count_users_by_version_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, Version} = q(ecredis_accounts, ["HGET", FullKey, <<"cv">>]),
            case Version of
                undefined ->
                    ?ERROR("Uid: ~p, client_version is undefined!", [Uid]);
                _ ->
                    Slot = util_redis:eredis_hash(Uid),
                    VersionKey = model_accounts:version_key(Slot, Version),
                    case DryRun of
                        true ->
                            ?INFO("Uid: ~p, would increment counter for: ~p", [Uid, VersionKey]);
                        false ->
                            {ok, Value} = q(ecredis_accounts, ["INCR", VersionKey]),
                            ?INFO("Uid: ~p, would increment counter for: ~p, value: ~p",
                                    [Uid, VersionKey, Value])
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all user accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_accounts_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case Phone of
                undefined ->
                    ?ERROR("Uid: ~p, Phone is undefined!", [Uid]);
                _ ->
                    {ok, PhoneUid} = model_phone:get_uid(Phone),
                    case PhoneUid =:= Uid of
                        true -> ok;
                        false ->
                            ?ERROR("uid mismatch for phone map Uid: ~s Phone: ~s PhoneUid: ~s",
                                    [Uid, Phone, PhoneUid]),
                            ok
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all phone number accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_phone_numbers_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Phone]]} ->
            ?INFO("phone number: ~p", [Phone]),
            {ok, Uid} = model_phone:get_uid(Phone),
            case Uid of
                undefined ->
                    ?ERROR("Phone: ~p, Uid is undefined!", [Uid]);
                _ ->
                    {ok, UidPhone} = model_accounts:get_phone(Uid),
                    case UidPhone =/= undefined andalso UidPhone =:= Phone of
                        true -> ok;
                        false ->
                            ?ERROR("phone: ~p, uid: ~p, uidphone: ~p", [Uid, Phone, UidPhone]),
                            ok
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         refresh otp keys for some accounts                       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

refresh_otp_keys_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, Version} = q(ecredis_accounts, ["HGET", FullKey, <<"cv">>]),
            case Version of
                undefined ->
                    ?ERROR("Undefined client version for a uid: ~p", [Uid]);
                _ ->
                    case util_ua:get_client_type(Version) =:= ios andalso
                            util_ua:is_version_greater_than(Version, <<"HalloApp/iOS1.2.91">>) of
                        false -> ok;
                        %% refresh otp keys for all ios accounts with version > 1.2.91
                        true ->
                            case DryRun of
                                true ->
                                    ?INFO("Uid: ~p, would refresh keys for: ~p", [Uid, Version]);
                                false ->
                                    ?INFO("Uid: ~p, Version: ~p", [Uid, Version]),
                                    ok = mod_whisper:refresh_otp_keys(Uid)
                            end
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                migrate version keys                                %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% For all accounts - go through them - compute the slot and get the version.
%% increment the corresponding field.
update_version_keys_run(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            Slot = util_redis:eredis_hash(binary_to_list(Uid)),
            case q(ecredis_accounts, ["HGET", FullKey, <<"cv">>]) of
                {ok, undefined} ->
                    ?ERROR("Undefined client version for a uid: ~p", [Uid]);
                {ok, Version} ->
                    NewSlot = Slot rem ?NUM_VERSION_SLOTS,
                    case DryRun of
                        true ->
                            ?INFO("would have incremented, slot: ~p, version: ~p by 1", [NewSlot, Version]);
                        false ->
                            {ok, FinalCount} = q(ecredis_accounts,
                                ["HINCRBY", model_accounts:new_version_key(NewSlot), Version, 1]),
                            ?INFO("updated key, slot: ~p, version: ~p, finalCount: ~p",
                                    [NewSlot, Version, FinalCount]),
                            ok
                    end;
                Res ->
                    ?ERROR("error with key: uid: ~p, result: ~p", [Uid, Res])
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Generate List of inactive users                            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

find_inactive_accounts(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            try
                {ok, LastActivity} = model_accounts:get_last_activity(Uid),
                #activity{uid = Uid, last_activity_ts_ms = LastTsMs} = LastActivity,

                %% Designate account inactive if last activity 27 weeks ago (approximately 180 days).
                IsAccountInactive = case LastTsMs of
                    undefined ->
                        ?ERROR("Undefined last active for Uid: ~p", [Uid]),
                        false;
                    _ ->
                        CurrentTimeMs = os:system_time(millisecond),
                        (CurrentTimeMs - LastTsMs) > 27 * ?WEEKS_MS
                end,
                case IsAccountInactive of
                    true ->
                        case DryRun of
                            true ->
                                  ?INFO("Adding Uid: ~p to delete", [Uid]);
                            false ->
                                  model_accounts:add_uid_to_delete(Uid)
                        end;
                    false -> ok
                end
            catch
                Class:Reason:Stacktrace ->
                    ?ERROR("Stacktrace:~s", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
                    ?ERROR("Unable to get last activity: ~p", [Uid])
            end,
            ok;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Compute user counts by whisper keys                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_users_by_whisper_keys(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            %% Don't fetch Otp keys.
            {ok, KeySet} = model_whisper_keys:get_key_set_without_otp(Uid),
            case KeySet of
                undefined ->
                    ?INFO("Uid: ~p, Keys undefined, ~s", [Uid, user_details(Uid)]);
                _ ->
                    #user_whisper_key_set{uid = Uid, identity_key = IdentityKey,
                        signed_key = SignedKey, one_time_key = OneTimeKey} = KeySet,
                    ?assertEqual(OneTimeKey, undefined),
                    case is_invalid_key(IdentityKey) orelse is_invalid_key(SignedKey) of
                        true -> 
                            ?INFO("Uid: ~p, Keys invalid, (Identity: ~p), (Signed: ~p), ~s",
                                  [Uid, is_invalid_key(IdentityKey), is_invalid_key(SignedKey),
                                   user_details(Uid)]);
                        _ -> ?INFO("Uid: ~p, Keys ok", [Uid])
                    end
            end;
        _ -> ok
    end,
    State.

is_invalid_key(Key) ->
    Key == undefined orelse not is_binary(Key) orelse byte_size(Key) == 0.

user_details(Uid) ->
    try
        user_details2(Uid)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            io_lib:format("Unable to fetch details", [])
    end.

user_details2(Uid) ->
    {ok, Account} = model_accounts:get_account(Uid),
    #account{uid = Uid, name = Name, phone = Phone, signup_user_agent = UA, creation_ts_ms = CtMs,
        last_activity_ts_ms = LaTsMs, activity_status = ActivityStatus, client_version = CV} =
            Account,
    IsTestPhone = util:is_test_number(Phone),

    %% Get list of internal inviter phone numbers if any.
    {ok, InvitersList} = model_invites:get_inviters_list(Phone),
    InternalInviterPhoneNums = lists:foldl(
        fun(X, Acc) ->
            {InviterUid, _Ts} = X,
            case dev_users:is_dev_uid(InviterUid) of
                true ->
                    {ok, InviterPhoneNum} = model_accounts:get_phone(InviterUid),
                    io_lib:format("~s~s, ", [Acc, util:to_list(InviterPhoneNum)]);
                _ -> Acc
            end
        end,
        "",
        InvitersList),

    LastActivityTimeString = case LaTsMs of
        undefined -> undefined;
        _ -> 
          calendar:system_time_to_rfc3339(LaTsMs,
              [{unit, millisecond}, {time_designator, $\s}])
    end,

    %% Designate account inactive if last activity 13 weeks ago.
    IsAccountInactive = case LaTsMs of
        undefined -> true;
        _ ->
            CurrentTimeMs = os:system_time(millisecond),
            (CurrentTimeMs - LaTsMs) > 13 * ?WEEKS_MS
    end,
    CreationTimeString = case CtMs of
        undefined -> undefined;
        _ -> 
          calendar:system_time_to_rfc3339(CtMs,
              [{unit, millisecond}, {time_designator, $\s}])
    end,
    io_lib:format("Last Activity: ~s, Last Status: ~s, Name: ~s, Creation: ~s, Test Phone?: ~s, "
        "Client Version: ~s, User Agent: ~s, Inactive?: ~s, Internal Inviters: ~s",
        [LastActivityTimeString, ActivityStatus, util:to_list(Name), CreationTimeString,
         IsTestPhone, util:to_list(CV), util:to_list(UA), IsAccountInactive,
         InternalInviterPhoneNums]).

