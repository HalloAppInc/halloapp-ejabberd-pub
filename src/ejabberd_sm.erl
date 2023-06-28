%%%----------------------------------------------------------------------
%%% File    : ejabberd_sm.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Session manager
%%% Created : 24 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_sm).
-author('murali').
-author('alexey@process-one.net').

-ifndef(GEN_SERVER).
-define(GEN_SERVER, gen_server).
-endif.
-behaviour(?GEN_SERVER).

%% API
-export([
    start_link/0,
    stop/0,
    prep_stop/0,
    route/1,
    route/2,
    open_session/7,
    check_and_activate_session/2,
    is_session_active/1,
    close_session/4,
    push_message/1,
    bounce_sm_packet/1,
    disconnect_removed_user/2,
    get_user_resources/2,
    get_user_present_resources/2,
    dirty_get_my_sessions_list/0,
    ets_count_sessions/0,
    ets_count_active_sessions/0,
    ets_count_passive_sessions/0,
    connected_users/0,
    connected_users_number/0,
    user_resources/2,
    kick_user/2,
    kick_user/3,
    get_session_pid/3,
    get_session_sid/3,
    get_session_sids/2,
    get_session_sids/3,
    get_user_info/2,
    get_user_info/3,
    get_user_ip/3,
    get_sessions/2,
    is_existing_resource/3,
    get_commands_spec/0,
    host_up/1,
    host_down/1,
    make_sid/0,
    config_reloaded/0,
    is_user_online/1,
    get_active_sessions/2,
    get_passive_sessions/2,
    get_passive_sessions/3
]).

%% TODO(murali@): This module has to be refactored soon!!

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("logger.hrl").
-include("jid.hrl").
-include("stanza.hrl").
-include("packets.hrl").
-include("ejabberd_commands.hrl").
-include("ejabberd_sm.hrl").
-include("ejabberd_stacktrace.hrl").
-include("translate.hrl").
-include ("account.hrl").
-include("ha_types.hrl").

-record(state, {}).

%% we allow atmost one active session per user.
%% maximum number of passive sessions for a user.
-define(MAX_PASSIVE_SESSIONS, 5).
% How long to wait for all c2s process to terminate, during shutdown
-define(SHUTDOWN_TIMEOUT_MS, 3000).

%%====================================================================
%% API
%%====================================================================
-export_type([sid/0, info/0]).

start_link() ->
    ?INFO("start ~w", [?MODULE]),
    ?GEN_SERVER:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    ?INFO("~s stopping", [?MODULE]),
    ejabberd_sup:stop_child(?MODULE),
    % this supervisors are created by the ejabberd_listener
    ejabberd_sup:stop_child(halloapp_c2s_sup),
    ok.

% called before stop to give us some time to terminate all the c2s process gracefully.
-spec prep_stop() -> ok.
prep_stop() ->
    StartTime = util:now_ms(),
    ?INFO("initiating shutdown"),
    close_all_c2s(),

    wait_for_c2s_to_terminate(?SHUTDOWN_TIMEOUT_MS),
    ?INFO("done in ~pms", [util:now_ms() - StartTime]),
    ok.

