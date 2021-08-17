%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Aug 2020 1:03 PM
%%%-------------------------------------------------------------------
-module(mod_aws).
-author("josh").
-behavior(gen_mod).

-include("logger.hrl").
-include("mod_aws.hrl").
-include("time.hrl").
-define(NOISE_SECRET_DEV_FILE, "noise_secret_dev").

%% Export all functions for unit tests
-ifdef(TEST).
-export([
    retrieve_secret/1,
    get_and_cache_secret/1,
    get_and_cache_ips/0,
    get_cached_secret/1,
    get_cached_ips/0
]).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    clear_cache/0,
    clear_cache/1,
    get_secret/1,
    get_ejabberd_ips/0
]).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(_Host, _Opts) ->
    try
        ?INFO("Trying to create tables for mod_aws in ets", []),
        lists:foreach(
            fun(Table) ->
                ets:new(Table, [named_table, public, {read_concurrency, true}])
            end,
            ?TABLES),
        ok
    catch
        Error:badarg ->
            ?WARNING("Failed to create a table for mod_aws in ets: ~p", [Error]),
            error
    end,
    ok.

stop(_Host) ->
    lists:foreach(fun ets:delete/1, ?TABLES),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================

-spec clear_cache() -> ok.
clear_cache() ->
    lists:foreach(fun clear_cache/1, ?TABLES),
    ok.


-spec clear_cache(Table :: ets:tab()) -> ok.
clear_cache(Table) ->
    ets:delete_all_objects(Table),
    ok.


-spec get_secret(SecretName :: binary()) -> binary().
get_secret(SecretName) ->
    case config:is_prod_env() of
        true -> get_secret_internal(SecretName);
        false ->
            case SecretName of
                %% This allows us to use noise in our ct test suite.
                <<"noise_secret_dev">> ->
                    FileName = filename:join(misc:data_dir(), ?NOISE_SECRET_DEV_FILE),
                    {ok, SecretBin} = file:read_file(FileName),
                    SecretBin;
                %% This allows us to ping an SMS provider's test API
                <<"TwilioTest">> -> get_secret_internal(SecretName);
                <<"MBirdTest">> -> get_secret_internal(SecretName);
                _ -> ?DUMMY_SECRET
            end
    end.


-spec get_ejabberd_ips() -> [string()].
get_ejabberd_ips() ->
    case config:is_prod_env() of
        true -> get_ips_internal();
        false -> ?LOCALHOST_IPS
    end.

%%====================================================================
%% Internal functions
%%====================================================================

-spec retrieve_secret(SecretName :: binary()) -> binary().
retrieve_secret(SecretName) ->
    {ok, Res} = erlcloud_sm:get_secret_value(SecretName, []),
    [_ARN, _CreatedDate, _Name, {<<"SecretString">>, Json}, _VersionId, _VersionStages] = Res,
    Json.


-spec retrieve_ejabberd_ips() -> [string()].
retrieve_ejabberd_ips() ->
    {ok, Config} = erlcloud_aws:auto_config(),
    Filters = [{"tag:Name", ["s-test", "prod*"]}],
    %% TODO: see if aws function below can take --query pararm,
    %% so we don't have to do the map
    {ok, Res} = erlcloud_ec2:describe_instances([], Filters, Config),
    lists:map(
        fun(Ele) ->
            [_, _, {instances_set,[InfoList]}] = Ele,
            {ip_address, IpAddr} = lists:keyfind(ip_address, 1, InfoList),
            IpAddr
        end,
        Res
    ).


-spec get_and_cache_secret(SecretName :: binary()) -> binary().
get_and_cache_secret(SecretName) ->
    Secret = retrieve_secret(SecretName),
    true = ets:insert(?SECRETS_TABLE, {SecretName, Secret, util:now_ms()}),
    Secret.


-spec get_and_cache_ips() -> [string()].
get_and_cache_ips() ->
    Ips = retrieve_ejabberd_ips(),
    true = ets:insert(?IP_TABLE, {ip_list, Ips, util:now_ms()}),
    Ips.


-spec get_cached_secret(SecretName :: binary()) -> undefined | binary().
get_cached_secret(SecretName) ->
    case ets:lookup(?SECRETS_TABLE, SecretName) of
        [] -> undefined;
        [{SecretName, Secret, Ts}] ->
            case (util:now_ms() - Ts) > ?DAYS_MS of
                true -> get_and_cache_secret(SecretName);
                false -> Secret
            end
    end.


-spec get_cached_ips() -> [string()] | undefined.
get_cached_ips() ->
    case ets:lookup(?IP_TABLE, ip_list) of
        [] -> undefined;
        [{ip_list, IpList, Ts}] ->
            case (util:now_ms() - Ts) > (4 * ?HOURS_MS) of
                true -> get_and_cache_ips();
                false -> IpList
            end
    end.


-spec get_secret_internal(SecretName :: binary()) -> binary().
get_secret_internal(SecretName) ->
    case get_cached_secret(SecretName) of
        undefined -> get_and_cache_secret(SecretName);
        Secret -> Secret
    end.


-spec get_ips_internal() -> [string()].
get_ips_internal() ->
    case get_cached_ips() of
        undefined -> get_and_cache_ips();
        Ips -> Ips
    end.

