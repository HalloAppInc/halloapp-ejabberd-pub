
%%%=============================================================================
%%% File: mod_backup_tests.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Tests for mod_backup.erl
%%% 
%%%=============================================================================
%%% BEGIN HEADER
%%%=============================================================================

-module(mod_backup_tests).
-author('ethan').

-include_lib("eunit/include/eunit.hrl").

%%%=============================================================================
%%% END HEADER
%%%=============================================================================
%%% BEGIN MACROS
%%%=============================================================================

-define(REDIS_TEST, "redis-dr-test").
-define(BACKUP_BUCKET, "ha-redis-backups").
-define(NUM_SHARDS, 3).
-define(REGION, "us-east-1").
-define(SHORT_TERM, "short-term").
-define(LONG_TERM, "long-term").

%%%=============================================================================
%%% END MACROS
%%%=============================================================================
%%% BEGIN MOCK DATABASES
%%%=============================================================================

database_list() ->
    [elasticache, s3, redises].


create_mock_databases() ->
    [ets:new(Table, [named_table, public]) || Table <- database_list()].


seed_redises() ->
    ets:insert(redises, {?REDIS_TEST, ok}).


seed_s3() ->
    Metadata = maps:from_list([{<<"last-daily-backup">>, 0}]),
    ets:insert(s3, {"redis-dr-test/metadata.json", jiffy:encode(Metadata)}).


destroy_mock_databases() ->
    [ets:delete(Table) || Table <- database_list()].

%%%=============================================================================
%%% END MOCK DATABASES
%%%=============================================================================
%%% BEGIN MOCK FUNCTIONS
%%%=============================================================================

%% metadata_get
mock_erlcloud_s3_get_object(?BACKUP_BUCKET, Key) ->
    %% erlcloud_s3 asserts that the object exists
    try
        assert_key_exists(s3, Key),
        [{Key, Data}] = ets:lookup(s3, Key),
        %% erlcloud returns a proplist with metadata - since we just ignore
        %% it all, it is omitted here - we only want the content
        [{content, Data}]
    catch
        error : {badmatch, []} ->
            %% the first time this function is run, there will be nothing
            %% in s3 to get, so the code will throw an error. this is intended
            %% and is handled by the true code (in mod_backup:get_last_backup_time).
            %% here, we let meck know that this exception is allowable which will
            %% allow the function to be validated successfully at teardown.
            meck:exception(error, {badmatch, []});
        Class : Reason : Stacktrace ->
            ?debugFmt("Unexpected exception (~p): ~p, ~p", [Class, Reason, Stacktrace])
    end.

%% metadata_put
mock_erlcloud_s3_put_object(?BACKUP_BUCKET, Key, Data) ->
    ets:insert(s3, {Key, Data}).


%% get_keys_with_prefix
mock_erlcloud_s3_list_objects(?BACKUP_BUCKET, [{prefix, Prefix}]) ->
    AllKeys = get_all_objects(s3),
    Contents = lists:foldl(
        fun(Key, MockObjects) ->
            case lists:prefix(Prefix, Key) of
                true ->
                    MockObject = mock_object_metadata(Key, 200),
                    [MockObject | MockObjects];
                false ->
                    MockObjects
            end
        end, [], AllKeys),
    [{contents, Contents}].

%% create_elasticache_backup
mock_run_command([
        "elasticache", "create-snapshot",
        "--replication-group-id", _Redis,
        "--snapshot-name", Backup,
        "--region", ?REGION], [enforce_json]) ->
    %% AWS asserts that all backup names are unique
    assert_key_not_exists(elasticache, Backup),
    ets:insert(elasticache, {Backup, ok}),
    mock_create_snapshot();

%% copy_backup_to_s3
mock_run_command([
        "elasticache", "copy-snapshot",
        "--source-snapshot-name", Backup,
        "--target-snapshot-name", Path,
        "--target-bucket", ?BACKUP_BUCKET,
        "--region", ?REGION], [enforce_json]) ->
    %% AWS asserts that the backup exists in elasticache
    assert_key_exists(elasticache, Backup),
    %% AWS asserts that all key names are unique
    assert_key_not_exists(s3, Path),
    [ets:insert(s3, {Key, ok}) || Key <- generate_expected_keys_list(Path)],
    mock_copy_backup_to_s3();

