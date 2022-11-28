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

-include("ha_types.hrl").
-include("logger.hrl").
-include("mod_aws.hrl").
-include("time.hrl").
-define(NOISE_SECRET_DEV_FILE, "noise_secret_dev").

%% Configurable cache reset times
-define(SECRETS_CACHE_REFRESH_TIME_MS, (1 * ?DAYS_MS)).
-define(MACHINES_CACHE_REFRESH_TIME_MS, (4 * ?HOURS_MS)).

%% Export all functions for unit tests
-ifdef(TEST).
-export([
    retrieve_secret/1,
    get_and_cache_secret/1,
    get_and_cache_machines/0,
    get_cached_secret/1,
    get_cached_machines/0
]).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    clear_cache/0,
    clear_cache/1,
    get_secret/1,
    get_secret_value/2,
    get_ejabberd_machines/0,
    get_ip/1,
    get_stest_ips/0,
    get_stest_ips_v6/0
]).

%% Hooks
-export([node_up/2, node_down/2]).

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
    ejabberd_hooks:add(node_up, ?MODULE, node_up, 0),
    ejabberd_hooks:add(node_down, ?MODULE, node_down, 0),
    ok.

stop(_Host) ->
    ejabberd_hooks:delete(node_up, ?MODULE, node_up, 0),
    ejabberd_hooks:delete(node_down, ?MODULE, node_down, 0),
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
    ?INFO("Clearing mod_aws cache for ~p", [Table]),
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
                <<"Vonage">> -> get_secret_internal(SecretName);
                <<"fcm">> -> <<"{\"fcm\": \"dummySecret\"}">>;
                _ -> ?DUMMY_SECRET
            end
    end.

-spec get_secret_value(Name :: binary(), Key :: binary()) -> string().
get_secret_value(Name, Key) ->
    Json = jiffy:decode(mod_aws:get_secret(Name), [return_maps]),
    util:to_list(maps:get(Key, Json)).


-spec get_ejabberd_machines() -> [{MachineName :: string(), Ip :: string()}].
get_ejabberd_machines() ->
    case config:is_prod_env() of
        true -> get_machines_internal();
        false -> ?LOCALHOST_IPS
    end.

%%====================================================================
%% Hooks
%%====================================================================

node_up(_Node, _InfoList) -> clear_cache().

node_down(_Node, _InfoList) -> clear_cache().

%%====================================================================
%% Internal functions
%%====================================================================

-spec retrieve_secret(SecretName :: binary()) -> binary().
retrieve_secret(SecretName) ->
    {ok, Res} = erlcloud_sm:get_secret_value(SecretName, []),
    [_ARN, _CreatedDate, _Name, {<<"SecretString">>, Json}, _VersionId, _VersionStages] = Res,
    Json.


-spec retrieve_ejabberd_machines() -> [{string(), string()}].
retrieve_ejabberd_machines() ->
    {ok, Config} = erlcloud_aws:auto_config(),
    Filters = [{"tag:Name", ["s-test*", "prod*"]}],
    %% TODO: see if aws function below can take --query pararm,
    %% so we don't have to do the map
    {ok, Res} = erlcloud_ec2:describe_instances([], Filters, Config),
    lists:map(
        fun(Ele) ->
            [_, _, {instances_set,[InfoList]}] = Ele,
            {ip_address, IpAddr} = lists:keyfind(ip_address, 1, InfoList),
            {tag_set, Tags} = lists:keyfind(tag_set, 1, InfoList),
            [Name] = lists:filtermap(
                fun([{key, Key},{value, Val}]) ->
                    case Key =:= "Name" of
                        false -> false;
                        true -> {true, Val}
                    end
                end,
                Tags),
            {Name, IpAddr}
        end,
        Res
    ).


-spec get_and_cache_secret(SecretName :: binary()) -> binary().
get_and_cache_secret(SecretName) ->
    Secret = retrieve_secret(SecretName),
    true = ets:insert(?SECRETS_TABLE, {SecretName, Secret, util:now_ms()}),
    Secret.


-spec get_and_cache_machines() -> [{string(), string()}].
get_and_cache_machines() ->
    Ips = retrieve_ejabberd_machines(),
    true = ets:insert(?IP_TABLE, {ip_list, Ips, util:now_ms()}),
    Ips.


-spec get_cached_secret(SecretName :: binary()) -> maybe(binary()).
get_cached_secret(SecretName) ->
    case ets:lookup(?SECRETS_TABLE, SecretName) of
        [] -> undefined;
        [{SecretName, Secret, Ts}] ->
            case (util:now_ms() - Ts) > ?SECRETS_CACHE_REFRESH_TIME_MS of
                true -> get_and_cache_secret(SecretName);
                false -> Secret
            end
    end.


-spec get_cached_machines() -> maybe([{string(), string()}]).
get_cached_machines() ->
    case ets:lookup(?IP_TABLE, ip_list) of
        [] -> undefined;
        [{ip_list, IpList, Ts}] ->
            case (util:now_ms() - Ts) > ?MACHINES_CACHE_REFRESH_TIME_MS of
                true -> get_and_cache_machines();
                false -> IpList
            end
    end.


-spec get_secret_internal(SecretName :: binary()) -> binary().
get_secret_internal(SecretName) ->
    case get_cached_secret(SecretName) of
        undefined -> get_and_cache_secret(SecretName);
        Secret -> Secret
    end.


-spec get_machines_internal() -> [{string(), string()}].
get_machines_internal() ->
    case get_cached_machines() of
        undefined -> get_and_cache_machines();
        Ips -> Ips
    end.

-spec get_ip(MachineName :: string()) -> string().
get_ip(MachineName) ->
    case lists:keyfind(MachineName, 1, get_ejabberd_machines()) of
        false -> "";
        {MachineName, IpAddr} -> IpAddr
    end.

-spec get_stest_ips() -> [string()].
get_stest_ips() ->
    lists:filtermap(
        fun({Name, Ip}) ->
            case string:find(Name, "s-test") of
                nomatch -> false;
                _ -> {true, Ip}
            end
        end,
        get_ejabberd_machines()).


%% TODO: Fix this.
-spec get_stest_ips_v6() -> [string()].
get_stest_ips_v6() ->
    ["2600:1f18:1b30:6300:6fae:a209:b50:1ada"].

