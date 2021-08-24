%%%----------------------------------------------------------------------
%%% File    : mod_client_version.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles the iq queries related to client versions
%%% - When given an iq-get query with a version,
%%% - We check if the version already exists in our table, if not: insert it.
%%% - Obtain the number of seconds left and return that to the client.
%%% This module can also check if a version is valid or not.
%%%
%%%----------------------------------------------------------------------

-module(mod_client_version).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("time.hrl").
-include("client_version.hrl").
-include("packets.hrl").


%% gen_mod API.
-export([start/2, stop/1, depends/2, reload/3, mod_options/1]).

-export([
    process_local_iq/1,
    is_valid_version/1,
    get_version_ttl/1,
    c2s_session_opened/1,
    extend_version_validity/2,
    get_time_left/2     %% test
]).

% TODO: add tests after the migration to Redis is done.

start(Host, _Opts) ->
    ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_client_version, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_client_version),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


process_local_iq(#pb_iq{type = get, from_uid = Uid,
        payload = #pb_client_version{version = Version}} = IQ) ->
    % TODO(Nikola): clean up this print once we figure out the different versions bug
    ?INFO("mod_client_version Uid: ~s ClientVersion ~p", [Uid, Version]),
    CurTimestamp = util:now(),
    TimeLeftSec = get_time_left(Version, CurTimestamp),
    case TimeLeftSec > 0 of
        true ->
            ?INFO("client_version version: ~p, valid for ~p seconds", [Version, TimeLeftSec]),
            ok;
        false ->
            ?INFO("client_version version: ~p, expired ~p seconds ago",
                [Version, abs(TimeLeftSec)])
    end,
    pb:make_iq_result(IQ, #pb_client_version{version = Version, expires_in_seconds = TimeLeftSec}).


c2s_session_opened(#{user := Uid, client_version := ClientVersion} = State) ->
    check_and_migrate_otpkeys(Uid, ClientVersion),
    ok = set_client_version(Uid, ClientVersion),
    State.


-spec set_client_version(Uid :: binary(), ClientVersion :: binary()) -> boolean().
set_client_version(Uid, ClientVersion) ->
    ok = model_accounts:set_client_version(Uid, ClientVersion),
    ok.


%% Checks if a version is valid or not with respect to the current timestamp.
-spec is_valid_version(binary()) -> boolean().
is_valid_version(Version) ->
    get_version_ttl(Version) > 0.


-spec get_version_ttl(binary()) -> integer().
get_version_ttl(Version) ->
    case util_ua:is_valid_ua(Version) of
        false -> 0;
        true ->
            CurTimestamp = util:now(),
            TimeLeftSec = get_time_left(Version, CurTimestamp),
            TimeLeftSec
    end.


-spec extend_version_validity(Version :: binary(), ExtendTimeSec :: integer()) -> integer().
extend_version_validity(Version, ExtendTimeSec) ->
    CurTimestamp = model_client_version:get_version_ts(Version),
    case CurTimestamp of
        undefined ->
            ?ERROR("Can not find version ~s in Redis", [Version]),
            0;
        VerTs ->
            NewTimestamp = VerTs + ExtendTimeSec,
            ok = model_client_version:update_version_ts(Version, NewTimestamp),
            TimeLeft = get_time_left(Version, util:now()),
            ?INFO("updated version : ~s, timestamp is now: ~p, timeleft: ~p",
                    [Version, NewTimestamp, TimeLeft]),
            TimeLeft
    end.

%%====================================================================
%% internal functions
%%====================================================================

-spec check_and_migrate_otpkeys(Uid :: binary(), ClientVersion :: binary()) -> ok.
check_and_migrate_otpkeys(Uid, ClientVersion) ->
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% extra logic to clear out otp keys for older versions as they upgrade.
    %% Remove this code for ios on 04-03-2021.
    %% Remove this code for android in 2months - 05-03-2021.
    %% Run migration to delete otp keys of old accounts if any.
    %% Refresh keys if ios and if older version =< 1.2.91 and newer version > 1.2.91 (or)
    %% Refresh keys if android if old version =< 0.131 and newer version > 0.131.
    case model_accounts:get_client_version(Uid) of
        {ok, OldVersion} ->
            ClientType = util_ua:get_client_type(ClientVersion),
            IsNewVersionGreater = case ClientType of
                ios -> util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.2.91">>);
                android -> util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android0.131">>);
                undefined -> false  %% ignore account
            end,
            IsOldVersionGreater = case {ClientType, OldVersion} of
                {_, undefined} -> false;
                {ios, _} -> util_ua:is_version_greater_than(OldVersion, <<"HalloApp/iOS1.2.91">>);
                {android, _} -> util_ua:is_version_greater_than(OldVersion, <<"HalloApp/Android0.131">>);
                {undefined, _} -> false  %% ignore account
            end,
            %% refresh otp keys for all
            %% - ios accounts with version > 1.2.91
            %% - android accounts with version > 0.131
            case not IsOldVersionGreater andalso IsNewVersionGreater of
                false -> ok;
                true ->
                    ?INFO("Uid: ~p, OldVersion: ~p, NewVersion: ~p", [Uid, OldVersion, ClientVersion]),
                    ok = mod_whisper:refresh_otp_keys(Uid)
            end;
        _ ->
            ?INFO("No client version found for uid: ~p, probably new user", [Uid])
    end,
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    ok.


%% Gets the time left in seconds for a client version.
%% If the client version is new, then we insert it into the table with the
%% current timestamp as the released date. If not, we fetch and compute the number of seconds left
%% using the max_days config option of the module.
-spec get_time_left(binary(), non_neg_integer()) -> integer().
get_time_left(undefined, _CurTimestamp) ->
    0;
get_time_left(Version, CurTimestamp) ->
    case model_client_version:set_version_ts(Version, CurTimestamp) of
        true -> ?INFO("New version ~s inserted at ~p", [Version, CurTimestamp]);
        false -> ok
    end,
    % TODO: we can combine the get with the set.
    VerTs = model_client_version:get_version_ts(Version),
    case VerTs of
        undefined ->
            ?ERROR("Can not find version ~s in Redis", [Version]),
            0;
        VerTs ->
            MaxTimeSec = get_version_validity(),
            MaxTimeSec - (CurTimestamp - VerTs)
    end.


-spec get_version_validity() -> integer().
get_version_validity() ->
    ?VERSION_VALIDITY.


mod_options(_Host) ->
    [].