%% delete_elasticache_backups
mock_run_command([
        "elasticache", "delete-snapshot",
        "--snapshot-name", Backup,
        "--region", ?REGION], [enforce_json]) ->
    %% AWS asserts that the backup exists in elasticache
    assert_key_exists(elasticache, Backup),
    ets:delete(elasticache, Backup),
    mock_delete_snapshots();

%% backup_status
mock_run_command([
        "elasticache", "describe-snapshots",
        "--snapshot-name", Backup,
        "--snapshot-source", "user",
        "--show-node-group-config",
        "--region", ?REGION], [enforce_json]) ->
    case ets:lookup(elasticache, Backup) of
        [{Backup, ok}] ->
            mock_describe_snapshots();
        [] ->
            mock_describe_snapshots_empty()
    end;

%% delete_elasticache_snapshots
mock_run_command([
        "elasticache", "describe-snapshots",
        "--replication-group-id", _Redis,
        "--snapshot-source", "user",
        "--show-node-group-config",
        "--region", ?REGION], [enforce_json]) ->
    mock_describe_snapshots();

%% redis_status
mock_run_command([
        "elasticache", "describe-replication-groups",
        "--replication-group-id", Redis,
        "--region", ?REGION], [enforce_json]) ->
    %% AWS asserts that the replication group exists
    assert_key_exists(redises, Redis),
    mock_describe_replication_groups().

%%%=============================================================================
%%% END MOCK FUNCTIONS 
%%%=============================================================================
%%% BEGIN MOCK DATA
%%%=============================================================================

mock_create_snapshot() ->
    #{<<"Snapshot">> =>
      #{<<"ARN">> =>
            <<"arn:aws:elasticache:us-west-1:356247613230:snapshot:redis-dr-test-2021-07-26-23-36-39">>,
        <<"AutoMinorVersionUpgrade">> => true,
        <<"AutomaticFailover">> => <<"enabled">>,
        <<"CacheNodeType">> => <<"cache.t3.micro">>,
        <<"CacheParameterGroupName">> => <<"default.redis6.x.cluster.on">>,
        <<"CacheSubnetGroupName">> => <<"default">>,
        <<"Engine">> => <<"redis">>,<<"EngineVersion">> => <<"6.0.5">>,
        <<"NodeSnapshots">> =>
            [#{<<"CacheSize">> => <<>>,<<"NodeGroupId">> => <<"0001">>},
             #{<<"CacheSize">> => <<>>,<<"NodeGroupId">> => <<"0002">>},
             #{<<"CacheSize">> => <<>>,<<"NodeGroupId">> => <<"0003">>}],
        <<"NumNodeGroups">> => 3,<<"Port">> => 6379,
        <<"PreferredMaintenanceWindow">> => <<"mon:12:30-mon:13:30">>,
        <<"ReplicationGroupDescription">> => <<"test redis dr">>,
        <<"ReplicationGroupId">> => <<"redis-dr-test">>,
        <<"SnapshotName">> => <<"redis-dr-test-2021-07-26-23-36-39">>,
        <<"SnapshotRetentionLimit">> => 0, 
        <<"SnapshotSource">> => <<"manual">>,
        <<"SnapshotStatus">> => <<"creating">>,
        <<"SnapshotWindow">> => <<"10:00-11:00">>,
        <<"VpcId">> => <<"vpc-57f5e430">>}}.

