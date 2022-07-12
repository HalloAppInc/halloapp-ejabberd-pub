%%%----------------------------------------------------------------------
%%% File    : mod_ping.erl
%%% Author  : Brian Cully <bjc@kublai.com>
%%% Purpose : Support XEP-0199 XMPP Ping and periodic keepalives
%%% Created : 11 Jul 2009 by Brian Cully <bjc@kublai.com>
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
%%% TODO(murali@): using maps in a process_state and then canceling and creating timers
%%% over and over is not great. this will get very overloaded at scale: we should have each
%%% c2s process manage their own timers to ping or not and act accordingly
%%% and use an ets table to store.
%%%
%%%----------------------------------------------------------------------

-module(mod_ping).

-author('bjc@kublai.com').

-protocol({xep, 199, '2.0'}).

-behaviour(gen_mod).

-behaviour(gen_server).

-include("logger.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("time.hrl").
-include("ha_types.hrl").
-include("proc.hrl").
-include("ejabberd_sm.hrl").

-define(PING_ACTIVE_INTERVAL, 30 * ?SECONDS_MS).
-define(PING_PASSIVE_INTERVAL, 15 * ?SECONDS_MS).
-define(ACK_TIMEOUT, 5 * ?SECONDS_MS).

%% API
-export([start_ping/2, stop_ping/2]).

%% gen_mod callbacks
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% gen_server callbacks
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

% hooks
-export([
    iq_ping/1,
    sm_register_connection_hook/4,
    sm_remove_connection_hook/4,
    user_send_packet/1,
    user_session_activated/3
]).

-record(state, {
    host                :: binary(),
    timers              :: timers()
}).


-type state() :: #state{}.
-type session_info() :: #session_info{}.
-type timers() :: #{session_info() => reference()}.

%%====================================================================
%% API
%%====================================================================

-spec start_ping(binary(), session_info()) -> ok.
start_ping(_Host, SessionInfo) ->
    gen_server:cast(?PROC(), {start_ping, SessionInfo}).


-spec stop_ping(binary(), session_info()) -> ok.
stop_ping(_Host, SessionInfo) ->
    gen_server:cast(?PROC(), {stop_ping, SessionInfo}).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()).


stop(_Host) ->
    gen_mod:stop_child(?PROC()).


reload(Host, NewOpts, OldOpts) ->
    gen_server:cast(?PROC(), {reload, Host, NewOpts, OldOpts}).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    process_flag(trap_exit, true),
    Opts = gen_mod:get_module_opts(Host, ?MODULE),
    State = init_state(Host, Opts),
    register_iq_handlers(Host),
    register_hooks(Host),
    {ok, State}.


