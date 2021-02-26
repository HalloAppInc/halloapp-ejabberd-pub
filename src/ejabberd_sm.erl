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
    route/1,
    route/2,
    open_session/5,
    open_session/6,
    activate_session/2,
    is_session_active/1,
    close_session/4,
    push_message/1,
    bounce_sm_packet/1,
    disconnect_removed_user/2,
    get_user_resources/2,
    get_user_present_resources/2,
    set_presence/6,
    unset_presence/5,
    close_session_unset_presence/5,
    dirty_get_my_sessions_list/0,
    ets_count_sessions/0,
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
    get_max_user_sessions/2,
    is_existing_resource/3,
    get_commands_spec/0,
    host_up/1,
    host_down/1,
    make_sid/0,
    config_reloaded/0
]).

%% TODO(murali@): This module has to be refactored soon!!

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("packets.hrl").
-include("ejabberd_commands.hrl").
-include("ejabberd_sm.hrl").
-include("ejabberd_stacktrace.hrl").
-include("translate.hrl").
-include ("account.hrl").

-record(state, {}).

%% default value for the maximum number of user connections
-define(MAX_USER_SESSIONS, infinity).

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
    _ = supervisor:terminate_child(ejabberd_sup, ?MODULE),
    _ = supervisor:delete_child(ejabberd_sup, ?MODULE),
    _ = supervisor:terminate_child(ejabberd_sup, ejabberd_c2s_sup),
    _ = supervisor:delete_child(ejabberd_sup, ejabberd_c2s_sup),
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
check_privacy_and_dest_uid(#message{to = To, type = _Type} = Packet) ->
    ToUid = To#jid.luser,
    LServer = To#jid.lserver,
    DecodedPacket = xmpp:decode_els(Packet),
    case ejabberd_auth:user_exists(ToUid) of
        true ->
            case ejabberd_hooks:run_fold(privacy_check_packet, LServer, allow,
                    [To, DecodedPacket, in]) of
                allow -> allow;
                deny -> {deny, privacy_violation};
                {stop, deny} -> {deny, privacy_violation}
            end;
        false ->
            {deny, invalid_to_uid}
    end.

% Store the message in the offline store.
-spec store_offline_message(message()) -> message().
store_offline_message(#message{to = To} = Packet) ->
    LServer = To#jid.lserver,
    ejabberd_hooks:run_fold(store_message_hook, LServer, Packet, []).

push_message(#message{to = To} = Packet) ->
    LServer = To#jid.lserver,
    ejabberd_hooks:run_fold(push_message_hook, LServer, Packet, []).


-spec open_session(sid(), binary(), binary(), binary(), prio(), info()) -> ok.

open_session(SID, User, Server, Resource, Priority, Info) ->
    set_session(SID, User, Server, Resource, Priority, Info),
    check_for_sessions_to_replace(User, Server, Resource),
    JID = jid:make(User, Server, Resource),
    ?INFO("U: ~p S: ~p R: ~p JID: ~p", [User, Server, Resource, JID]),
    ejabberd_hooks:run(sm_register_connection_hook, JID#jid.lserver, [SID, JID, Info]).

-spec open_session(sid(), binary(), binary(), binary(), info()) -> ok.

open_session(SID, User, Server, Resource, Info) ->
    open_session(SID, User, Server, Resource, undefined, Info).

-spec close_session(sid(), binary(), binary(), binary()) -> ok.

close_session(SID, User, Server, Resource) ->
    % TODO: remote all those nodeprep. They are not needed.
    ?INFO("SID: ~p User: ~p", [SID, User]),
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    Sessions = get_sessions(LUser, LServer, LResource),
    Info = case lists:keyfind(SID, #session.sid, Sessions) of
       #session{info = I} = Session ->
           delete_session(Session),
           I;
       _ ->
           []
    end,
    JID = jid:make(User, Server, Resource),
    ejabberd_hooks:run(sm_remove_connection_hook, JID#jid.lserver, [SID, JID, Info]).

-spec bounce_sm_packet({warn | term(), stanza()}) -> any().
bounce_sm_packet({warn, Packet} = Acc) ->
    FromJid = util_pb:get_from(Packet),
    ToJid = util_pb:get_to(Packet),
    ?WARNING("FromUid: ~p, ToUid: ~p, packet: ~p",
            [FromJid#jid.luser, ToJid#jid.luser, Packet]),
    {stop, Acc};
bounce_sm_packet({_, Packet} = Acc) ->
    FromUid = util_pb:get_from(Packet),
    ToUid = util_pb:get_to(Packet),
    ?INFO("FromUid: ~p, ToUid: ~p, packet: ~p", [FromUid, ToUid, Packet]),
    Acc.

-spec disconnect_removed_user(binary(), binary()) -> ok.
disconnect_removed_user(User, Server) ->
    route(jid:make(User, Server), {close, account_deleted}).

get_user_resources(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Ss = get_sessions(LUser, LServer),
    [element(3, S#session.usr) || S <- clean_session_list(Ss)].

-spec get_user_present_resources(binary(), binary()) -> [tuple()].

get_user_present_resources(LUser, LServer) ->
    Ss = get_sessions(LUser, LServer),
    [{S#session.priority, element(3, S#session.usr)}
     || S <- clean_session_list(Ss), is_integer(S#session.priority)].

-spec get_user_ip(binary(), binary(), binary()) -> ip().

get_user_ip(User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    case get_sessions(LUser, LServer, LResource) of
        [] ->
            undefined;
        Ss ->
            Session = lists:max(Ss),
            proplists:get_value(ip, Session#session.info)
    end.

-spec get_user_info(binary(), binary()) -> [{binary(), info()}].
get_user_info(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Ss = get_sessions(LUser, LServer),
    [{LResource, [{node, node(Pid)}, {ts, Ts}, {pid, Pid},
          {priority, Priority} | Info]}
     || #session{usr = {_, _, LResource},
         priority = Priority,
         info = Info,
         sid = {Ts, Pid}} <- clean_session_list(Ss)].

-spec get_user_info(binary(), binary(), binary()) -> info() | offline.
get_user_info(User, Server, Resource) ->
    LResource = jid:resourceprep(Resource),
    Results = get_user_info(User, Server),
    case lists:filter(fun({LResource1, _Info}) -> LResource1 =:= LResource end, Results) of
        [] -> offline;
        [{LResource, Info}] -> Info
    end.


% TODO: (nikola): Both set_presence and unset_presence can use helper function to get_session
-spec set_presence(sid(), binary(), binary(), binary(),
                   prio(), presence()) -> ok | {error, notfound}.

set_presence(SID, User, Server, Resource, Priority, Presence) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    case get_sessions(LUser, LServer, LResource) of
        [] -> {error, notfound};
        Ss ->
            case lists:keyfind(SID, #session.sid, Ss) of
                #session{info = Info} ->
                    set_session(SID, User, Server, Resource, Priority, Info),
                    ejabberd_hooks:run(set_presence_hook,
                               LServer,
                               [User, Server, Resource, Presence]);
                false ->
                    {error, notfound}
            end
    end.

-spec unset_presence(sid(), binary(), binary(),
                     binary(), binary()) -> ok | {error, notfound}.

unset_presence(SID, User, Server, Resource, Status) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    case get_sessions(LUser, LServer, LResource) of
        [] -> {error, notfound};
        Ss ->
            case lists:keyfind(SID, #session.sid, Ss) of
                #session{info = Info} ->
                    set_session(SID, User, Server, Resource, undefined, Info),
                    ejabberd_hooks:run(unset_presence_hook,
                               LServer,
                               [User, Server, Resource, Status]);
                false ->
                    {error, notfound}
            end
    end.

-spec close_session_unset_presence(sid(), binary(), binary(),
                                   binary(), binary()) -> ok.

close_session_unset_presence(SID, User, Server,
                 Resource, Status) ->
    ?INFO("SID: ~p User: ~p", [SID, User]),
    close_session(SID, User, Server, Resource),
    ejabberd_hooks:run(unset_presence_hook,
               jid:nameprep(Server),
               [User, Server, Resource, Status]).

-spec get_session_pid(binary(), binary(), binary()) -> none | pid().

get_session_pid(User, Server, Resource) ->
    case get_session_sid(User, Server, Resource) of
        {_, PID} -> PID;
        none -> none
    end.

-spec get_session_sid(binary(), binary(), binary()) -> none | sid().

get_session_sid(User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    case get_sessions(LUser, LServer, LResource) of
        [] ->
            none;
        Ss ->
            #session{sid = SID} = lists:max(Ss),
            SID
    end.

-spec get_session_sids(binary(), binary()) -> [sid()].

get_session_sids(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Sessions = get_sessions(LUser, LServer),
    [SID || #session{sid = SID} <- Sessions].

-spec get_session_sids(binary(), binary(), binary()) -> [sid()].

get_session_sids(User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    Sessions = get_sessions(LUser, LServer, LResource),
    [SID || #session{sid = SID} <- Sessions].


-spec dirty_get_my_sessions_list() -> [#session{}].

dirty_get_my_sessions_list() ->
    ets:match(?SM_LOCAL, '$1').


-spec config_reloaded() -> ok.
config_reloaded() ->
    ok.

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

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lists:foreach(fun host_down/1, ejabberd_option:hosts()),
    close_all_c2s(),
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
    ejabberd_hooks:add(bounce_sm_packet, Host, ?MODULE, bounce_sm_packet, 100),
    ejabberd_c2s:host_up(Host),
    halloapp_c2s:host_up(Host).

-spec host_down(binary()) -> ok.
host_down(Host) ->
    ejabberd_hooks:delete(bounce_sm_packet, Host,
              ejabberd_sm, bounce_sm_packet, 100),
    ejabberd_c2s:host_down(Host),
    halloapp_c2s:host_down(Host).

% Close down all the c2s processes 
close_all_c2s() ->
    Err = case ejabberd_cluster:get_nodes() of
        [Node] when Node == node() -> xmpp:serr_system_shutdown();
        _ -> xmpp:serr_reset()
    end,

    % TODO: (nikola): Here it looks like we send errors to all the sessions when shutting down.
    % Do we want to do this and what will the error be. I think just closing the connection
    % should be enough.

    NumSessions = ets_sm_local_foldl(
        fun (#session{sid = {_, Pid}}, Acc) when node(Pid) == node() ->
                ?INFO("stopping ~p", [Pid]),
                ejabberd_c2s:send(Pid, Err),
                ejabberd_c2s:stop(Pid),
                Acc + 1;
            (S, Acc) ->
                ?WARNING("shoudld not happen ~p", [S]), % we iterate over only local sessions
                Acc
        end, 0),
    ?INFO("closed ~p sessions", [NumSessions]),
    ok.

-spec set_session(sid(), binary(), binary(), binary(),
                  prio(), info()) -> ok | {error, any()}.

set_session(SID, User, Server, Resource, Priority, Info) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    US = {LUser, LServer},
    USR = {LUser, LServer, LResource},
    set_session(#session{sid = SID, usr = USR, us = US,
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

-spec get_sessions(binary(), binary()) -> [#session{}].
get_sessions(LUser, _LServer) ->
    case db_get_sessions(LUser) of
        {ok, Ss} -> delete_dead(Ss);
        _ -> []
    end.

-spec get_sessions(binary(), binary(), binary()) -> [#session{}].
get_sessions(LUser, LServer, <<"">>) ->
    get_sessions(LUser, LServer);
get_sessions(LUser, LServer, LResource) ->
    Sessions = get_sessions(LUser, LServer),
    [S || S <- Sessions, element(3, S#session.usr) == LResource].

-spec db_set_session(Session :: session()) -> ok.
db_set_session(Session) ->
    {Uid, _Server} = Session#session.us,
    {ok, _OldPid} = model_session:set_session(Uid, Session),
    ok.

-spec db_delete_session(Session :: session()) -> ok.
db_delete_session(Session) ->
    {Uid, _Server} = Session#session.us,
    model_session:del_session(Uid, Session).

-spec db_get_sessions(uid()) -> {ok, [#session{}]}.
db_get_sessions(Uid) ->
    Sessions = model_session:get_sessions(Uid),
    {ok, Sessions}.


-spec get_active_sessions(Mod :: module(), LUser :: binary(), LServer :: binary()) -> [session()].
get_active_sessions(Mod, LUser, LServer) ->
    Sessions = get_sessions(Mod, LUser, LServer),
    lists:filter(fun is_session_active/1, Sessions).


-spec is_session_active(Session :: session()) -> boolean().
is_session_active(Session) ->
    proplists:get_value(mode, Session#session.info) =:= active.


%% This code should go away once we have access to c2s state when processing iqs.
%% mod_user_session can directly update the state of the c2s process in that case.
%% TODO(murali@): add new process_local_iq function that also has c2s process state.
-spec activate_session(Uid :: binary(), Server :: binary()) -> ok.
activate_session(Uid, Server) ->
    case get_sessions(Uid, Server) of
        {ok, []} ->
            ?ERROR("No sessions found for uid: ~s", [Uid]);
        {ok, [Session]} ->
            {Uid, _} = Session#session.us,
            {_, Pid} = Session#session.sid,
            Info = Session#session.info,
            CurrentMode = proplists:get_value(mode, Session#session.info),
            case CurrentMode of
                active ->
                    ?WARNING("Uid: ~s, user session is already active.", [Uid]);
                passive ->
                    ?INFO("Uid: ~s, activating user_session", [Uid]),
                    NewInfo = lists:keyreplace(mode, 1, Info, {mode, active}),
                    NewSession = Session#session{info = NewInfo},
                    ejabberd_c2s:route(Pid, activate_session),
                    set_session(NewSession)
            end;
        {ok, _} ->
            ?ERROR("Multiple sessions found for uid: ~s", [Uid])
            %% Ideally, we could use resource to match the session,
            %% but we dont need this until we support multiple devices per user.
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
-spec do_route(jid(), term()) -> any().
do_route(#jid{lresource = <<"">>} = To, Term) ->
    lists:foreach(
        fun(R) ->
            do_route(jid:replace_resource(To, R), Term)
        end, get_user_resources(To#jid.user, To#jid.server));
do_route(To, Term) ->
    ?DEBUG("Broadcasting ~p to ~ts", [Term, jid:encode(To)]),
    {U, S, R} = jid:tolower(To),
    case get_sessions(U, S, R) of
        [] ->
            ?DEBUG("Dropping broadcast to unavailable resourse: ~p", [Term]);
        Ss ->
            Session = lists:max(Ss),
            Pid = element(2, Session#session.sid),
            ?DEBUG("Sending to process ~p: ~p", [Pid, Term]),
            ejabberd_c2s:route(Pid, Term)
    end.

-spec do_route(stanza()) -> any().
do_route(#message{} = Packet) ->
    route_message(Packet);
do_route(#pb_iq{to_uid = <<"">>, type = T} = Packet) ->
    Server = util:get_host(),
    if
        T == set; T == get ->
            ?DEBUG("Processing IQ : ~p", [Packet]),
            gen_iq_handler:handle(?MODULE, Packet);
        true ->
            ejabberd_hooks:run_fold(bounce_sm_packet, Server, {pass, Packet}, [])
    end;
do_route(#iq{to = #jid{lresource = <<"">>} = To, type = T} = Packet) ->
    if
        T == set; T == get ->
            ?DEBUG("Processing IQ to bare JID:~n~ts", [xmpp:pp(Packet)]),
            gen_iq_handler:handle(?MODULE, Packet);
        true ->
            ejabberd_hooks:run_fold(bounce_sm_packet,
                    To#jid.lserver, {pass, Packet}, [])
    end;
do_route(Packet) ->
    ?DEBUG("Processing packet to full JID:~n~ts", [xmpp:pp(Packet)]),
    LUser = util_pb:get_to(Packet),
    LServer = util:get_host(),
    LResource = <<>>,
    case get_sessions(LUser, LServer, LResource) of
        [] ->
            case Packet of
            #message{} ->
                %% TODO(murali@): clean this do_route function properly
                ?WARNING("should-not-happen"),
                route_message(Packet);
            #presence{} ->
                ejabberd_hooks:run_fold(bounce_sm_packet,
                            LServer, {pass, Packet}, []);
            #chat_state{} ->
                ejabberd_hooks:run_fold(bounce_sm_packet,
                            LServer, {pass, Packet}, []);
            #pb_presence{} ->
                ejabberd_hooks:run_fold(bounce_sm_packet,
                            LServer, {pass, Packet}, []);
            #pb_chat_state{} ->
                ejabberd_hooks:run_fold(bounce_sm_packet,
                            LServer, {pass, Packet}, []);
            _ ->
                ejabberd_hooks:run_fold(bounce_sm_packet,
                            LServer, {warn, Packet}, [])
            end;
        Ss ->
            Session = lists:max(Ss),
            Pid = element(2, Session#session.sid),
            ?DEBUG("Sending to process ~p:~n~ts", [Pid, xmpp:pp(Packet)]),
            ejabberd_c2s:route(Pid, {route, Packet})
    end.


-spec route_message(message()) -> any().
route_message(#message{} = Packet) ->
    To = xmpp:get_to(Packet),
    LUser = To#jid.luser,
    LServer = To#jid.lserver,
    LResource = To#jid.lresource,
    %% Ignore presence information and just rely on the connection state.

    DecodedPacket = xmpp:decode_els(Packet),
    case check_privacy_and_dest_uid(DecodedPacket) of
        allow ->
            %% Store the message regardless of user having sessions or not.
            store_offline_message(DecodedPacket),
            %% Irrespective of whether the session is passive or active:
            %% send the message to the user's c2s process if it exists.
            case get_sessions(LUser, LServer, LResource) of
                [] ->
                    %% If no online sessions, just send push via apple/google
                    push_message(DecodedPacket);
                Ss ->
                    %% pick the latest session
                    Session = lists:max(Ss),
                    Pid = element(2, Session#session.sid),
                    ?INFO("route To: ~s -> pid ~p MsgId: ~s", [LUser, Pid, Packet#message.id]),
                    % NOTE: message will be lost if the dest PID dies while routing
                    ejabberd_c2s:route(Pid, {route, DecodedPacket})
            end;
        {deny, privacy_violation} ->
            %% Ignore the packet and stop routing it now.
            ok;
        {deny, invalid_to_uid} ->
            ?ERROR("Invalid To uid: ~s packet received: ~p", [LUser, DecodedPacket]),
            Err = util:xmpp_err(invalid_to_uid),
            ErrorPacket = xmpp:make_error(DecodedPacket, Err),
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
-spec check_for_sessions_to_replace(binary(), binary(), binary()) -> ok | replaced.
check_for_sessions_to_replace(User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    check_existing_resources(LUser, LServer, LResource),
    check_max_sessions(LUser, LServer).

-spec check_existing_resources(binary(), binary(), binary()) -> ok.
check_existing_resources(LUser, LServer, LResource) ->
    Ss = get_sessions(LUser, LServer, LResource),
    if Ss == [] -> ok;
        true ->
        SIDs = [SID || #session{sid = SID} <- Ss],
        MaxSID = lists:max(SIDs),
        lists:foreach(fun ({_, Pid} = S) when S /= MaxSID ->
                        ejabberd_c2s:route(Pid, replaced);
                    (_) -> ok
                    end,
                    SIDs)
    end.

-spec is_existing_resource(binary(), binary(), binary()) -> boolean().

is_existing_resource(LUser, LServer, LResource) ->
    [] /= get_resource_sessions(LUser, LServer, LResource).

-spec get_resource_sessions(binary(), binary(), binary()) -> [sid()].
get_resource_sessions(User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    [S#session.sid || S <- get_sessions(LUser, LServer, LResource)].

-spec check_max_sessions(binary(), binary()) -> ok | replaced.
check_max_sessions(LUser, LServer) ->
    Ss = get_sessions(LUser, LServer),
    MaxSessions = get_max_user_sessions(LUser, LServer),
    if
        length(Ss) =< MaxSessions -> ok;
        true ->
            #session{sid = {_, Pid}} = lists:min(Ss),
            ejabberd_c2s:route(Pid, replaced)
    end.

%% Get the user_max_session setting
%% This option defines the max number of time a given users are allowed to
%% log in
%% Defaults to infinity
-spec get_max_user_sessions(binary(), binary()) -> infinity | non_neg_integer().
get_max_user_sessions(LUser, Host) ->
    case ejabberd_shaper:match(Host, max_user_sessions,
                   jid:make(LUser, Host)) of
        Max when is_integer(Max) -> Max;
        infinity -> infinity;
        _ -> ?MAX_USER_SESSIONS
    end.

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
    ok.

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
            ets:insert(?SM_LOCAL, Session);
        false ->
            ?WARNING("ets table ~p is gone", [?SM_LOCAL]),
            false
    end.


-spec ets_delete_session(session()) -> true.
ets_delete_session(#session{} = Session) ->
    case ets_sm_local_exists() of
        true ->
            ets:delete_object(?SM_LOCAL, Session);
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
    Uids = [Uid || #session{us = {Uid, _}} <- dirty_get_my_sessions_list()],
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
        Pid -> ejabberd_c2s:route(Pid, kick)
    end.

make_sid() ->
    {misc:unique_timestamp(), self()}.