mock_copy_backup_to_s3() ->
    #{<<"Snapshot">> =>
      #{<<"ARN">> =>
            <<"arn:aws:elasticache:us-west-1:356247613230:snapshot:redis-dr-test-2021-07-26-23-36-39">>,
        <<"AutoMinorVersionUpgrade">> => true,
        <<"AutomaticFailover">> => <<"enabled">>,
        <<"CacheNodeType">> => <<"cache.t3.micro">>,
        <<"CacheParameterGroupName">> => <<"default.redis6.x.cluster.on">>,
        <<"CacheSubnetGroupName">> => <<"default">>,
        <<"Engine">> => <<"redis">>,<<"EngineVersion">> => <<"6.0.5">>,
        <<"NodeSnapshots">> =>
            [#{<<"CacheClusterId">> => <<"redis-dr-test-0001-003">>,
               <<"CacheNodeCreateTime">> =>
                   <<"2021-07-26T22:56:55.421000+00:00">>,
               <<"CacheNodeId">> => <<"0001">>,<<"CacheSize">> => <<"6 MB">>,
               <<"NodeGroupId">> => <<"0001">>,
               <<"SnapshotCreateTime">> => <<"2021-07-26T23:36:56+00:00">>},
             #{<<"CacheClusterId">> => <<"redis-dr-test-0002-002">>,
               <<"CacheNodeCreateTime">> =>
                   <<"2021-07-26T22:56:55.421000+00:00">>,
               <<"CacheNodeId">> => <<"0001">>,<<"CacheSize">> => <<"6 MB">>,
               <<"NodeGroupId">> => <<"0002">>,
               <<"SnapshotCreateTime">> => <<"2021-07-26T23:36:56+00:00">>},
             #{<<"CacheClusterId">> => <<"redis-dr-test-0003-003">>,
               <<"CacheNodeCreateTime">> =>
                   <<"2021-07-26T22:56:55.421000+00:00">>,
               <<"CacheNodeId">> => <<"0001">>,<<"CacheSize">> => <<"6 MB">>,
               <<"NodeGroupId">> => <<"0003">>,
               <<"SnapshotCreateTime">> => <<"2021-07-26T23:36:56+00:00">>}],
        <<"NumNodeGroups">> => 3,<<"Port">> => 6379,
        <<"PreferredMaintenanceWindow">> => <<"mon:12:30-mon:13:30">>,
        <<"ReplicationGroupDescription">> => <<"test redis dr">>,
        <<"ReplicationGroupId">> => <<"redis-dr-test">>,
        <<"SnapshotName">> => <<"redis-dr-test-2021-07-26-23-36-39">>,
        <<"SnapshotRetentionLimit">> => 0,
        <<"SnapshotSource">> => <<"manual">>,
        <<"SnapshotStatus">> => <<"exporting">>,
        <<"SnapshotWindow">> => <<"10:00-11:00">>,
        <<"VpcId">> => <<"vpc-57f5e430">>}}.


mock_delete_snapshots() ->
    #{<<"Snapshot">> =>
      #{<<"ARN">> =>
            <<"arn:aws:elasticache:us-west-1:356247613230:snapshot:redis-dr-test-2021-07-26-23-53-22">>,
        <<"AutoMinorVersionUpgrade">> => true,
        <<"AutomaticFailover">> => <<"enabled">>,
        <<"CacheNodeType">> => <<"cache.t3.micro">>,
        <<"CacheParameterGroupName">> => <<"default.redis6.x.cluster.on">>,
        <<"CacheSubnetGroupName">> => <<"default">>,
        <<"Engine">> => <<"redis">>,<<"EngineVersion">> => <<"6.0.5">>,
        <<"NodeSnapshots">> =>
            [#{<<"CacheClusterId">> => <<"redis-dr-test-0001-003">>,
               <<"CacheNodeCreateTime">> =>
                   <<"2021-07-26T22:56:55.421000+00:00">>,
               <<"CacheNodeId">> => <<"0001">>,<<"CacheSize">> => <<"6 MB">>,
               <<"NodeGroupId">> => <<"0001">>,
               <<"SnapshotCreateTime">> => <<"2021-07-26T23:53:45+00:00">>},
             #{<<"CacheClusterId">> => <<"redis-dr-test-0002-003">>,
               <<"CacheNodeCreateTime">> =>
                   <<"2021-07-26T22:56:55.421000+00:00">>,
               <<"CacheNodeId">> => <<"0001">>,<<"CacheSize">> => <<"6 MB">>,
               <<"NodeGroupId">> => <<"0002">>,
               <<"SnapshotCreateTime">> => <<"2021-07-26T23:53:45+00:00">>},
             #{<<"CacheClusterId">> => <<"redis-dr-test-0003-002">>,
               <<"CacheNodeCreateTime">> =>
                   <<"2021-07-26T22:56:55.421000+00:00">>,
               <<"CacheNodeId">> => <<"0001">>,<<"CacheSize">> => <<"6 MB">>,
               <<"NodeGroupId">> => <<"0003">>,
               <<"SnapshotCreateTime">> => <<"2021-07-26T23:53:45+00:00">>}],
        <<"NumNodeGroups">> => 3,<<"Port">> => 6379,
        <<"PreferredMaintenanceWindow">> => <<"mon:12:30-mon:13:30">>,
        <<"ReplicationGroupDescription">> => <<"test redis dr">>,
        <<"ReplicationGroupId">> => <<"redis-dr-test">>,
        <<"SnapshotName">> => <<"redis-dr-test-2021-07-26-23-53-22">>,
        <<"SnapshotRetentionLimit">> => 0,
        <<"SnapshotSource">> => <<"manual">>,
        <<"SnapshotStatus">> => <<"deleting">>,
        <<"SnapshotWindow">> => <<"10:00-11:00">>,
        <<"VpcId">> => <<"vpc-57f5e430">>}}.


