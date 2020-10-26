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
-include("xmpp.hrl").

-define(NS_CLIENT_VER, <<"halloapp:client:version">>).
-define(CUTOFF_TIME, 1603318598).
-define(OLD_MAX_DAYS, 30).

%% gen_mod API.
-export([start/2, stop/1, depends/2, reload/3, mod_options/1, mod_opt_type/1]).

-export([
    process_local_iq/1,
    c2s_handle_info/2,
    is_valid_version/1,
    set_client_version/2,
    c2s_session_opened/1,
    get_version_validity/1,  % Stop exporting this once we delete mnesia
    get_time_left/2     %% test
]).

% TODO: add tests after the migration to Redis is done.

start(Host, Opts) ->
    ejabberd_hooks:add(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 10),
    ejabberd_hooks:add(pb_c2s_handle_info, Host, ?MODULE, c2s_handle_info, 10),
    ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_CLIENT_VER, ?MODULE, process_local_iq),
    mod_client_version_mnesia:init(Host, Opts),
    store_options(Opts),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 10),
    ejabberd_hooks:delete(pb_c2s_handle_info, Host, ?MODULE, c2s_handle_info, 10),
    ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_CLIENT_VER),
    mod_client_version_mnesia:close(Host),
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


process_local_iq(#iq{type = get, to = _Host, from = From,
        sub_els = [#client_version{version = Version}]} = IQ) ->
    CurTimestamp = util:now_binary(),
    TimeLeftSec = get_time_left(Version, CurTimestamp),
    Validity = is_valid_version(Version, TimeLeftSec),
    check_and_close_connection(Version, Validity, From),
    check_and_set_user_agent(Version, From#jid.luser),
    ?INFO("client_version version: ~p, validity: ~p, time left: ~p",
        [Version, Validity, TimeLeftSec]),
    xmpp:make_iq_result(IQ, #client_version{version = Version, seconds_left = TimeLeftSec}).


c2s_session_opened(#{user := Uid, client_version := ClientVersion} = State) ->
    ok = set_client_version(Uid, ClientVersion),
    State.


c2s_handle_info(State, {kill_connection, expired_app_version, From}) ->
    #jid{user = User, server = Server, resource = Resource} = From,
    case ejabberd_sm:get_session_pid(User, Server, Resource) of
        Pid when is_pid(Pid) -> ejabberd_c2s:close(Pid, expired_app_version);
        _ -> ok
    end,
    State;
c2s_handle_info(State, _) ->
    State.


-spec set_client_version(Uid :: binary(), ClientVersion :: binary()) -> boolean().
set_client_version(Uid, ClientVersion) ->
    ok = model_accounts:set_client_version(Uid, ClientVersion),
    ok.


%% Checks if a version is valid or not with respect to the current timestamp.
-spec is_valid_version(binary()) -> boolean().
is_valid_version(Version) ->
    CurTimestamp = util:now_binary(),
    TimeLeftSec = get_time_left(Version, CurTimestamp),
    is_valid_version(Version, TimeLeftSec).

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
            ?INFO("User agent for uid:~p updated to ~p",[Uid, Version]);
        _ -> ok
    end.


%% Checks if the version is valid or not based on the boolean value.
%% If it's not valid, then kill the connection.
check_and_close_connection(_Version, true, _From) ->
    ok;
check_and_close_connection(_Version, false, From) ->
    erlang:send(self(), {kill_connection, expired_app_version, From}),
    ok.


%% Checks if the version with the timeleft is valid or not.
%% We consider a version to be valid if it has more than 60 seconds of unexpired time.
-spec is_valid_version(binary(), binary()) -> boolean().
is_valid_version(_Version, TimeLeftSec) ->
    SecsLeft = binary_to_integer(TimeLeftSec),
    if
        % TODO(nikola) why 60 seconds, should be 0?
        SecsLeft =< 60 -> false;
        true -> true
    end.


%% Gets the time left in seconds for a client version.
%% If the client version is new, then we insert it into the table with the
%% current timestamp as the released date. If not, we fetch and compute the number of seconds left
%% using the max_days config option of the module.
-spec get_time_left(binary(), binary()) -> binary().
get_time_left(undefined, _CurTimestamp) ->
    <<"0">>;
get_time_left(Version, CurTimestamp) ->
    case mod_client_version_mnesia:check_if_version_exists(Version) of
        false ->
            mod_client_version_mnesia:insert_version(Version, CurTimestamp),
            model_client_version:set_version_ts(Version, binary_to_integer(CurTimestamp));
        true ->
            ok
    end,
    case mod_client_version_mnesia:get_time_left(Version, CurTimestamp) of
        {error, _} ->
            ?ERROR("version missing, should not happen. Version: ~p", [Version]),
            <<"0">>;
        {ok, SecsLeft} ->
            VerTs = model_client_version:get_version_ts(Version),
            case VerTs of
                undefined -> ?WARNING("version_check_failed no data in Redis Version: ~p", [Version]);
                _ ->
                    MaxTimeSec = get_version_validity(VerTs),
                    NewSecsLeft = MaxTimeSec - (binary_to_integer(CurTimestamp) - VerTs),
                    case SecsLeft =:= NewSecsLeft of
                        true ->
                            ?INFO("version_match_ok version ~p -> ~p", [Version, NewSecsLeft]);
                        false ->
                            ?ERROR("version_exp_mismatch Version: ~p ~p ~p",
                                [Version, SecsLeft, NewSecsLeft])
                    end
            end,
            integer_to_binary(SecsLeft)
    end.

%% Store the necessary options with persistent_term.
%% [https://erlang.org/doc/man/persistent_term.html]
store_options(Opts) ->
    MaxDays = mod_client_version_opt:max_days(Opts),
    %% Store MaxDays as int.
    persistent_term:put({?MODULE, max_days}, MaxDays).


-spec get_version_validity(VersionTs :: integer()) -> integer().
get_version_validity(VersionTs) ->
    case VersionTs > ?CUTOFF_TIME of
        true -> get_max_days() * 24 * 60 * 60;
        false -> ?OLD_MAX_DAYS * 24 * 60 * 60
    end.

-spec get_max_days() -> integer().
get_max_days() ->
    persistent_term:get({?MODULE, max_days}).


-spec mod_opt_type(atom()) -> econf:validator().
mod_opt_type(max_days) ->
    econf:pos_int(infinity).


mod_options(_Host) ->
    [
        {max_days, 30}
    ].

