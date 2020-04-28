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
    get_service/1,
    get_default_log_level/0
]).
-export_type([service/0, hallo_env/0]).

-define(HALLO_ENV_NAME, "HALLO_ENV").
-define(ENV_LOCALHOST, "localhost").
-define(ENV_PROD, "prod").
-define(ENV_TEST, "test").
-define(ENV_GITHUB, "github").

-type hallo_env() :: prod | localhost | test.

-spec get_hallo_env() -> hallo_env().
get_hallo_env() ->
    case os:getenv(?HALLO_ENV_NAME) of
        ?ENV_LOCALHOST -> localhost;
        ?ENV_PROD -> prod;
        ?ENV_TEST -> test;
        ?ENV_GITHUB -> github;
        _Else -> prod
    end.

-type host() :: string().
-type service() :: {term(), host(), port()}.
-spec get_service(string()) -> {ok, service()} | {error, any()}.
get_service(Name) ->
    case {get_hallo_env(), Name} of
        {localhost, Name} -> {Name, "127.0.0.1", 30001};
        {test, Name} -> {Name, "127.0.0.1", 30001};
        {github, Name} -> {Name, "redis", 6379};
        {prod, redis_friends} -> {redis_friends, "redisaccounts.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_accounts} -> {redis_accounts, "redisaccounts.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_contacts} -> {redis_contacts, "rediscontacts.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_auth} -> {redis_auth, "redisauth.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_phone} -> {redis_phone, "redisphone.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        {prod, redis_messages} -> {redis_messages, "redismessages.zsin4n.clustercfg.use1.cache.amazonaws.com", 6379};
        _Else -> {error, service_not_found}
  end.

-spec get_default_log_level() -> ejabberd_logger:loglevel().
get_default_log_level() ->
    case get_hallo_env() of
        localhost -> 5;
        test -> 5;
        prod -> 4;
        github -> 4
    end.