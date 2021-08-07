%%%=============================================================================
%%% File: mod_backup.erl
%%% Copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module to manage Redis backups on AWS
%%% 
%%% Specification:
%%% https://github.com/HalloAppInc/server/blob/master/doc/backup_spec.md
%%% 
%%% S3 FILE STRUCTURE:
%%% - At the top level, each Redis Cluster has its own metadata file
%%% - At the top level, there are short-term and long-term buckets:
%%%   - short-term: folder that contains all of the short-term backups
%%%       (including backup files and snapshot-specific metadata)
%%%   - long-term: folder that contains all of the long-term backups
%%%       (including backup files and snapshot-specific metadata)
%%% 
%%% EXAMPLE:
%%% ha-redis-backups
%%% |-- redis-messages-metadata.json
%%% |-- redis-feed-metadata.json
%%% |-- redis-contacts-metadata.json
%%% |-- short-term
%%% |   |-- redis-messages-backupA-0001.rdb
%%% |   |-- redis-messages-backupA-0002.rdb
%%% |   |-- ...
%%% |   |-- redis-messages-backupA-XXXX.rdb
%%% |   |-- redis-messages-backupB-0001.rdb
%%% |   |-- ...
%%% |   |-- redis-feed-backupA-0001.rdb
%%% |   |-- ...
%%% |-- long-term
%%% |   |-- redis-messages-backupC-0001.rdb
%%% |   |-- ...
%%% |   |-- redis-feed-backupB-0001.rdb
%%% |   |-- ...
%%% 
%%% TODO: have a gen_server for backups to avoid subtle race conditions.
%%%   currently, it's technically possible for two invocations of backup_redis/1
%%%   to be running at the same time, and the following interleaving of function
%%%   calls will lead to a race condition:
%%%         
%%%                 process A                  process B
%%%                     |                          |
%%%          create_elasticache_backup             |
%%%                     |               create_elasticache_backup
%%%                     |                   copy_backup_to_s3
%%%                     |               delete_elasticache_backups
%%%           **copy_backup_to_s3**                |
%%%                     |                          |
%%%                     v                          v
%%%         
%%% At the **** point, process A's elasticache backup will have already been
%%% deleted by process B's call to delete_elasticache_backups, so ****** will
%%% have nothing to copy. having a gen_server for backups will avoid this.
%%% 
%%%=============================================================================
%%% BEGIN HEADER
%%%=============================================================================

-module(mod_backup).
-author('ethan').
-behaviour(gen_mod).

-include("logger.hrl").
-include("time.hrl").

%%%=============================================================================
%%% END HEADER
%%%=============================================================================
%%% BEGIN MACROS
%%%=============================================================================

-define(REGION, "us-east-1").
-define(BACKUP_BUCKET, "ha-redis-backups").
-define(SHORT_TERM_FOLDER, "short-term").
-define(LONG_TERM_FOLDER, "long-term").
-define(LAST_BACKUP_START_KEY, <<"last-backup">>).
-define(LAST_DAILY_BACKUP_START_KEY, <<"last-daily-backup">>).
-define(METADATA_EXTENSION, "-metadata.json").
-define(DAILY_BACKUP_INTERVAL, 1 * ?DAYS).
-define(AWS_RETRY_WINDOW, 15 * ?SECONDS_MS).
-define(MAX_WAIT_RETRIES, 500). %% 2 hours, 5 minutes
-define(NUM_BACKUPS_WARNING_THRESHOLD, 47).
%% TODO: determine a good warning threshold
-define(MIN_BACKUP_SIZE_WARNING_THRESHOLD, 10 * 1024). %% 10KB

%%%=============================================================================
%%% END MACROS
%%%=============================================================================
%%% BEGIN EXPORTS
%%%=============================================================================

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1, depends/2]).

%% api
-export([
    schedule_all/0,
    schedule/1,
    unschedule_all/0,
    unschedule/1,
    backup_redis/1,
    health_check_redis_backups/1
]).

%%%=============================================================================
%%% END EXPORTS
%%%=============================================================================
%%% BEGIN GEN_MOD CALLBACKS
%%%=============================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    case util_aws:get_machine_name() of
        <<"s-test">> ->
            schedule_all();
        _ ->
            ok
    end,
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    case util_aws:get_machine_name() of
        <<"s-test">> ->
            unschedule_all();
        _ ->
            ok
    end,
    ok.


depends(_Host, _Opts) ->
    [].


mod_options(_Host) ->
    [].

