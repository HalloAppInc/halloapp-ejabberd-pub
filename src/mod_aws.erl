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
-include("time.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-export([
    get_table_name/0,
    retrieve_secret/1,
    get_and_cache_secret/1,
    get_cached_secret/1
]).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    get_secret/1
]).

-define(SECRETS_TABLE, aws_secrets).
-define(DUMMY_SECRET, <<"dummy_secret">>).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(_Host, _Opts) ->
    try
        ?INFO("Trying to create a table for mod_aws in ets", []),
        ets:new(?SECRETS_TABLE, [named_table, public, {read_concurrency, true}]),
        ok
    catch
        Error:badarg ->
            ?WARNING("Failed to create a table for mod_aws in ets: ~p", [Error]),
            error
    end,
    ok.

stop(_Host) ->
    ets:delete(?SECRETS_TABLE),
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

-spec get_secret(SecretName :: binary()) -> binary().
get_secret(SecretName) ->
    case config:is_prod_env() of
        true ->
            case get_cached_secret(SecretName) of
                undefined -> get_and_cache_secret(SecretName);
                Secret -> Secret
            end;
        false ->
            ?DUMMY_SECRET
    end.

%%====================================================================
%% Internal functions
%%====================================================================

-spec retrieve_secret(SecretName :: binary()) -> binary().
retrieve_secret(SecretName) ->
    {ok, Res} = erlcloud_sm:get_secret_value(SecretName, []),
    [_ARN, _CreatedDate, _Name, {<<"SecretString">>, Json}, _VersionId, _VersionStages] = Res,
    Json.


-spec get_and_cache_secret(SecretName :: binary()) -> binary().
get_and_cache_secret(SecretName) ->
    Secret = retrieve_secret(SecretName),
    true = ets:insert(?SECRETS_TABLE, {SecretName, Secret, util:now_ms()}),
    Secret.


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


% for testing only
get_table_name() ->
    ?SECRETS_TABLE.

