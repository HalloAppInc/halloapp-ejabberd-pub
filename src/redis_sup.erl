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

    RedisFriends = create_redis_child_spec(redis_friends, redis_friends_client),
    RedisAccounts = create_redis_child_spec(redis_accounts, redis_accounts_client),
    RedisContacts = create_redis_child_spec(redis_contacts, redis_contacts_client),
    RedisAuth = create_redis_child_spec(redis_auth, redis_auth_client),

    {ok, {SupFlags, [
        EredisClusterPool,
        RedisFriends,
        RedisAccounts,
        RedisContacts,
        RedisAuth
    ]}}.

%% TODO: can the 2 atoms be the same?
-spec create_redis_child_spec(
        RedisService :: atom(), RedisServiceClient :: atom()) -> supervisor:child_spec().
create_redis_child_spec(RedisService, RedisServiceClient) ->
    {RedisService, RedisHost, RedisPort} = config:get_service(RedisService),
    ChildSpec = #{
        id => RedisServiceClient,
        start => {eredis_cluster_client, start_link,
            [{RedisServiceClient, [{RedisHost, RedisPort}]}]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [dynamic]},
    ChildSpec.

%%%===================================================================
%%% Internal functions
%%%===================================================================