mock_describe_snapshots() ->
    #{<<"Snapshots">> =>
      [#{<<"ARN">> =>
             <<"arn:aws:elasticache:us-west-1:356247613230:snapshot:redis-dr-test-2021-07-14-22-07-32">>,
         <<"AutoMinorVersionUpgrade">> => true,
         <<"AutomaticFailover">> => <<"enabled">>,
         <<"CacheNodeType">> => <<"cache.t3.micro">>,
         <<"CacheParameterGroupName">> => <<"default.redis6.x.cluster.on">>, 
         <<"CacheSubnetGroupName">> => <<"default">>,
         <<"Engine">> => <<"redis">>,<<"EngineVersion">> => <<"6.0.5">>,
         <<"NodeSnapshots">> =>
             [#{<<"CacheClusterId">> => <<"redis-dr-test-0001-003">>,
                <<"CacheNodeCreateTime">> =>
                    <<"2021-07-14T21:19:43.126000+00:00">>,
                <<"CacheNodeId">> => <<"0001">>,<<"CacheSize">> => <<"6 MB">>,
                <<"NodeGroupConfiguration">> =>
                    #{<<"PrimaryAvailabilityZone">> => <<"us-west-1a">>,
                      <<"ReplicaAvailabilityZones">> =>
                          [<<"us-west-1a">>,<<"us-west-1c">>],
                      <<"ReplicaCount">> => 2,<<"Slots">> => <<"0-5461">>},
                <<"NodeGroupId">> => <<"0001">>,
                <<"SnapshotCreateTime">> => <<"2021-07-14T22:07:39+00:00">>},
              #{<<"CacheClusterId">> => <<"redis-dr-test-0002-002">>,
                <<"CacheNodeCreateTime">> =>
                    <<"2021-07-14T21:19:43.126000+00:00">>,
                <<"CacheNodeId">> => <<"0001">>,<<"CacheSize">> => <<"6 MB">>,
                <<"NodeGroupConfiguration">> =>
                    #{<<"PrimaryAvailabilityZone">> => <<"us-west-1a">>,
                      <<"ReplicaAvailabilityZones">> =>
                          [<<"us-west-1c">>,<<"us-west-1c">>],
                      <<"ReplicaCount">> => 2,<<"Slots">> => <<"5462-10922">>},
                <<"NodeGroupId">> => <<"0002">>,
                <<"SnapshotCreateTime">> => <<"2021-07-14T22:07:39+00:00">>},
              #{<<"CacheClusterId">> => <<"redis-dr-test-0003-003">>,
                <<"CacheNodeCreateTime">> =>
                    <<"2021-07-14T21:19:43.126000+00:00">>,
                <<"CacheNodeId">> => <<"0001">>,<<"CacheSize">> => <<"6 MB">>,
                <<"NodeGroupConfiguration">> =>
                    #{<<"PrimaryAvailabilityZone">> => <<"us-west-1a">>,
                      <<"ReplicaAvailabilityZones">> =>
                          [<<"us-west-1a">>,<<"us-west-1c">>],
                      <<"ReplicaCount">> => 2,
                      <<"Slots">> => <<"10923-16383">>},
                <<"NodeGroupId">> => <<"0003">>,
                <<"SnapshotCreateTime">> => <<"2021-07-14T22:07:39+00:00">>}],
         <<"NumNodeGroups">> => 3,<<"Port">> => 6379,
         <<"PreferredMaintenanceWindow">> => <<"sat:10:30-sat:11:30">>,
         <<"ReplicationGroupDescription">> => <<"test redis dr">>,
         <<"ReplicationGroupId">> => <<?REDIS_TEST>>,
         <<"SnapshotName">> => <<"redis-dr-test-2021-07-14-22-07-32">>,
         <<"SnapshotRetentionLimit">> => 0,
         <<"SnapshotSource">> => <<"manual">>,
         <<"SnapshotStatus">> => <<"available">>,
         <<"SnapshotWindow">> => <<"09:00-10:00">>,
         <<"VpcId">> => <<"vpc-57f5e430">>}]}.


