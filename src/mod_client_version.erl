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

%% gen_mod API.
-export([start/2, stop/1, depends/2, reload/3, mod_options/1, mod_opt_type/1, is_valid_version/1]).
%% iq handler and hooks.
-export([process_local_iq/1, c2s_handle_info/2]).
%% debug console functions.
-export([get_time_left/2]).


start(Host, Opts) ->
    ejabberd_hooks:add(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 10),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_CLIENT_VER, ?MODULE, process_local_iq),
    mod_client_version_mnesia:init(Host, Opts),
    store_options(Opts),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 10),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_CLIENT_VER),
    mod_client_version_mnesia:close(Host),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


process_local_iq(#iq{type = get, to = _Host, from = From,
                  sub_els = [#client_version{version = Version}]} = IQ) ->
  CurTimestamp = util:now_binary(),
  TimeLeftSec = get_time_left(Version, CurTimestamp),
  Validity = is_valid_version(Version, TimeLeftSec),
  check_and_close_connection(Version, Validity, From),
  ?INFO_MSG("mod_client_version: Received an IQ for this version: ~p, validity: ~p, time left: ~p",
                                                              [Version, Validity, TimeLeftSec]),
  xmpp:make_iq_result(IQ, #client_version{version = Version, seconds_left = TimeLeftSec}).



c2s_handle_info(State, {kill_connection, expired_app_version, From}) ->
     #jid{user = User, server = Server, resource = Resource} = From,
      case ejabberd_sm:get_session_pid(User, Server, Resource)
          of
        Pid when is_pid(Pid) -> ejabberd_c2s:close(Pid, expired_app_version);
        _ -> ok
      end,
    State;
c2s_handle_info(State, _) ->
    State.


%% Checks if a version is valid or not with respect to the current timestamp.
-spec is_valid_version(binary()) -> boolean().
is_valid_version(Version) ->
  CurTimestamp = util:now_binary(),
  TimeLeftSec = get_time_left(Version, CurTimestamp),
  is_valid_version(Version, TimeLeftSec).

%%====================================================================
%% internal functions
%%====================================================================


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
    SecsLeft =< 60 ->
      false;
    true ->
      true
  end.



%% Gets the time left in seconds for a client version.
%% If the client version is new, then we insert it into the table with the
%% current timestamp as the released date. If not, we fetch and compute the number of seconds left
%% using the max_days config option of the module.
-spec get_time_left(binary(), binary()) -> binary().
get_time_left(undefined, _CurTimestamp) ->
  <<"0">>;
get_time_left(Version, CurTimestamp) ->
  MaxTimeSec = get_max_time_in_sec(),
  case mod_client_version_mnesia:check_if_version_exists(Version) of
    false ->
      mod_client_version_mnesia:insert_version(Version, CurTimestamp);
    true ->
      ok
  end,
  case mod_client_version_mnesia:get_time_left(Version, CurTimestamp, MaxTimeSec) of
    {error, _} -> <<"0">>;
    {ok, SecsLeft} -> integer_to_binary(SecsLeft)
  end.



%% Store the necessary options with persistent_term.
%% [https://erlang.org/doc/man/persistent_term.html]
store_options(Opts) ->
  MaxDays = mod_client_version_opt:max_days(Opts),
  %% Store MaxDays as int.
  persistent_term:put({?MODULE, max_days}, MaxDays).


-spec get_max_time_in_sec() -> integer().
get_max_time_in_sec() ->
  get_max_days() * 24 * 60 * 60.


-spec get_max_days() -> integer().
get_max_days() ->
  persistent_term:get({?MODULE, max_days}).



-spec mod_opt_type(atom()) -> econf:validator().
mod_opt_type(max_days) ->
  econf:pos_int(infinity).

mod_options(_Host) ->
  [{max_days, 30}].