-spec route(jid(), term()) -> ok.
%% @doc route arbitrary term to c2s process(es)
route(To, Term) ->
    try do_route(To, Term), ok
    catch Class : Reason : St ->
        ?ERROR("Failed to route term to ~ts: Term: ~p~n"
            "Stacktrace: ~ts",
            [To#jid.user, Term, lager:pr_stacktrace(St, {Class, Reason})])
    end.

-spec route(stanza()) -> ok.
route(Packet) ->
    do_route(Packet).

-spec check_privacy_and_dest_uid(Packet :: message()) -> allow | {deny, atom()}.
check_privacy_and_dest_uid(#pb_msg{to_uid = ToUid, type = _Type} = Packet) ->
    AppType = util_uid:get_app_type(ToUid),
    case ejabberd_auth:user_exists(ToUid) of
        true ->
            %% remove state from privacy_check_packet hook.
            case ejabberd_hooks:run_fold(privacy_check_packet, AppType, allow,
                    [undefined, Packet, in]) of
                allow -> allow;
                deny -> {deny, privacy_violation};
                {stop, deny} -> {deny, privacy_violation}
            end;
        false ->
            {deny, invalid_to_uid}
    end.

% Store the message in the offline store.
-spec store_offline_message(message()) -> message().
store_offline_message(#pb_msg{to_uid = ToUid} = Packet) ->
    AppType = util_uid:get_app_type(ToUid),
    ejabberd_hooks:run_fold(store_message_hook, AppType, Packet, []).


push_message(#pb_msg{to_uid = ToUid} = Packet) ->
    AppType = util_uid:get_app_type(ToUid),
    ejabberd_hooks:run_fold(push_message_hook, AppType, Packet, []).


-spec open_session(sid(), binary(), binary(), binary(), prio(), mode(), info()) -> ok.
open_session(SID, User, Server, Resource, Priority, Mode, Info) ->
    ClientVersion = proplists:get_value(client_version, Info, undefined),
    check_for_sessions_to_replace(User, Server, Resource, Mode),
    set_session(SID, User, Server, Resource, Priority, Mode, Info),
    JID = jid:make(User, Server, Resource),
    IPInfo = proplists:get_value(ip, Info),
    IP = util:parse_ip_address(IPInfo),
    CC = mod_geodb:lookup(IP),
    AppType = util_uid:get_app_type(User),
    ?INFO("U: ~p R: ~p Mode: ~p, AppType: ~p, ClientVersion: ~p, IP: ~s, CC: ~s",
        [User, Resource, Mode, AppType, ClientVersion, IP, CC]),
    ejabberd_hooks:run(sm_register_connection_hook, AppType, [SID, JID, Mode, Info]).


-spec close_session(sid(), binary(), binary(), binary()) -> ok.
close_session(SID, User, Server, Resource) ->
    ?INFO("SID: ~p User: ~p", [SID, User]),
    JID = jid:make(User, Server, Resource),
    Sessions = get_sessions(User, Server, Resource),
    AppType = util_uid:get_app_type(User),
    {Mode, Info} = case lists:keyfind(SID, #session.sid, Sessions) of
        #session{mode = M, info = I} = Session ->
            delete_session(Session),
            {M, I};
        _ ->
            ?WARNING("Unable to find session, User: ~p, SID: ~p", [User, SID]),
            {undefined, []}
    end,
    %% TODO(murali@): Fix this hook to only have SID and JID here.
    ejabberd_hooks:run(sm_remove_connection_hook, AppType, [SID, JID, Mode, Info]),
    ok.

-spec bounce_sm_packet({warn | term(), stanza()}) -> any().
bounce_sm_packet({warn, Packet} = Acc) ->
    FromJid = pb:get_from(Packet),
    ToJid = pb:get_to(Packet),
    ?WARNING("FromUid: ~p, ToUid: ~p, packet: ~p",
            [FromJid, ToJid, Packet]),
    {stop, Acc};
bounce_sm_packet({_, Packet} = Acc) ->
    FromUid = pb:get_from(Packet),
    ToUid = pb:get_to(Packet),
    ?INFO("FromUid: ~p, ToUid: ~p, packet: ~p", [FromUid, ToUid, Packet]),
    Acc.

-spec disconnect_removed_user(binary(), binary()) -> ok.
disconnect_removed_user(User, Server) ->
    route(jid:make(User, Server), {close, account_deleted}).

get_user_resources(User, Server) ->
    Ss = get_sessions(User, Server),
    [element(3, S#session.usr) || S <- clean_session_list(Ss)].

-spec get_user_present_resources(binary(), binary()) -> [tuple()].

get_user_present_resources(LUser, LServer) ->
    Ss = get_sessions(LUser, LServer),
    [{S#session.priority, element(3, S#session.usr)}
     || S <- clean_session_list(Ss), is_integer(S#session.priority)].

-spec get_user_ip(binary(), binary(), binary()) -> ip().

get_user_ip(User, Server, Resource) ->
    case get_sessions(User, Server, Resource) of
        [] ->
            undefined;
        Ss ->
            Session = lists:max(Ss),
            proplists:get_value(ip, Session#session.info)
    end.

-spec get_user_info(binary(), binary()) -> [{binary(), info()}].
get_user_info(User, Server) ->
    Ss = get_sessions(User, Server),
    [{LResource, [{node, node(Pid)}, {ts, Ts}, {pid, Pid},
          {priority, Priority} | Info]}
     || #session{usr = {_, _, LResource},
         priority = Priority,
         info = Info,
         sid = {Ts, Pid}} <- clean_session_list(Ss)].

-spec get_user_info(binary(), binary(), binary()) -> info() | offline.
get_user_info(User, Server, Resource) ->
    Results = get_user_info(User, Server),
    case lists:filter(fun({Resource1, _Info}) -> Resource1 =:= Resource end, Results) of
        [] -> offline;
        [{Resource, Info}] -> Info
    end.

-spec get_session_pid(binary(), binary(), binary()) -> none | pid().
get_session_pid(User, Server, Resource) ->
    case get_session_sid(User, Server, Resource) of
        {_, PID} -> PID;
        none -> none
    end.

-spec get_session_sid(binary(), binary(), binary()) -> none | sid().
get_session_sid(User, Server, Resource) ->
    case get_sessions(User, Server, Resource) of
        [] ->
            none;
        Ss ->
            #session{sid = SID} = lists:max(Ss),
            SID
    end.

-spec get_session_sids(binary(), binary()) -> [sid()].
get_session_sids(User, Server) ->
    Sessions = get_sessions(User, Server),
    [SID || #session{sid = SID} <- Sessions].

-spec get_session_sids(binary(), binary(), binary()) -> [sid()].
get_session_sids(User, Server, Resource) ->
    Sessions = get_sessions(User, Server, Resource),
    [SID || #session{sid = SID} <- Sessions].


-spec dirty_get_my_sessions_list() -> [[#session{}]].
dirty_get_my_sessions_list() ->
    ets:match(?SM_LOCAL, '$1').


-spec config_reloaded() -> ok.
config_reloaded() ->
    ok.


-spec is_user_online(User :: binary()) -> boolean().
is_user_online(User) ->
    case get_active_sessions(User, util:get_host()) of
        [] -> false;
        _ -> true
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    ets_init(),
    gen_iq_handler:start(?MODULE),
    ejabberd_hooks:add(host_up, ?MODULE, host_up, 50),
    ejabberd_hooks:add(host_down, ?MODULE, host_down, 60),
    ejabberd_hooks:add(config_reloaded, ?MODULE, config_reloaded, 50),
    lists:foreach(fun host_up/1, ejabberd_option:hosts()),
    ejabberd_commands:register_commands(get_commands_spec()),
    {ok, #state{}}.

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lists:foreach(fun host_down/1, ejabberd_option:hosts()),
    final_session_cleanup(),
    ejabberd_hooks:delete(host_up, ?MODULE, host_up, 50),
    ejabberd_hooks:delete(host_down, ?MODULE, host_down, 60),
    ejabberd_hooks:delete(config_reloaded, ?MODULE, config_reloaded, 50),
    ejabberd_commands:unregister_commands(get_commands_spec()),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------


-spec host_up(binary()) -> ok.
host_up(Host) ->
    ejabberd_hooks:add(bounce_sm_packet, halloapp, ?MODULE, bounce_sm_packet, 100),
    ejabberd_hooks:add(bounce_sm_packet, katchup, ?MODULE, bounce_sm_packet, 100),
    ejabberd_hooks:add(bounce_sm_packet, ?PHOTO_SHARING, ?MODULE, bounce_sm_packet, 100),
    halloapp_c2s:host_up(Host).

-spec host_down(binary()) -> ok.
host_down(Host) ->
    ejabberd_hooks:delete(bounce_sm_packet, halloapp, ejabberd_sm, bounce_sm_packet, 100),
    ejabberd_hooks:delete(bounce_sm_packet, katchup, ejabberd_sm, bounce_sm_packet, 100),
    ejabberd_hooks:delete(bounce_sm_packet, ?PHOTO_SHARING, ejabberd_sm, bounce_sm_packet, 100),
    halloapp_c2s:host_down(Host).

% Close down all the c2s processes 
close_all_c2s() ->
    % TODO: send 'shutdown' reason to all clients.
    N = ets_count_sessions(),
    ?INFO("Closing ~p c2s processes", [N]),

    NumSessions = ets_sm_local_foldl(
        fun (#session{sid = {_, Pid}}, Acc) when node(Pid) == node() ->
                ?INFO("stopping c2s ~p", [Pid]),
                halloapp_c2s:close(Pid, shutdown),
                Acc + 1;
            (S, Acc) ->
                ?ERROR("found remote session in local ets table. Should not happen ~p", [S]),
                Acc
        end, 0),
    ?INFO("closed ~p sessions", [NumSessions]),
    ok.


final_session_cleanup() ->
    N = ets_count_sessions(),
    ?INFO("Final cleanup of ~p sessions", [N]),

    NumSessions = ets_sm_local_foldl(
        fun (#session{sid = {_, Pid}} = S, Acc) when node(Pid) == node() ->
                db_delete_session(S),
                Acc + 1;
            (S, Acc) ->
                ?ERROR("found remote session in local ets table. Should not happen ~p", [S]),
                Acc
        end, 0),
    ?INFO("closed ~p sessions", [NumSessions]),
    ok.

-spec wait_for_c2s_to_terminate(Timeout :: integer()) -> ok.
wait_for_c2s_to_terminate(Timeout) when Timeout =< 0 ->
    ok;
wait_for_c2s_to_terminate(Timeout) ->
    N = ets_count_sessions(),
    case N of
        0 -> ok;
        _ ->
            ?INFO("Still waiting for ~ts c2s processes to terminate", [N]),
            timer:sleep(50),
            wait_for_c2s_to_terminate(Timeout - 50)
    end.

-spec set_session(sid(), binary(), binary(), binary(),
                  prio(), mode(), info()) -> ok | {error, any()}.
set_session(SID, User, Server, Resource, Priority, Mode, Info) ->
    US = {User, Server},
    USR = {User, Server, Resource},
    set_session(#session{sid = SID, usr = USR, us = US, mode = Mode,
        priority = Priority, info = Info}).

-spec set_session(#session{}) -> ok | {error, any()}.
set_session(#session{sid = Sid, us = {LUser, _LServer}} = Session) ->
    ?INFO("Uid: ~s Sid: ~p", [LUser, Sid]),
    Res = case db_set_session(Session) of
        ok ->
            ok;
        {error, _} = Err ->
            Err
    end,
    ets_insert_sesssion(Session),
    Res.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% get_sessions: includes both passive and active.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_sessions(binary(), binary()) -> [#session{}].
get_sessions(LUser, _LServer) ->
    {ok, Ss} = db_get_sessions(LUser),
    delete_dead(Ss).

-spec get_sessions(binary(), binary(), binary()) -> [#session{}].
get_sessions(LUser, LServer, <<"">>) ->
    get_sessions(LUser, LServer);
get_sessions(LUser, LServer, LResource) ->
    Sessions = get_sessions(LUser, LServer),
    filter_sessions(Sessions, LResource).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% get_active_sessions: includes only active sessions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_active_sessions(binary(), binary()) -> [#session{}].
get_active_sessions(LUser, _LServer) ->
    {ok, Ss} = db_get_active_sessions(LUser),
    delete_dead(Ss).


-spec get_active_sessions(binary(), binary(), binary()) -> [#session{}].
get_active_sessions(LUser, LServer, <<"">>) ->
    get_active_sessions(LUser, LServer);
get_active_sessions(LUser, LServer, LResource) ->
    Sessions = get_active_sessions(LUser, LServer),
    filter_sessions(Sessions, LResource).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% get_passive_sessions: includes only passive sessions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_passive_sessions(binary(), binary()) -> [#session{}].
get_passive_sessions(LUser, _LServer) ->
    {ok, Ss} = db_get_passive_sessions(LUser),
    delete_dead(Ss).


-spec get_passive_sessions(binary(), binary(), binary()) -> [#session{}].
get_passive_sessions(LUser, LServer, <<"">>) ->
    get_passive_sessions(LUser, LServer);
get_passive_sessions(LUser, LServer, LResource) ->
    Sessions = get_passive_sessions(LUser, LServer),
    filter_sessions(Sessions, LResource).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% db related functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec db_set_session(Session :: session()) -> ok | {error, any()}.
db_set_session(Session) ->
    {Uid, _Server} = Session#session.us,
    model_session:set_session(Uid, Session).

-spec db_delete_session(Session :: session()) -> ok | {error, any()}.
db_delete_session(Session) ->
    {Uid, _Server} = Session#session.us,
    model_session:del_session(Uid, Session).


-spec db_get_sessions(uid()) -> {ok, [#session{}]}.
db_get_sessions(Uid) ->
    Sessions = model_session:get_sessions(Uid),
    {ok, Sessions}.


-spec db_get_active_sessions(uid()) -> {ok, [#session{}]}.
db_get_active_sessions(Uid) ->
    Sessions = model_session:get_active_sessions(Uid),
    {ok, Sessions}.


-spec db_get_passive_sessions(uid()) -> {ok, [#session{}]}.
db_get_passive_sessions(Uid) ->
    Sessions = model_session:get_passive_sessions(Uid),
    {ok, Sessions}.


-spec is_session_active(Session :: session()) -> boolean().
is_session_active(Session) ->
    proplists:get_value(mode, Session#session.info) =:= active.


-spec filter_sessions(Sessions :: [session()], Resource :: binary()) -> [session()].
filter_sessions(Sessions, Resource) ->
    [S || S <- Sessions, element(3, S#session.usr) == Resource].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Activates a passive session with SID.
-spec check_and_activate_session(Uid :: binary(), SID :: term()) -> ok.
check_and_activate_session(Uid, SID) ->
    Server = util:get_host(),
    %% Fetch current active sessions and close if necessary.
    case get_active_sessions(Uid, Server) of
        [] ->
            %% No active sessions found.
            ?INFO("No active sessions found for Uid: ~s", [Uid]),
            activate_passive_session(Uid, SID);
        [#session{sid = SID, mode = active}] ->
            %% Session is already active. Nothing to do here.
            ?WARNING("Uid: ~s, user session is already active.", [Uid]);
        [Session] ->
            %% Some other active session is found in db.
            %% Close that session and activate existing passive session.
            {_, Pid} = Session#session.sid,
            ?INFO("Sending replaced to session: ~p, Uid: ~p", [Session#session.sid, Uid]),
            halloapp_c2s:route(Pid, replaced),
            activate_passive_session(Uid, SID);
        Sessions ->
            ?CRITICAL("Should never happen: multiple active sessions found, Uid: ~p", [Uid]),
            lists:foreach(
                fun(#session{sid = {_, Pid}} = Session) ->
                    ?INFO("Sending replaced to session: ~p, Uid: ~p", [Session#session.sid, Uid]),
                    halloapp_c2s:route(Pid, replaced)
                end, Sessions),
            activate_passive_session(Uid, SID)
    end.


-spec activate_passive_session(Uid :: binary(), SID :: term()) -> ok.
activate_passive_session(Uid, SID) ->
    %% Lookup session using key.
    case model_session:get_session(Uid, SID) of
        {error, missing} ->
            ?ERROR("No sessions found for Sid: ~s", [SID]);
        {ok, Session} ->
            {Uid, _} = Session#session.us,
            {_, Pid} = Session#session.sid,
            CurrentMode = Session#session.mode,
            case CurrentMode of
                active ->
                    %% this should not happen since we already check this in activate_session.
                    ?ERROR("Uid: ~s, user session: ~p is already active.", [Uid, SID]);
                passive ->
                    ?INFO("Uid: ~s, activating user_session: ~p", [Uid, SID]),
                    NewSession = Session#session{mode = active},
                    halloapp_c2s:route(Pid, activate_session),
                    set_session(NewSession)
            end
    end.


-spec delete_session(#session{}) -> ok.
delete_session(#session{sid = Sid} = Session) ->
    ?INFO("SID: ~p", [Sid]),
    db_delete_session(Session),
    ets_delete_session(Session),
    ok.

-spec delete_dead([#session{}]) -> [#session{}].
delete_dead(Sessions) ->
    lists:filter(
        fun(#session{sid = {_, Pid}} = Session) ->
            case remote_is_process_alive(Pid) of
                true -> true;
                false ->
                    ?WARNING("Pid: ~p is dead. Cleaning up old sessions ~p", [Pid, Session]),
                    stat:count("HA/sessions", "cleanup_dead", 1),
                    db_delete_session(Session),
                    false
            end
    end, Sessions).


remote_is_process_alive(Pid) ->
    stat:count("HA/sessions", "remote_is_process_alive", 1),
    case rpc:call(node(Pid), erlang, is_process_alive, [Pid], 5000) of
        {badrpc, Reason} ->
            ?ERROR("Pid: ~p badrpc ~p", [Pid, Reason]),
            true;
        Result -> Result
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%% Any kind of routing logic here: always use active sessions.
%%%%% Passive sessions have their own logic separately to route on their own c2s process.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec do_route(jid(), term()) -> any().
do_route(#jid{lresource = <<"">>} = To, Term) ->
    lists:foreach(
        fun(R) ->
            do_route(jid:replace_resource(To, R), Term)
        end, get_user_resources(To#jid.user, To#jid.server));
do_route(To, Term) ->
    ?DEBUG("Broadcasting ~p to ~ts", [Term, jid:encode(To)]),
    {U, S, R} = jid:tolower(To),
    case get_active_sessions(U, S, R) of
        [] ->
            ?DEBUG("Dropping broadcast to unavailable resourse: ~p", [Term]);
        Ss ->
            NumSessions = length(Ss),
            case NumSessions > 1 of
                true -> ?WARNING("Uid: ~p, NumSessions: ~p", [U, NumSessions]);
                false -> ok
            end,
            Session = lists:max(Ss),
            Pid = element(2, Session#session.sid),
            ?DEBUG("Sending to process ~p: ~p", [Pid, Term]),
            halloapp_c2s:route(Pid, Term)
    end.

-spec do_route(stanza()) -> any().
do_route(#pb_msg{} = Packet) ->
    route_message(Packet);
do_route(#pb_iq{to_uid = <<"">>, from_uid = FromUid} = Packet) ->
    AppType = util_uid:get_app_type(FromUid),
    ejabberd_hooks:run_fold(bounce_sm_packet, AppType, {pass, Packet}, []);
do_route(Packet) ->
    ?DEBUG("Processing packet: ~p", [Packet]),
    LUser = pb:get_to(Packet),
    AppType = util_uid:get_app_type(LUser),
    LServer = util:get_host(),
    LResource = <<>>,
    case get_active_sessions(LUser, LServer, LResource) of
        [] ->
            case Packet of
            #pb_presence{} ->
                ejabberd_hooks:run_fold(bounce_sm_packet,
                            AppType, {pass, Packet}, []);
            #pb_chat_state{} ->
                ejabberd_hooks:run_fold(bounce_sm_packet,
                            AppType, {pass, Packet}, []);
            _ ->
                ejabberd_hooks:run_fold(bounce_sm_packet,
                            AppType, {warn, Packet}, [])
            end;
        Ss ->
            Session = lists:max(Ss),
            Pid = element(2, Session#session.sid),
            ?DEBUG("Sending to process ~p, packet:~p", [Pid, Packet]),
            halloapp_c2s:route(Pid, {route, Packet})
    end.


-spec route_message(message()) -> any().
route_message(#pb_msg{} = Packet) ->
    MsgId = pb:get_id(Packet),
    LUser = pb:get_to(Packet),
    AppType = util_uid:get_app_type(LUser),
    LServer = util:get_host(),
    %% Ignore presence information and just rely on the connection state.
    case check_privacy_and_dest_uid(Packet) of
        allow ->
            %% Store the message regardless of user having sessions or not.
            store_offline_message(Packet),
            %% send the message to the user's active c2s process if it exists.
            case get_active_sessions(LUser, LServer, <<>>) of
                [] ->
                    %% If no online sessions, just send push via apple/google
                    push_message(Packet);
                Ss ->
                    %% pick the latest session
                    Session = lists:max(Ss),
                    Pid = element(2, Session#session.sid),
                    ?INFO("route To: ~s -> pid ~p MsgId: ~s", [LUser, Pid, MsgId]),
                    % NOTE: message will be lost if the dest PID dies while routing
                    halloapp_c2s:route(Pid, {route, Packet}),
                    %% This hook can now be used to send push notifications for messages always.
                    ejabberd_hooks:run(push_message_always_hook, AppType, [Packet])
            end;
        {deny, privacy_violation} ->
            %% Ignore the packet and stop routing it now.
            ok;
        {deny, invalid_to_uid} ->
            ?INFO("Invalid To uid: ~s packet received: ~p", [LUser, Packet]),
            Err = util:err(invalid_to_uid),
            ErrorPacket = pb:make_error(Packet, Err),
            ejabberd_router:route(ErrorPacket)
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Keeps only one session per resource. Picks the one with highest sid.
-spec clean_session_list([#session{}]) -> [#session{}].
clean_session_list(Ss) ->
    clean_session_list(lists:keysort(#session.usr, Ss), []).

-spec clean_session_list([#session{}], [#session{}]) -> [#session{}].
clean_session_list([], Res) -> Res;
clean_session_list([S], Res) -> [S | Res];
clean_session_list([S1, S2 | Rest], Res) ->
    if S1#session.usr == S2#session.usr ->
        if S1#session.sid > S2#session.sid ->
          clean_session_list([S1 | Rest], Res);
          true -> clean_session_list([S2 | Rest], Res)
        end;
        true -> clean_session_list([S2 | Rest], [S1 | Res])
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% On new session, check if some existing connections need to be replace
-spec check_for_sessions_to_replace(binary(), binary(), binary(), atom()) -> ok | replaced.
check_for_sessions_to_replace(User, Server, _Resource, active) ->
    %% Replace any active sessions if available.
    lists:foreach(
        fun(#session{sid = {_, Pid} = SID}) ->
            ?INFO("Sending replaced to session: ~p, Uid: ~p", [SID, User]),
            halloapp_c2s:route(Pid, replaced)
        end, get_active_sessions(User, Server)),
    ok;
check_for_sessions_to_replace(User, Server, _Resource, passive) ->
    %% Replace oldest passive session if we exceed our limit of max_passive_sessions.
    PassiveSessions = get_passive_sessions(User, Server),
    NumSessions = length(PassiveSessions),
    case length(PassiveSessions) < ?MAX_PASSIVE_SESSIONS of
        true ->
            ?INFO("Uid: ~p, NumSessions: ~p", [User, PassiveSessions]),
            ok;
        false ->
            SIDs = [SID || #session{sid = SID} <- PassiveSessions],
            SIDsToReplace = lists:sublist(lists:reverse(lists:sort(SIDs)),
                ?MAX_PASSIVE_SESSIONS, NumSessions - ?MAX_PASSIVE_SESSIONS),
            lists:foreach(
                fun({_, Pid} = SID) ->
                    ?INFO("Sending replaced to session: ~p, Uid: ~p", [SID, User]),
                    halloapp_c2s:route(Pid, replaced)
                end, SIDsToReplace)
    end.


-spec is_existing_resource(binary(), binary(), binary()) -> boolean().
is_existing_resource(LUser, LServer, LResource) ->
    [] /= get_resource_sessions(LUser, LServer, LResource).

-spec get_resource_sessions(binary(), binary(), binary()) -> [sid()].
get_resource_sessions(User, Server, Resource) ->
    [S#session.sid || S <- get_sessions(User, Server, Resource)].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%--------------------------------------------------------------------
%%% Local ETS table
%%--------------------------------------------------------------------

-spec ets_init() -> ok.
ets_init() ->
    ets:new(?SM_LOCAL, [
        set,
        public,
        named_table,
        {keypos, 2},
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    ets:new(?SM_COUNTERS, [
        set,
        public,
        named_table,
        {keypos, 1},
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% SM_COUNTERS ets table to count active vs passive sessions.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

ets_sm_counters_exists() ->
    case ets:whereis(?SM_COUNTERS) of
        undefined -> false;
        _ -> true
    end.

-spec ets_increment_counter(session()) -> ok.
ets_increment_counter(#session{mode=Mode} = _Session) ->
    case ets_sm_counters_exists() of
        true ->
            ets:update_counter(?SM_COUNTERS, Mode, 1, {Mode, 0});
        false ->
            ?WARNING("ets table ~p is gone", [?SM_COUNTERS]),
            ok
    end.

-spec ets_decrement_counter(session()) -> ok.
ets_decrement_counter(#session{mode=Mode} = _Session) ->
    case ets_sm_counters_exists() of
        true ->
            ets:update_counter(?SM_COUNTERS, Mode, -1, {Mode, 0});
        false ->
            ?WARNING("ets table ~p is gone", [?SM_COUNTERS]),
            ok
    end.

-spec ets_count_active_sessions() -> integer().
ets_count_active_sessions() ->
    ets_count_mode_sessions(active).

-spec ets_count_passive_sessions() -> integer().
ets_count_passive_sessions() ->
    ets_count_mode_sessions(passive).

-spec ets_count_mode_sessions(Mode :: atom()) -> integer().
ets_count_mode_sessions(Mode) ->
    try
        %% lookup won't throw exception if no keys match Mode
        SessionCounters = ets:lookup(?SM_COUNTERS, Mode),
        case SessionCounters of
            %% if no keys match Mode, then there are no Mode sessions
            [] ->
                0;
            [{Mode, Count}] ->
                Count
        end
    catch
        Class : Reason : St ->
        ?INFO("crashed ets_count_mode_sessions, table: ~p, Mode: ~p Stacktrace: ~ts",
            [?SM_COUNTERS, Mode, lager:pr_stacktrace(St, {Class, Reason})]),
        0
    end.
    


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% SM_LOCAL ets table to hold all sessions.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

ets_sm_local_exists() ->
    case ets:whereis(?SM_LOCAL) of
        undefined -> false;
        _ -> true
    end.

% TODO: (nikola): ejabberd_sm terminates before all the c2s processes
% and the functions below start crashing if we don't check for the ets table first
-spec ets_insert_sesssion(session()) -> boolean().
ets_insert_sesssion(#session{} = Session) ->
    case ets_sm_local_exists() of
        true ->
            Result = ets:insert(?SM_LOCAL, Session),
            ets_increment_counter(Session),
            Result;
        false ->
            ?WARNING("ets table ~p is gone", [?SM_LOCAL]),
            false
    end.


-spec ets_delete_session(session()) -> true.
ets_delete_session(#session{} = Session) ->
    case ets_sm_local_exists() of
        true ->
            Result = ets:delete_object(?SM_LOCAL, Session),
            ets_decrement_counter(Session),
            Result;
        false ->
            ?WARNING("ets table ~p is gone", [?SM_LOCAL]),
            false
    end.

-spec ets_count_sessions() -> non_neg_integer().
ets_count_sessions() ->
    case ets_sm_local_exists() of
        true ->
            ets:info(?SM_LOCAL, size);
        false ->
            ?WARNING("ets table ~p is gone", [?SM_LOCAL]),
            0
    end.

%% You can use this function to iterate over all the local sessions on this
%% node.
-spec ets_sm_local_foldl(Func, Acc :: term()) -> term() when
    Func :: fun((Session :: session(), AccIn) -> AccOut),
    AccIn :: term(),
    AccOut :: term().
ets_sm_local_foldl(Func, Acc) ->
    case ets_sm_local_exists() of
        true ->
            ets:foldl(Func, Acc, ?SM_LOCAL);
        false ->
            ?WARNING("ets table ~p is gone", [?SM_LOCAL]),
            Acc
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% ejabberd commands

get_commands_spec() ->
    [#ejabberd_commands{name = connected_users, tags = [session],
            desc = "List all established sessions on this node",
                        policy = admin,
            module = ?MODULE, function = connected_users, args = [],
            result_desc = "List of users sessions",
            result_example = [<<"user1@example.com">>, <<"user2@example.com">>],
            result = {connected_users, {list, {sessions, string}}}},
     #ejabberd_commands{name = connected_users_number, tags = [session, stats],
            desc = "Get the number of established sessions on this node",
                        policy = admin,
            module = ?MODULE, function = connected_users_number,
            result_example = 2,
            args = [], result = {num_sessions, integer}},
     #ejabberd_commands{name = user_resources, tags = [session],
            desc = "List user's connected resources",
                        policy = admin,
            module = ?MODULE, function = user_resources,
            args = [{user, binary}, {host, binary}],
            args_desc = ["User name", "Server name"],
            args_example = [<<"user1">>, <<"example.com">>],
            result_example = [<<"tka1">>, <<"Gajim">>, <<"mobile-app">>],
            result = {resources, {list, {resource, string}}}},
     #ejabberd_commands{name = kick_user, tags = [session],
            desc = "Disconnect user's active sessions",
            module = ?MODULE, function = kick_user,
            args = [{user, binary}, {host, binary}],
            args_desc = ["User name", "Server name"],
            args_example = [<<"user1">>, <<"example.com">>],
            result_desc = "Number of resources that were kicked",
            result_example = 3,
            result = {num_resources, integer}}].

-spec connected_users() -> [binary()].

connected_users() ->
    Uids = [Uid || [#session{usr = Uid}] <- dirty_get_my_sessions_list()],
    lists:sort(Uids).

connected_users_number() ->
    ets_count_sessions().

user_resources(User, Server) ->
    Resources = get_user_resources(User, Server),
    lists:sort(Resources).

-spec kick_user(binary(), binary()) -> non_neg_integer().
kick_user(User, Server) ->
    Resources = get_user_resources(User, Server),
    lists:foldl(
        fun(Resource, Acc) ->
            case kick_user(User, Server, Resource) of
                false -> Acc;
                true -> Acc + 1
            end
        end, 0, Resources).

-spec kick_user(binary(), binary(), binary()) -> boolean().
kick_user(User, Server, Resource) ->
    case get_session_pid(User, Server, Resource) of
        none -> false;
        Pid -> halloapp_c2s:route(Pid, kick)
    end.

make_sid() ->
    {misc:unique_timestamp(), self()}.