terminate(_Reason, #state{host = Host}) ->
    unregister_hooks(Host),
    unregister_iq_handlers(Host).


handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast({reload, Host, NewOpts, _OldOpts}, #state{timers = Timers} = _OldState) ->
    NewState = init_state(Host, NewOpts),
    register_hooks(Host),
    {noreply, NewState#state{timers = Timers}};
handle_cast({start_ping, SessionInfo}, State) ->
    NewState = add_timer(SessionInfo, State),
    {noreply, NewState};
handle_cast({stop_ping, SessionInfo}, State) ->
    NewState = del_timer(SessionInfo, State),
    {noreply, NewState};
handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info({iq_reply, #pb_iq{type = error, payload = #error_st{reason = user_session_not_found}},
        SessionInfo}, State) ->
    NewState = del_timer(SessionInfo, State),
    {noreply, NewState};

handle_info({iq_reply, #pb_iq{}, SessionInfo}, State) ->
    ?INFO("receive_ping, Uid: ~s, SessionInfo: ~p", [SessionInfo#session_info.uid, SessionInfo]),
    {noreply, State};

%% handler for when the device doesn't respond to a ping w/in 30s.
handle_info({iq_reply, timeout, SessionInfo}, State) ->
    ?INFO("ping_timeout, Uid: ~s, SessionInfo: ~p", [SessionInfo#session_info.uid, SessionInfo]),
    ejabberd_hooks:run(user_ping_timeout, State#state.host, [SessionInfo]),
    User = SessionInfo#session_info.uid,
    Resource = SessionInfo#session_info.resource,
    case ejabberd_sm:get_session_pid(User, State#state.host, Resource) of
        Pid when is_pid(Pid) -> halloapp_c2s:close(Pid, ping_timeout);
        _ -> ok
    end,
    NewState = del_timer(SessionInfo, State),
    {noreply, NewState};

%% handler for ping timer. sends new ping to device
handle_info({timeout, _TRef, {ping, SessionInfo}}, State) ->
    Uid = SessionInfo#session_info.uid,
    {_, UserPid} = SessionInfo#session_info.sid,
    ?INFO("send_ping to Uid: ~p, SessionInfo: ~p", [Uid, SessionInfo]),
    IQ = #pb_iq{to_uid = SessionInfo#session_info.uid, type = get, payload = #pb_ping{}},
    ejabberd_iq:route(IQ, UserPid, ?PROC(), SessionInfo, ?ACK_TIMEOUT),
    NewState = add_timer(SessionInfo, State),
    {noreply, NewState};

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%====================================================================
%% Hook callbacks
%%====================================================================
-spec iq_ping(pb_iq()) -> pb_iq().
iq_ping(#pb_iq{type = get, payload = #pb_ping{}} = IQ) ->
    pb:make_iq_result(IQ);
iq_ping(#pb_iq{} = IQ) ->
    ?ERROR("Invalid iq: ~p", [IQ]),
    pb:make_error(IQ, util:err(invalid_iq)).

-spec sm_register_connection_hook(ejabberd_sm:sid(), jid(), mode(), ejabberd_sm:info()) -> ok.
sm_register_connection_hook(SID, JID, Mode, _Info) ->
    SessionInfo = #session_info{
        uid = JID#jid.luser,
        resource = JID#jid.lresource,
        sid = SID,
        mode = Mode
    },
    start_ping(JID#jid.lserver, SessionInfo).

-spec sm_remove_connection_hook(ejabberd_sm:sid(), jid(), mode(), ejabberd_sm:info()) -> ok.
sm_remove_connection_hook(SID, JID, Mode, _Info) ->
    SessionInfo = #session_info{
        uid = JID#jid.luser,
        resource = JID#jid.lresource,
        sid = SID,
        mode = Mode
    },
    stop_ping(JID#jid.lserver, SessionInfo).

-spec user_send_packet({stanza(), halloapp_c2s:state()}) -> {stanza(), halloapp_c2s:state()}.
user_send_packet({Packet, #{jid := JID, sid := SID, mode := Mode} = C2SState}) ->
    SessionInfo = #session_info{
        uid = JID#jid.luser,
        resource = JID#jid.lresource,
        sid = SID,
        mode = Mode
    },
    start_ping(JID#jid.lserver, SessionInfo),
    {Packet, C2SState}.

-spec user_session_activated(C2SState :: halloapp_c2s:state(), Uid :: binary(), SID :: sid()) -> state().
user_session_activated(#{jid := JID, sid := SID, mode := Mode} = C2SState, Uid, SID) ->
    ?INFO("Uid: ~p, SID: ~p", [Uid, SID]),
    SessionInfo = #session_info{
        uid = Uid,
        resource = JID#jid.lresource,
        sid = SID,
        mode = Mode
    },
    %% This will now update the timer with the new ping interval for this session.
    start_ping(JID#jid.lserver, SessionInfo),
    C2SState.


%%====================================================================
%% Internal functions
%%====================================================================

init_state(Host, _Opts) ->
    #state{
        host = Host,
        timers = #{}
    }.


register_hooks(Host) ->
    ejabberd_hooks:add(sm_register_connection_hook, Host, ?MODULE, sm_register_connection_hook, 100),
    ejabberd_hooks:add(sm_remove_connection_hook, Host, ?MODULE, sm_remove_connection_hook, 100),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:add(user_session_activated, Host, ?MODULE, user_session_activated, 50).


unregister_hooks(Host) ->
    ejabberd_hooks:delete(sm_remove_connection_hook, Host, ?MODULE, sm_remove_connection_hook, 100),
    ejabberd_hooks:delete(sm_register_connection_hook, Host, ?MODULE, sm_register_connection_hook, 100),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(user_session_activated, Host, ?MODULE, user_session_activated, 50).


register_iq_handlers(Host) ->
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, pb_ping, ?MODULE, iq_ping),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_ping, ?MODULE, iq_ping).


unregister_iq_handlers(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_ping),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, pb_ping).


-spec add_timer(SessionInfo :: session_info(), State :: state()) -> state().
add_timer(#session_info{sid = SID} = SessionInfo, State) ->
    Timers1 = State#state.timers,
    Timers2 = case maps:find(SID, Timers1) of
        {ok, {SessionInfo, OldTRef}} ->
            misc:cancel_timer(OldTRef),
            maps:remove(SID, Timers1);
        _ ->
            Timers1
    end,
    PingInterval = fetch_ping_interval(SessionInfo),
    TRef = erlang:start_timer(PingInterval, self(), {ping, SessionInfo}),
    Timers3 = maps:put(SID, {SessionInfo, TRef}, Timers2),
    State#state{timers = Timers3}.


-spec del_timer(SessionInfo :: session_info(), State :: state()) -> state().
del_timer(#session_info{sid = SID} = SessionInfo, State) ->
    Timers1 = State#state.timers,
    Timers2 = case maps:find(SID, Timers1) of
        {ok, {SessionInfo, TRef}} ->
            misc:cancel_timer(TRef),
            maps:remove(SID, Timers1);
        _ ->
            Timers1
    end,
    State#state{timers = Timers2}.


fetch_ping_interval(#session_info{mode = active}) -> ?PING_ACTIVE_INTERVAL;
fetch_ping_interval(#session_info{mode = passive}) -> ?PING_PASSIVE_INTERVAL.


depends(_Host, _Opts) ->
    [].


mod_options(_Host) ->
    [].