%%%=============================================================================
%%% END GEN_MOD CALLBACKS
%%%=============================================================================
%%% BEGIN API
%%%=============================================================================

%% @doc Schedule automated backups for all production Redis Clusters
-spec schedule_all() -> ok.
schedule_all() ->
    RedisIds = get_redis_ids(),
    lists:foreach(fun schedule/1, RedisIds).


%% @doc Schedule automated backups a specific Redis Cluster
-spec schedule(RedisId :: string()) -> ok.
schedule(RedisId) ->
    BackupJobRef = list_to_atom(RedisId ++ "_backup"),
    HealthCheckJobRef = list_to_atom(RedisId ++ "_health_check"),
    erlcron:cron(BackupJobRef, {
        {daily, {every, {2, hr}}},
        {?MODULE, backup_redis, [RedisId]}
    }),
    erlcron:cron(HealthCheckJobRef, {
        {daily, {every, {2, hr}}},
        {?MODULE, health_check_redis_backups, [RedisId]}
    }),
    ok.


%% @doc Unschedule automated backups for all production Redis Clusters
-spec unschedule_all() -> ok.
unschedule_all() ->
    RedisIds = get_redis_ids(),
    lists:foreach(fun unschedule/1, RedisIds),
    ok.


%% @doc Unschedule automated backups a specific Redis Cluster
-spec unschedule(RedisId :: string()) -> ok.
unschedule(RedisId) ->
    BackupJobRef = list_to_atom(RedisId ++ "_backup"),
    HealthCheckJobRef = list_to_atom(RedisId ++ "_health_check"),
    erlcron:cancel(BackupJobRef),
    erlcron:cancel(HealthCheckJobRef),
    ok.


