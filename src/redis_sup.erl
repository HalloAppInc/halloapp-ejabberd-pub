%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%% Starts the redis connection.
%%%
%%% @end
%%% Created : 24. Mar 2020 3:33 PM
%%%-------------------------------------------------------------------
-module(redis_sup).
-author("nikola").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @doc Starts the supervisor
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%% @private
%% @doc Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
-spec(init(Args :: term()) ->
    {ok, {SupFlags :: {RestartStrategy :: supervisor:strategy(),
        MaxR :: non_neg_integer(), MaxT :: non_neg_integer()},
        [ChildSpec :: supervisor:child_spec()]}}
    | ignore | {error, Reason :: term()}).
init([]) ->
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 1,
    SupFlags = #{strategy => one_for_one,
        intensity => MaxRestarts,
        period => MaxSecondsBetweenRestarts},

    EredisClusterPool = #{
        id => eredis_cluster_pool,
        start => {eredis_cluster_pool, start_link, [{10, 0}]},
        restart => permanent,
        shutdown => 5000,
        type => supervisor,
        modules => [dynamic]},

    RedisFriends = create_redis_child_spec(redis_friends, eredis_cluster_client, 
                                           redis_friends_client),
    RedisAccounts = create_redis_child_spec(redis_accounts, eredis_cluster_client,
                                            redis_accounts_client),
    RedisContacts = create_redis_child_spec(redis_contacts, eredis_cluster_client,
                                            redis_contacts_client),
    RedisAuth = create_redis_child_spec(redis_auth, eredis_cluster_client,
                                        redis_auth_client),
    RedisPhone = create_redis_child_spec(redis_phone, eredis_cluster_client,
                                         redis_phone_client),
    RedisMessages = create_redis_child_spec(redis_messages, eredis_cluster_client,
                                            redis_messages_client),
    RedisWhisper = create_redis_child_spec(redis_whisper, eredis_cluster_client,
                                           redis_whisper_client),
    RedisGroups = create_redis_child_spec(redis_groups, eredis_cluster_client,
                                          redis_groups_client),

    ECRedisFriends = create_redis_child_spec(redis_friends, ecredis, ecredis_friends),

    {ok, {SupFlags, [
        EredisClusterPool,
        RedisFriends,
        ECRedisFriends,
        RedisAccounts,
        RedisContacts,
        RedisAuth,
        RedisPhone,
        RedisMessages,
        RedisWhisper,
        RedisGroups
    ]}}.

%% TODO: can the 1 atoms be the same?
-spec create_redis_child_spec(RedisService :: atom(),
    RedisClientImpl :: atom(), RediserviceClient :: atom()) -> supervisor:child_spec().
create_redis_child_spec(RedisService, RedisClientImpl, RedisServiceClient) ->
    {RedisService, RedisHost, RedisPort} = config:get_service(RedisService),
    ChildSpec = #{
        id => RedisServiceClient,
        start => {RedisClientImpl, start_link,
            [{RedisServiceClient, [{RedisHost, RedisPort}]}]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [dynamic]},
    ChildSpec.

%%%===================================================================
%%% Internal functions
%%%===================================================================