mock_describe_snapshots_empty() ->
    #{<<"Snapshots">> => []}.


mock_describe_replication_groups() ->
    #{<<"ReplicationGroups">> =>
      [#{<<"ARN">> =>
             <<"arn:aws:elasticache:us-west-1:356247613230:replicationgroup:redis-dr-test">>,
         <<"AtRestEncryptionEnabled">> => false,
         <<"AuthTokenEnabled">> => false,
         <<"AutomaticFailover">> => <<"enabled">>,
         <<"CacheNodeType">> => <<"cache.t3.micro">>,
         <<"ClusterEnabled">> => true, 
         <<"ConfigurationEndpoint">> =>
             #{<<"Address">> =>
                   <<"redis-dr-test.rnhy4b.clustercfg.usw1.cache.amazonaws.com">>,
               <<"Port">> => 6379},
         <<"Description">> => <<"test redis dr">>,
         <<"GlobalReplicationGroupInfo">> => #{},
         <<"LogDeliveryConfigurations">> => [],
         <<"MemberClusters">> =>
             [<<"redis-dr-test-0001-001">>,<<"redis-dr-test-0001-002">>,
              <<"redis-dr-test-0001-003">>,<<"redis-dr-test-0002-001">>,
              <<"redis-dr-test-0002-002">>,<<"redis-dr-test-0002-003">>,
              <<"redis-dr-test-0003-001">>,<<"redis-dr-test-0003-002">>,
              <<"redis-dr-test-0003-003">>],
         <<"MultiAZ">> => <<"enabled">>,
         <<"NodeGroups">> =>
             [#{<<"NodeGroupId">> => <<"0001">>,
                <<"NodeGroupMembers">> =>
                    [#{<<"CacheClusterId">> => <<"redis-dr-test-0001-001">>,
                       <<"CacheNodeId">> => <<"0001">>,
                       <<"PreferredAvailabilityZone">> => <<"us-west-1a">>},
                     #{<<"CacheClusterId">> => <<"redis-dr-test-0001-002">>,
                       <<"CacheNodeId">> => <<"0001">>,
                       <<"PreferredAvailabilityZone">> => <<"us-west-1a">>},
                     #{<<"CacheClusterId">> => <<"redis-dr-test-0001-003">>,
                       <<"CacheNodeId">> => <<"0001">>,
                       <<"PreferredAvailabilityZone">> => <<"us-west-1c">>}],
                <<"Slots">> => <<"0-5461">>,<<"Status">> => <<"available">>},
              #{<<"NodeGroupId">> => <<"0002">>,
                <<"NodeGroupMembers">> =>
                    [#{<<"CacheClusterId">> => <<"redis-dr-test-0002-001">>,
                       <<"CacheNodeId">> => <<"0001">>,
                       <<"PreferredAvailabilityZone">> => <<"us-west-1a">>},
                     #{<<"CacheClusterId">> => <<"redis-dr-test-0002-002">>,
                       <<"CacheNodeId">> => <<"0001">>,
                       <<"PreferredAvailabilityZone">> => <<"us-west-1c">>},
                     #{<<"CacheClusterId">> => <<"redis-dr-test-0002-003">>,
                       <<"CacheNodeId">> => <<"0001">>,
                       <<"PreferredAvailabilityZone">> => <<"us-west-1c">>}],
                <<"Slots">> => <<"5462-10922">>,
                <<"Status">> => <<"available">>},
              #{<<"NodeGroupId">> => <<"0003">>,
                <<"NodeGroupMembers">> =>
                    [#{<<"CacheClusterId">> => <<"redis-dr-test-0003-001">>,
                       <<"CacheNodeId">> => <<"0001">>,
                       <<"PreferredAvailabilityZone">> => <<"us-west-1a">>},
                     #{<<"CacheClusterId">> => <<"redis-dr-test-0003-002">>,
                       <<"CacheNodeId">> => <<"0001">>,
                       <<"PreferredAvailabilityZone">> => <<"us-west-1c">>},
                     #{<<"CacheClusterId">> => <<"redis-dr-test-0003-003">>,
                       <<"CacheNodeId">> => <<"0001">>,
                       <<"PreferredAvailabilityZone">> => <<"us-west-1a">>}],
                <<"Slots">> => <<"10923-16383">>,
                <<"Status">> => <<"available">>}],
         <<"PendingModifiedValues">> => #{},
         <<"ReplicationGroupId">> => <<?REDIS_TEST>>,
         <<"SnapshotRetentionLimit">> => 0,
         <<"SnapshotWindow">> => <<"09:00-10:00">>,
         <<"Status">> => <<"available">>,
         <<"TransitEncryptionEnabled">> => false}]}.


