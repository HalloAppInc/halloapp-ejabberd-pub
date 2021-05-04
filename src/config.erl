%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 20. Mar 2020 4:26 PM
%%%-------------------------------------------------------------------
-module(config).
-author("nikola").

%% API
-export([
    get_hallo_env/0,
    is_testing_env/0,
    is_prod_env/0,
    get_service/1,
    get_default_log_level/0,
    get_noise_secret_name/0,
    get_sentry_dsn/0
]).
-export_type([service/0, hallo_env/0]).

-define(HALLO_ENV_NAME, "HALLO_ENV").
-define(ENV_LOCALHOST, "localhost").
-define(ENV_PROD, "prod").
-define(ENV_TEST, "test").
-define(ENV_GITHUB, "github").
-define(ENV_STRESS, "stress").
-define(NOISE_PROD_SECRET_NAME, <<"noise_secret_prod">>).
-define(NOISE_PROD2_SECRET_NAME, <<"noise_secret_prod2">>).
-define(NOISE_DEV_SECRET_NAME, <<"noise_secret_dev">>).

-define(SENTRY_DSN_SECRET_NAME, <<"sentry_dsn">>).


-type hallo_env() :: prod | localhost | test | github.

-spec get_hallo_env() -> hallo_env().
get_hallo_env() ->
    case os:getenv(?HALLO_ENV_NAME) of
        ?ENV_LOCALHOST -> localhost;
        ?ENV_PROD -> prod;
        ?ENV_TEST -> test;
        ?ENV_GITHUB -> github;
        ?ENV_STRESS -> stress;
        _Else -> prod
        %% TODO: %% if nothing is present then update to use test or github.
    end.


-spec is_testing_env() -> boolean().
is_testing_env() ->
    case get_hallo_env() of
        test -> true;
        github -> true;
        stress -> true;
        _ -> false
    end.

-spec get_noise_secret_name() -> binary().
get_noise_secret_name() ->
    case is_prod_env() of
        true -> ?NOISE_PROD2_SECRET_NAME;
        _ -> ?NOISE_DEV_SECRET_NAME
    end.


-spec get_sentry_dsn() -> string().
get_sentry_dsn() ->
    %% Can not use mod_aws to fetch the secret, since mod_aws might not be started.
    base64:decode(util_aws:get_secret(?SENTRY_DSN_SECRET_NAME)).


-spec is_prod_env() -> boolean().
is_prod_env() ->
    get_hallo_env() =:= prod.


-type host() :: string().
-type service() :: {term(), host(), port()}.
-spec get_service(string()) -> {ok, service()} | {error, any()}.
get_service(Name) ->
    case {get_hallo_env(), Name} of
        {localhost, Name} -> {Name, "127.0.0.1", 30001};
        {test, Name} -> {Name, "127.0.0.1", 30001};
        {github, Name} -> {Name, "127.0.0.1", 30001};
        {stress, Name} -> {Name, "redis-stress1.emlvii.clustercfg.use2.cache.amazonaws.com", 6379};
        {prod, redis_friends} -> {redis_friends, "redis-accounts.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_accounts} -> {redis_accounts, "redis-accounts.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_contacts} -> {redis_contacts, "redis-contacts.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_auth} -> {redis_auth, "redis-auth.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_phone} -> {redis_phone, "redis-phone.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_messages} -> {redis_messages, "redismessages.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_whisper} -> {redis_whisper, "redis-whisper.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_groups} -> {redis_groups, "redis-groups.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_feed} -> {redis_feed, "redisfeed.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_sessions} -> {redis_sessions, "redis-sessions.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        _Else -> {error, service_not_found}
  end.

-spec get_default_log_level() -> ejabberd_logger:loglevel().
get_default_log_level() ->
    case get_hallo_env() of
        localhost -> 5;
        test -> 5;
        prod -> 4;
        github -> 4;
        stress -> 4;
        _ -> 4
    end.