%% @doc Attempt to perform a backup on the specified Redis Cluster. 
-spec backup_redis(RedisId :: string()) -> ok.
backup_redis(RedisId) ->
    try
        RedisMetadata = get_redis_metadata(RedisId),
        Now = util:now(),
        log_last_backup(RedisId, Now, RedisMetadata),
        {Folder, RedisMetadata2} = folder_and_new_backup_times(RedisId, Now, RedisMetadata),
        case redis_status(RedisId) of
            <<"available">> ->
                ?INFO("[~p] Performing backup", [RedisId]),
                BackupName = create_elasticache_backup(RedisId),
                copy_backup_to_s3(Folder, BackupName),
                put_redis_metadata(RedisId, RedisMetadata2),
                delete_elasticache_backups(RedisId),
                stat:count("HA/backups", "successful_backups", 1,
                        [{redis, RedisId}, {storage_time, Folder}]);
            Status ->
                ?ERROR("[~p] Skipping backup. Status: ~p", [RedisId, Status]),
                %% TODO(@ethan): use alerts.erl to send an alert
                stat:count("HA/backups", "unsuccessful_backups", 1,
                        [{redis, RedisId},{storage_time, Folder}])
        end
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("[~p] Backup Failed. Stacktrace: ~p", [RedisId,
                    lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    ok.


%% @doc Get the number of backups and the sizes of all backups for the
%%   specified Redis Cluster
-spec health_check_redis_backups(RedisId :: string()) -> ok.
health_check_redis_backups(RedisId) ->
    try
        ShortTermObjects = get_objects_with_prefix(make_path([?SHORT_TERM_FOLDER, RedisId])),
        LongTermObjects = get_objects_with_prefix(make_path([?LONG_TERM_FOLDER, RedisId])),
        AllObjects = lists:append(ShortTermObjects, LongTermObjects),
        BackupSizeMap = objects_to_backup_size_map(AllObjects),
        NumUniqueBackups = maps:size(BackupSizeMap),
        ?INFO("BackupSizeMap: ~p~n", [BackupSizeMap]),
        stat:gauge("HA/backups", "num_backups", NumUniqueBackups,
                [{redis, RedisId}]),
        case NumUniqueBackups < ?NUM_BACKUPS_WARNING_THRESHOLD of
            true ->
                %% TODO(@ethan): use alerts.erl to send an alert
                %% TODO: change INFO to ERROR on september 6 2021
                ?INFO("[~p] currently has ~p backups in S3",
                        [RedisId, NumUniqueBackups]);
            false ->
                ?INFO("[~p] currently has ~p backups in S3",
                        [RedisId, NumUniqueBackups])
        end,
        maps:map(
            fun(BackupName, Size) ->
                case Size < ?MIN_BACKUP_SIZE_WARNING_THRESHOLD of
                    true ->
                        %% TODO(@ethan): use alerts.erl to send an alert
                        ?ERROR("[~p] Backup ~p is only ~p bytes",
                                [RedisId, BackupName, Size]);
                    false ->
                        ok
                end
            end, BackupSizeMap)
    catch
        error:Reason:Stacktrace ->
            ?ERROR("[~p] Backup Failed. Reason: ~p, Stacktrace: ~p", [RedisId,
                    Reason, Stacktrace])
    end,
    ok.

%%%=============================================================================
%%% END API
%%%=============================================================================
%%% BEGIN INTERNAL FUNCITONS
%%%=============================================================================

-spec create_elasticache_backup(RedisId :: string()) -> string().
create_elasticache_backup(RedisId) ->
    BackupName = generate_backup_name(RedisId),
    create_elasticache_backup(RedisId, BackupName).


%% @doc Create a backup of a Redis Cluster in elasticache. Blocks until the
%%   backup is available, up to 2 hours, 5 minutes.
%% @end
-spec create_elasticache_backup(RedisId :: string(), BackupId :: string()) -> string().
create_elasticache_backup(RedisId, BackupName) ->
    CreateBackupJson = util_aws:run_command([
            "elasticache", "create-snapshot",
            "--replication-group-id", RedisId,
            "--snapshot-name", BackupName,
            "--region", ?REGION], [enforce_json]),
    ?INFO("~p~n", [CreateBackupJson]),
    wait_until_backup_is_available(BackupName),
    ?INFO("Backup of ~p created at ~p", [RedisId, BackupName]),
    BackupName.


%% @doc Copy a backup and its metadata to S3.
%%   @param Folder The storage class (can be "short-term" or "long-term"). AWS
%%     is configured to expire objects after 2 days for short-term, and 29 days
%%     for long-term.
%%   @param Backup The name of the backup in elasticache
%% @end
-spec copy_backup_to_s3(Folder :: string(), BackupName :: string()) -> ok.
copy_backup_to_s3(Folder, BackupName) ->
    BackupPath = make_path([Folder, BackupName]),
    %% Get the metadata for this backup. This includes: name, status, source,
    %%   cache node type, engine, engine version, preferred availability zone,
    %%   cluster create time, preferred maintenance window, port, vpc id,
    %%   snapshot window, and node group configuration
    BackupMetadata = util_aws:run_command([
            "elasticache", "describe-snapshots",
            "--snapshot-name", BackupName,
            "--snapshot-source", "user",
            "--show-node-group-config",
            "--region", ?REGION], [enforce_json]),
    ?INFO("~p~n", [BackupMetadata]),
    %% Copy the backup to s3. One file will be created for each shard in the
    %%   cluster, i.e. if there are three shards, three files will be created
    %%   in s3: backup-0001.rdb, backup-0002.rdb, backup-0003.rdb
    CopyBackupJson = util_aws:run_command([
            "elasticache", "copy-snapshot",
            "--source-snapshot-name", BackupName,
            "--target-snapshot-name", BackupPath,
            "--target-bucket", ?BACKUP_BUCKET,
            "--region", ?REGION], [enforce_json]),
    ?INFO("~p~n", [CopyBackupJson]),
    %% Snapshot is in "exporting" status while copying to s3 - need to wait until
    %%   it is available so we can safely delete the snapshot from elasticache
    wait_until_backup_is_available(BackupName),
    %% Copy the backup's metadata to s3
    BackupMetadataPath = BackupPath ++ ?METADATA_EXTENSION,
    erlcloud_s3:put_object(?BACKUP_BUCKET, BackupMetadataPath, jiffy:encode(BackupMetadata)),
    ?INFO("Copied ~p to s3", [BackupName]),
    ok.


%% @doc Delete all manual elasticache backups.
%%   This function also serves as a garbage collector for previously failed
%%   backups, as it deletes all manual backups for the specified Redis Cluster
%%   from elasticache. Note: there is no way to automatically expire manual
%%   snapshots on AWS, so they must be manually deleted.
%% @end
-spec delete_elasticache_backups(RedisId :: string()) -> ok.
delete_elasticache_backups(RedisId) ->
    %% Get the metadata for all manual backups stored in elasticache. Backups
    %%   automatically taken by elasticache are omitted.
    Json = util_aws:run_command([
            "elasticache", "describe-snapshots",
            "--replication-group-id", RedisId,
            "--snapshot-source", "user",
            "--show-node-group-config",
            "--region", ?REGION], [enforce_json]),
    BackupMetadataList = maps:get(<<"Snapshots">>, Json),
    case length(BackupMetadataList) of
        0 ->
            ?ERROR("No backups to delete");
        1 ->
            ok;
        NumBackups ->
            ?ERROR("~p manual backups for ~p in elasticache to be deleted: ~p",
                    [NumBackups, RedisId, BackupMetadataList])
    end,
    lists:foreach(
        fun(BackupMetadata) ->
            BackupName = maps:get(<<"SnapshotName">>, BackupMetadata),
            DeleteSnapshotJson = util_aws:run_command([
                    "elasticache", "delete-snapshot",
                    "--snapshot-name", binary_to_list(BackupName),
                    "--region", ?REGION], [enforce_json]),
            ?INFO("~p~n", [DeleteSnapshotJson]),
            ?INFO("Deleted ~p from elasticache", [BackupName])
        end, BackupMetadataList),
    ok.


%% @doc Get the status of a Redis Cluser. Can return: <<"creating">>,
%%   <<"available">>, <<"modifying">>, <<"create-failed">>, <<"deleting">>, or
%%   <<"snapshotting">>. 
%% @end
-spec redis_status(RedisId :: string()) -> binary().
redis_status(RedisId) ->
    Json = util_aws:run_command([
            "elasticache", "describe-replication-groups",
            "--replication-group-id", RedisId,
            "--region", ?REGION], [enforce_json]),
    [Json2] = maps:get(<<"ReplicationGroups">>, Json),
    maps:get(<<"Status">>, Json2).


%% @doc Get the status of an elasticache backup. Can return: <<"creating">>,
%%   <<"available">>, <<"restoring">>, <<"copying">>, <<"exporting">>, or
%%   <<"deleting">>. 
%% @end
-spec backup_status(BackupName :: string()) -> binary().
backup_status(BackupName) ->
    Json = util_aws:run_command([
        "elasticache", "describe-snapshots",
        "--snapshot-name", BackupName,
        "--snapshot-source", "user",
        "--show-node-group-config",
        "--region", ?REGION], [enforce_json]),
    case maps:get(<<"Snapshots">>, Json) of
        [] ->
            ?ERROR("Backup ~p does not exist in elasticache", [BackupName]),
            error(backup_nonexistent_error, [BackupName]);
        [Json2] ->
            maps:get(<<"SnapshotStatus">>, Json2)
    end.


-spec wait_until_backup_is_available(BackupName :: string()) -> ok.
wait_until_backup_is_available(BackupName) ->
    wait_until_backup_is_available(BackupName, 0).


%% @doc Spin until Backup is available (up to 2 hours, 5 minutes).
-spec wait_until_backup_is_available(BackupName :: string(), Retries :: integer()) -> ok.
wait_until_backup_is_available(BackupName, ?MAX_WAIT_RETRIES) ->
    ?ERROR("Max wait retries reached for backup ~p", [BackupName]),
    error(backup_unavailable_error, [BackupName, ?MAX_WAIT_RETRIES]);
wait_until_backup_is_available(BackupName, Retries) ->
    BackupStatus = backup_status(BackupName),
    case BackupStatus of
        <<"available">> ->
            ok;
        _SnapshotStatus ->
            timer:sleep(?AWS_RETRY_WINDOW),
            wait_until_backup_is_available(BackupName, Retries + 1)
    end.


%% @doc Get all S3 objects that begin with Prefix. Used to get objects within
%%   specific folders in S3.
-spec get_objects_with_prefix(Prefix :: string()) -> proplists:proplist().
get_objects_with_prefix(Prefix) ->
    ?INFO("Getting objects with prefix ~p", [Prefix]),
    Options = [{prefix, Prefix}],
    Response = erlcloud_s3:list_objects(?BACKUP_BUCKET, Options),
    proplists:get_value(contents, Response).


-spec log_last_backup(RedisId :: string(), Now :: integer(), Metadata :: maps:map()) -> ok.
log_last_backup(RedisId, Now, Metadata) ->
    LastBackup = maps:get(?LAST_BACKUP_START_KEY, Metadata, 0),
    TimeSinceLastBackup = Now - LastBackup,
    {Days, Hours, Minutes, Seconds} = humanize_time(TimeSinceLastBackup),
    case TimeSinceLastBackup > ?DAILY_BACKUP_INTERVAL of
        true ->
            ?ERROR("[~p] Time since last hourly backup: ~p days, "
                ++ "~p:~p:~p", [RedisId, Days, Hours, Minutes, Seconds]);
        false ->
            ?INFO("[~p] Time since last hourly backup: ~p days, "
                ++ "~p:~p:~p", [RedisId, Days, Hours, Minutes, Seconds])
    end.


-spec folder_and_new_backup_times(RedisId :: string(), Now :: integer(), Metadata :: maps:map()) ->
        {string, maps:map()}.
folder_and_new_backup_times(RedisId, Now, Metadata) ->
    LastDailyBackup = maps:get(?LAST_DAILY_BACKUP_START_KEY, Metadata, 0),
    TimeSinceLastDailyBackup = Now - LastDailyBackup,
    {Days, Hours, Minutes, Seconds} = humanize_time(TimeSinceLastDailyBackup),
    ?INFO("[~p] Time since last daily backup: ~p days, ~p:~p:~p",
            [RedisId, Days, Hours, Minutes, Seconds]),
    case TimeSinceLastDailyBackup > ?DAILY_BACKUP_INTERVAL of
        true ->
            ?INFO("[~p] Backup type needed: Long term", [RedisId]),
            {?LONG_TERM_FOLDER, Metadata#{?LAST_BACKUP_START_KEY => Now, 
                    ?LAST_DAILY_BACKUP_START_KEY => Now}};
        false ->
            ?INFO("[~p] Backup type needed: Short term", [RedisId]),
            {?SHORT_TERM_FOLDER, Metadata#{?LAST_BACKUP_START_KEY => Now}}
    end.


-spec objects_to_backup_size_map(Objects :: [proplists:proplist()]) -> maps:map().
objects_to_backup_size_map(Objects) ->
    lists:foldl(
        fun(Object, Backups) ->
            Key = proplists:get_value(key, Object),
            [BackupName, _Rest] = string:split(Key, "-", trailing),
            Size = proplists:get_value(size, Object),
            maps:update_with(BackupName, fun(V) -> V + Size end, Size, Backups)
        end, maps:new(), Objects).


-spec get_redis_metadata(RedisId :: string()) -> maps:map().
get_redis_metadata(RedisId) ->
    try
        RedisMetadataPath = RedisId ++ ?METADATA_EXTENSION,
        Response = erlcloud_s3:get_object(?BACKUP_BUCKET, RedisMetadataPath),
        JsonEncoded = proplists:get_value(content, Response),
        jiffy:decode(JsonEncoded, [return_maps])
    catch
        _Class:_Reason:_Stacktace ->
            ?ERROR("[~p] Redis metadata not present or malformed. Creating new metadata object",
                    [RedisId]),
            maps:new()
    end.


-spec put_redis_metadata(RedisId :: string(), RedisMetadata :: maps:map()) -> ok.
put_redis_metadata(RedisId, RedisMetadata) ->
    RedisMetadataPath = RedisId ++ ?METADATA_EXTENSION,
    erlcloud_s3:put_object(?BACKUP_BUCKET, RedisMetadataPath, jiffy:encode(RedisMetadata)).


%% TODO(@ethan): move this into redis_sup
-spec get_redises() -> [atom()].
get_redises() ->
    [
        % redis_accounts,
        % redis_auth,
        % redis_contacts,
        % redis_feed,
        % redis_groups,
        % redis_messages,
        % redis_phone,
        redis_sessions,
        redis_whisper
    ].


-spec get_redis_ids() -> [string()].
get_redis_ids() ->
    case config:is_prod_env() of
        true ->
            Redises = get_redises(),
            lists:map(
                fun(RedisAtom) ->
                    {RedisAtom, Host, _Port} = config:get_service(RedisAtom),
                    [RedisId, _Rest] = string:split(Host, "."),
                    RedisId
                end, Redises);
        false ->
            ["redis-dr-test"]
    end.


-spec generate_backup_name(RedisId :: string()) -> string().
generate_backup_name(RedisId) ->
    Now = util:now_prettystring(),
    util:join_strings([RedisId, Now], "-").


-spec make_path(Components :: [string()]) -> string().
make_path(Components) ->
    util:join_strings(Components, "/").


-spec humanize_time(Time :: integer()) -> string().
humanize_time(Time) ->
    Days = Time div ?DAYS,
    Time2 = Time rem ?DAYS,
    Hours = Time2 div ?HOURS,
    Time3 = Time2 rem ?HOURS,
    Minutes = Time3 div ?MINUTES,
    Seconds = Time3 rem ?MINUTES,
    {Days, Hours, Minutes, Seconds}.

%%%=============================================================================
%%% END INTERNAL FUNCITONS
%%%=============================================================================

