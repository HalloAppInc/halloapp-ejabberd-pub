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

start(_Host, _Opts) ->
    ejabberd_hooks:add(c2s_session_opened, halloapp, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_client_version, ?MODULE, process_local_iq),
    ejabberd_hooks:add(c2s_session_opened, katchup, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_client_version, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    ejabberd_hooks:delete(c2s_session_opened, halloapp, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_client_version),
    ejabberd_hooks:delete(c2s_session_opened, katchup, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_client_version),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


process_local_iq(#pb_iq{type = get, from_uid = Uid,
        payload = #pb_client_version{version = Version}} = IQ) ->
    CurTimestamp = util:now(),
    TimeLeftSec = get_time_left(Version, CurTimestamp),
    Validity = TimeLeftSec > 0,
    ?INFO("Uid: ~s ClientVersion ~p, TimeLeftSec: ~p, Validity: ~p",
        [Uid, Version, TimeLeftSec, Validity]),
    pb:make_iq_result(IQ, #pb_client_version{version = Version, expires_in_seconds = TimeLeftSec}).


c2s_session_opened(#{user := Uid, client_version := ClientVersion,
        device := Device, os_version := OsVersion} = State) ->
    ok = model_accounts:set_client_info(Uid, ClientVersion, Device, OsVersion),
    State.


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

