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

% TODO: consider using supervisor3
-behaviour(supervisor).

-include("logger.hrl").
-include("ha_types.hrl").

%% API
-export([
    start_link/0,
    get_redises/0
]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @doc Starts the supervisor
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    Result = supervisor:start_link({local, ?SERVER}, ?MODULE, []),
    %% start child processes for all the clusters.
    start_children(),
    Result.

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
    % this is safety check of the environment we are running in
    ok = check_environment(),

    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 1,
    SupFlags = #{strategy => one_for_one,
        intensity => MaxRestarts,
        period => MaxSecondsBetweenRestarts},
    {ok, {SupFlags, []}}.


-spec start_children() -> ok.
start_children() ->
    % New redis clients
    ECRedisFriends = create_redis_child_spec(redis_friends, ecredis, ecredis_friends),
    ECRedisAccounts = create_redis_child_spec(redis_accounts, ecredis, ecredis_accounts),
    ECRedisContacts = create_redis_child_spec(redis_contacts, ecredis, ecredis_contacts),
    ECRedisAuth = create_redis_child_spec(redis_auth, ecredis, ecredis_auth),
    ECRedisPhone = create_redis_child_spec(redis_phone, ecredis, ecredis_phone),
    ECRedisMessages = create_redis_child_spec(redis_messages, ecredis, ecredis_messages),
    ECRedisWhisper = create_redis_child_spec(redis_whisper, ecredis, ecredis_whisper),
    ECRedisGroups = create_redis_child_spec(redis_groups, ecredis, ecredis_groups),
    ECRedisFeed = create_redis_child_spec(redis_feed, ecredis, ecredis_feed),
    ECRedisSessions = create_redis_child_spec(redis_sessions, ecredis, ecredis_sessions),

    %% We are dynamically adding the children to the redis_sup supervisor.
    %% So, if one of the children fails to start here for some reason,
    %% We'll log an error, but the rest will continue to function meanwhile.
    start_child(ECRedisFriends),
    start_child(ECRedisAccounts),
    start_child(ECRedisContacts),
    start_child(ECRedisAuth),
    start_child(ECRedisPhone),
    start_child(ECRedisMessages),
    start_child(ECRedisWhisper),
    start_child(ECRedisGroups),
    start_child(ECRedisFeed),
    start_child(ECRedisSessions),
    ok.


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


-spec start_child(ChildSpec :: supervisor:child_spec()) -> ok | no_return().
start_child(ChildSpec) ->
    case supervisor:start_child(?SERVER, ChildSpec) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, Reason} ->
            ?CRITICAL("Error starting child: ~p, reason: ~p", [ChildSpec, Reason]),
            erlang:error(unable_to_connect, [ChildSpec, Reason])
    end.


-spec get_redises() -> [atom()].
get_redises() ->
    [
        redis_accounts,
        redis_auth,
        redis_contacts,
        redis_feed,
        redis_groups,
        redis_messages,
        redis_phone,
        redis_sessions,
        redis_whisper
    ].

%%%===================================================================
%%% Internal functions
%%%===================================================================

% Make sure if we are in the prod environment we are running on the right ec2 instance
% Make sure if we are in test ot github environment we don't have Jabber IAM role
-spec check_environment() -> ok. % or error is raised.
check_environment() ->
    case config:get_hallo_env() of
        prod ->
            Arn = util_aws:get_arn(),
            IsJabberIAMRole = util_aws:is_jabber_iam_role(Arn),
            ?INFO("Arn ~p ~p", [Arn, IsJabberIAMRole]),
            case IsJabberIAMRole of
                true -> ok;
                false -> error({bad_iam_role, Arn, prod})
            end;
        github ->
            Arn = util_aws:get_arn(),
            IsJabberIAMRole = util_aws:is_jabber_iam_role(Arn),
            ?INFO("Arn ~p ~p", [Arn, IsJabberIAMRole]),
            case IsJabberIAMRole of
                true -> error({bad_iam_role, Arn, github});
                false -> ok
            end;
        _ -> ok
    end.