mock_object_metadata(Key, Size) ->
    [{key, Key},
    {last_modified,{{2021,7,12},{22,5,7}}},
    {etag,"\"fbcff7b6867922290af6c7e5612751f3\""},
    {size, Size},
    {storage_class,"STANDARD"}, 
    {owner,[{id,"540804c33a284a299d2547575ce1010f2312ef3da9b3a053c8bc45bf233e4353"},
            {display_name,"aws-scs-s3-readonly"}]}].

%%%=============================================================================
%%% END MOCK DATA
%%%=============================================================================
%%% BEGIN TESTS
%%%=============================================================================

ensure_short_and_long_term_backups(ok) ->
    mod_backup:backup_redis(?REDIS_TEST),
    %% Sleep to ensure the backups have unique names
    timer:sleep(2000),
    mod_backup:backup_redis(?REDIS_TEST),
    Backups = lists:sort(get_all_objects(s3)),
    ShortTermBackups = lists:filter(
        fun(Object) ->
            lists:prefix("short-term/redis-dr-test", Object)
        end, Backups),
    LongTermBackups = lists:filter(
        fun(Object) ->
            lists:prefix("long-term/redis-dr-test", Object)
        end, Backups),
    mod_backup:health_check_redis_backups(?REDIS_TEST),
    [
        ?_assertEqual(?NUM_SHARDS + 1, length(ShortTermBackups)),
        ?_assertEqual(?NUM_SHARDS + 1, length(LongTermBackups))
    ].


backup_test_() ->
    {setup, fun start/0, fun stop/1, fun ensure_short_and_long_term_backups/1}.

%%%=============================================================================
%%% END TESTS
%%%=============================================================================
%%% BEGIN UTIL FUNCTIONS
%%%=============================================================================

assert_key_exists(Table, Key) ->
    ?_assertMatch([{_, _}], ets:lookup(Table, Key)).


assert_key_not_exists(Table, Key) ->
    ?_assertMatch([], ets:lookup(Table, Key)).


get_all_objects(Table) ->
    lists:append(ets:match(Table, {'$1', '_'})).


start() ->
    tutil:setup(),
    tutil:meck_init(erlcloud_s3, [
        {list_objects, fun mock_erlcloud_s3_list_objects/2},
        {get_object, fun mock_erlcloud_s3_get_object/2},
        {put_object, fun mock_erlcloud_s3_put_object/3}
    ]),
    tutil:meck_init(util_aws, run_command, fun mock_run_command/2),
    create_mock_databases(),
    seed_redises(),
    seed_s3(),
    ok.


stop(ok) ->
    destroy_mock_databases(),
    tutil:meck_finish(erlcloud_s3),
    tutil:meck_finish(util_aws).


generate_expected_keys_list(Path) ->
    [Path ++ "-" ++ io_lib:format("~4..0w", [N]) ++ ".rdb" ||
            N <- lists:seq(1, ?NUM_SHARDS)].

%%%=============================================================================
%%% END UTIL FUNCITONS
%%%=============================================================================

