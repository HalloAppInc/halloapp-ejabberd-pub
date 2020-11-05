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
-include("xmpp.hrl").

-define(NS_CLIENT_VER, <<"halloapp:client:version">>).

% TODO: cleanup this on 2020-11-27
-define(CUTOFF_TIME, 1603318598).
-define(OLD_VERSION_VALIDITY, 30 * ?DAYS).

-define(VERSION_VALIDITY, 60 * ?DAYS).
%% gen_mod API.
-export([start/2, stop/1, depends/2, reload/3, mod_options/1]).

-export([
    process_local_iq/1,
    is_valid_version/1,
    c2s_session_opened/1,
    get_version_validity/1,  % Stop exporting this once we delete mnesia
    get_time_left/2     %% test
]).

% TODO: add tests after the migration to Redis is done.

start(Host, _Opts) ->
    ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_CLIENT_VER, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_CLIENT_VER),
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


process_local_iq(#iq{type = get, to = _Host, from = From,
        sub_els = [#client_version{version = Version}]} = IQ) ->
    % TODO(Nikola): clean up this print once we figure out the different versions bug
    ?INFO("mod_client_version Uid: ~s ClientVersion ~p", [From#jid.luser, Version]),
    CurTimestamp = util:now(),
    TimeLeftSec = get_time_left(Version, CurTimestamp),
    case TimeLeftSec > 0 of
        true ->
            ?INFO("client_version version: ~p, valid for ~p seconds", [Version, TimeLeftSec]),
            check_and_set_user_agent(Version, From#jid.luser);
        false ->
            ?INFO("client_version version: ~p, expired ~p seconds ago",
                [Version, abs(TimeLeftSec)])
    end,
    xmpp:make_iq_result(IQ, #client_version{version = Version,
            seconds_left = util:to_binary(TimeLeftSec)}).


c2s_session_opened(#{user := Uid, client_version := ClientVersion} = State) ->
    ok = set_client_version(Uid, ClientVersion),
    State.


-spec set_client_version(Uid :: binary(), ClientVersion :: binary()) -> boolean().
set_client_version(Uid, ClientVersion) ->
    ok = model_accounts:set_client_version(Uid, ClientVersion),
    ok.


%% Checks if a version is valid or not with respect to the current timestamp.
-spec is_valid_version(binary()) -> boolean().
is_valid_version(Version) ->
    CurTimestamp = util:now(),
    TimeLeftSec = get_time_left(Version, CurTimestamp),
    TimeLeftSec > 0.

%%====================================================================
%% internal functions
%%====================================================================

%% Temp code to repair missing data during signup process
check_and_set_user_agent(Version, Uid) ->
    Result = model_accounts:get_signup_user_agent(Uid),
    case Result of
        {error, missing} ->
            % TODO(nikola): check if this is still happening, maybe we can remove this code
            model_accounts:set_user_agent(Uid, Version),
            ?WARNING("User agent for uid:~p updated to ~p",[Uid, Version]);
        _ -> ok
    end.

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
            MaxTimeSec = get_version_validity(VerTs),
            MaxTimeSec - (CurTimestamp - VerTs)
    end.

% TODO: this function can be simplified after 2020-11-25
-spec get_version_validity(VersionTs :: integer()) -> integer().
get_version_validity(VersionTs) ->
    case VersionTs > ?CUTOFF_TIME of
        true -> ?VERSION_VALIDITY;
        false -> ?OLD_VERSION_VALIDITY
    end.


mod_options(_Host) ->
    [].

