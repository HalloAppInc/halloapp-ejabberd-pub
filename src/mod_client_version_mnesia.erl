%%%----------------------------------------------------------------------
%%% File    : mod_client_version_mnesia.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the mnesia related queries with client versions to
%%% - insert a new client version into an mnesia table
%%% - fetch/delete a client version
%%% - check if a version exists already.
%%% - get the time left in seconds for a client version based on the timestamp.
%%%----------------------------------------------------------------------

-module(mod_client_version_mnesia).
-author('murali').
-include("logger.hrl").
-include("translate.hrl").

-export([init/2, close/1]).

-export([
    insert_version/2,
    delete_version/2,
    delete_version/1,
    fetch_version/1,
    get_time_left/3,
    check_if_version_exists/1,
    migrate_to_redis/0
]).

-record(client_version, {
    version :: binary(),
    timestamp :: binary()
}).


init(_Host, _Opts) ->
    case mnesia:create_table(client_version, [
            {disc_copies, [node()]},
            {attributes, record_info(fields, client_version)}]) of
        {atomic, _} -> ok;
        _ -> {error, db_failure}
    end.


close(_Host) ->
    ok.


-spec insert_version(binary(), binary()) -> {ok, any()} | {error, any()}.
insert_version(Version, Timestamp) ->
    F = fun () ->
        mnesia:write(#client_version{version = Version, timestamp = Timestamp}),
        {ok, inserted_version}
    end,
    case mnesia:transaction(F) of
        {atomic, Result} ->
            ?DEBUG("mnesia transaction successful for version: ~p", [Version]),
            Result;
        {aborted, Reason} ->
            ?ERROR("mnesia transaction failed for version: ~p with reason: ~p", [Version, Reason]),
            {error, db_failure}
    end.


-spec delete_version(binary(), binary()) -> {ok, any()} | {error, any()}.
delete_version(Version, Timestamp) ->
    F = fun() ->
        ClientVersion = #client_version{version = Version, timestamp = Timestamp},
        Result = mnesia:match_object(ClientVersion),
        case Result of
            [] ->
                ok;
            [#client_version{}] ->
                mnesia:delete_object(ClientVersion)
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} ->
            ?DEBUG("mnesia transaction successful for version: ~p", [Version]),
            {ok, Result};
        {aborted, Reason} ->
            ?ERROR("mnesia transaction failed for version: ~p with reason: ~p", [Version, Reason]),
            {error, db_failure}
    end.


-spec delete_version(binary()) -> {ok, any()} | {error, any()}.
delete_version(Version) ->
    F = fun() ->
        Result = mnesia:match_object(#client_version{version = Version, _ = '_'}),
        case Result of
            [] ->
                ok;
            [#client_version{} | _] ->
                mnesia:delete({client_version, Version})
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} ->
            ?DEBUG("mnesia transaction successful for version: ~p", [Version]),
            {ok, Result};
        {aborted, Reason} ->
            ?ERROR("mnesia transaction failed for version: ~p with reason: ~p", [Version, Reason]),
            {error, db_failure}
    end.


-spec fetch_version(binary()) -> {ok, #client_version{}} | {error, any()}.
fetch_version(Version) ->
    F = fun() ->
        case mnesia:match_object(#client_version{version = Version, _ = '_'}) of
            [] -> {error, empty};
            [#client_version{} = Result] -> {ok, Result}
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} ->
            ?DEBUG("mnesia transaction successful for version: ~p", [Version]),
            Result;
        {aborted, Reason} ->
            ?ERROR("mnesia transaction failed for version: ~p with reason: ~p", [Version, Reason]),
            {error, db_failure}
    end.


-spec get_time_left(binary(), binary(), integer()) -> {error, any()} | {ok, integer()}.
get_time_left(Version, CurTimestamp, MaxTimeInSec) ->
    Result = fetch_version(Version),
    case Result of
        {error, _} ->
            {error, invalid_version};
        {ok, #client_version{timestamp = ThenTimestamp}} ->
            Cur = binary_to_integer(CurTimestamp),
            Then = binary_to_integer(ThenTimestamp),
            SecsLeft = MaxTimeInSec - (Cur - Then),
            {ok, SecsLeft}
    end.


-spec check_if_version_exists(binary()) -> boolean().
check_if_version_exists(Version) ->
    F = fun() ->
        case mnesia:match_object(#client_version{version = Version, _ = '_'}) of
            [] -> false;
            [#client_version{}] -> true
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Res} ->
            ?DEBUG("mnesia transaction successful for version: ~p", [Version]),
            Res;
        {aborted, Reason} ->
            ?ERROR("mnesia transaction failed for version: ~p with reason: ~p", [Version, Reason]),
            false
    end.

% TODO: Delete this after the migration is done
migrate_to_redis() ->
    mnesia:activity(sync_dirty,
        fun() ->
            mnesia:foldl(
                fun(#client_version{version = V, timestamp = T}, Acc) ->
                    ?INFO_MSG("Migrating ~p ~p", [V, T]),
                    model_client_version:set_version_ts(V, binary_to_integer(T)),
                    Acc
                end,
                ignored_acc,
                client_version)
        end).

