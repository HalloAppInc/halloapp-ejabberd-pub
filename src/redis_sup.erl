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

    {redis_friends, Host, Port} = config:get_service(redis_friends),

    RedisFriends = #{
        id => redis_friends_client,
        start => {eredis_cluster_client, start_link, [{redis_friends_client, [{Host, Port}]}]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [dynamic]},

    {ok, {SupFlags, [EredisClusterPool, RedisFriends]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
