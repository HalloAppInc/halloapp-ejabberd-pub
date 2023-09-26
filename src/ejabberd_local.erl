%%%----------------------------------------------------------------------
%%% File    : ejabberd_local.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Route local packets
%%% Created : 30 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_local).

-author('alexey@process-one.net').

-behaviour(gen_server).

%% API
-export([start/0, start_link/0]).

-export([
    route/1,
    bounce_resource_packet/1,
    host_up/1,
    host_down/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("stanza.hrl").
-include("packets.hrl").
-include("ejabberd_stacktrace.hrl").
-include("translate.hrl").

-record(state, {}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start() ->
    ChildSpec = {?MODULE, {?MODULE, start_link, []}, transient, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

start_link() ->
    ?INFO("start ~w", [?MODULE]),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec route(stanza()) -> ok.
route(Packet) ->
    ?DEBUG("Local route:~p", [Packet]),
    FromUid = pb:get_from(Packet),
    Type = pb:get_type(Packet),
    ToUid = pb:get_to(Packet),
    Payload = pb:get_payload_type(Packet),
    AppType = util_uid:get_app_type(FromUid),
    if
        ToUid =/= <<"">> ->
            ejabberd_sm:route(Packet);
        is_record(Packet, pb_iq), ToUid =:= <<"">> ->
            gen_iq_handler:handle(?MODULE, Packet);
        Type =:= result orelse Type =:= error ->
            ok;
        is_record(Packet, pb_msg), Payload =:= pb_group_chat ->
            ejabberd_hooks:run(group_message, AppType, [Packet]);
        is_record(Packet, pb_msg), Payload =:= pb_group_chat_stanza ->
            ejabberd_hooks:run(group_message, AppType, [Packet]);
        is_record(Packet, pb_msg), Payload =:= pb_group_chat_retract ->
            ejabberd_hooks:run(group_message, AppType, [Packet]);
        is_record(Packet, pb_msg), Type =:= groupchat ->
            ejabberd_hooks:run(group_message, AppType, [Packet]);
        true ->
            ejabberd_hooks:run(local_send_to_resource_hook, AppType, [Packet])
    end.

-spec bounce_resource_packet(stanza()) -> ok | stop.
bounce_resource_packet(Packet) ->
    ?ERROR("Invalid packet received: ~p", [Packet]),
    Err = util:err(invalid_packet),
    ErrorPacket = pb:make_error(Packet, Err),
    ejabberd_router:route(ErrorPacket),
    stop.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    lists:foreach(fun host_up/1, ejabberd_option:hosts()),
    ejabberd_hooks:add(host_up, ?MODULE, host_up, 10),
    ejabberd_hooks:add(host_down, ?MODULE, host_down, 100),
    gen_iq_handler:start(?MODULE),
    update_table(),
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

handle_info({route, Packet}, State) ->
    route(Packet),
    {noreply, State};
handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lists:foreach(fun host_down/1, ejabberd_option:hosts()),
    ejabberd_hooks:delete(host_up, ?MODULE, host_up, 10),
    ejabberd_hooks:delete(host_down, ?MODULE, host_down, 100),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
-spec update_table() -> ok.
update_table() ->
    catch mnesia:delete_table(iq_response),
    ok.

host_up(Host) ->
    Owner = case whereis(?MODULE) of
        undefined -> self();
        Pid -> Pid
    end,
    ejabberd_router:register_route(Host, Host, {apply, ?MODULE, route}, Owner),
    ejabberd_hooks:add(local_send_to_resource_hook, halloapp, ?MODULE, bounce_resource_packet, 100),
    ejabberd_hooks:add(local_send_to_resource_hook, katchup, ?MODULE, bounce_resource_packet, 100).

host_down(Host) ->
    Owner = case whereis(?MODULE) of
        undefined -> self();
        Pid -> Pid
    end,
    ejabberd_router:unregister_route(Host, Owner),
    ejabberd_hooks:delete(local_send_to_resource_hook, halloapp, ?MODULE, bounce_resource_packet, 100),
    ejabberd_hooks:delete(local_send_to_resource_hook, katchup, ?MODULE, bounce_resource_packet, 100).
