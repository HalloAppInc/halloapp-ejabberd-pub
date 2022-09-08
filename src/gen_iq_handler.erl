%%%----------------------------------------------------------------------
%%% File    : gen_iq_handler.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : IQ handler support
%%% Created : 22 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
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

-module(gen_iq_handler).

-author('alexey@process-one.net').

%% API
-export([
    add_iq_handler/5,
    add_iq_handler/6,
    remove_iq_handler/3,
    handle/2,
    handle/3,
    start/1
]).

-include("logger.hrl").
-include("packets.hrl").
-include("translate.hrl").
-include("ejabberd_stacktrace.hrl").

-type component() :: ejabberd_sm | ejabberd_local.
-type state() :: halloapp_c2s:state().

%%====================================================================
%% API
%%====================================================================
-spec start(component()) -> ok.
start(Component) ->
    catch ets:new(Component, [named_table, public, ordered_set,
        {read_concurrency, true},
        {heir, erlang:group_leader(), none}]),
    ok.


-spec add_iq_handler(component(), binary(), atom(), module(), atom()) -> ok.
add_iq_handler(Component, Host, NS, Module, Function) ->
    add_iq_handler(Component, Host, NS, Module, Function, 1).


-spec add_iq_handler(component(), binary(), atom(), module(), atom(), integer()) -> ok.
add_iq_handler(Component, Host, NS, Module, Function, NumArgs) ->
    ets:insert(Component, {{Host, NS}, Module, Function, NumArgs}),
    ok.

-spec remove_iq_handler(component(), binary(), atom()) -> ok.
remove_iq_handler(Component, Host, NS) ->
    ets:delete(Component, {Host, NS}),
    ok.

-spec handle(state() | atom(), iq()) -> state().
handle(State, #pb_iq{to_uid = ToUid} = IQ) ->
    Component = case ToUid of
        <<"">> -> ejabberd_local;
        _ -> ejabberd_sm
    end,
    handle(State, Component, IQ).

-spec handle(state() | atom(), component(), iq()) -> state().
%% TODO(murali@): cleanup and have a simpler module after the transition.
handle(State, _, #pb_iq{type = T, payload = undefined} = Packet)
        when T == get; T == set ->
    ErrIq = pb:make_error(Packet, util:err(invalid_iq)),
    halloapp_c2s:route(State, {route, ErrIq});
handle(State, Component, #pb_iq{type = T, payload = _Payload} = Packet)
        when T == get; T == set ->
    PayloadType = util:get_payload_type(Packet),
    Host = util:get_host(),
    case ets:lookup(Component, {Host, PayloadType}) of
        [{_, Module, Function, NumArgs}] ->
            %% if we return ignore for our process_local_iq functions:
            %% we need to ensure to send the iq-response back on the same c2s process.
            case process_iq(Host, Module, Function, NumArgs, Packet, State) of
                {ignore, NewState} -> NewState;
                {#pb_iq{} = Iq, NewState} -> halloapp_c2s:route(NewState, {route, Iq})
            end;
        [] ->
            ?ERROR("Invalid iq: ~p", [Packet]),
            ErrIq = pb:make_error(Packet, util:err(invalid_iq)),
            halloapp_c2s:route(State, {route, ErrIq})
    end;
handle(State, _, #pb_iq{type = T}) when T == result; T == error ->
    State.


-spec process_iq(binary(), atom(), atom(), integer(), iq(), state()) -> {ignore | iq(), state()}.
process_iq(_Host, Module, Function, NumArgs, IQ, State) ->
    try process_iq(Module, Function, NumArgs, IQ, State)
    catch ?EX_RULE(Class, Reason, St) ->
        StackTrace = ?EX_STACK(St),
        ?ERROR("Failed to process iq: ~p~n Stacktrace: ~s", [
            IQ,
            lager:pr_stacktrace(StackTrace, {Class, Reason})]),
        {pb:make_error(IQ, util:err(internal_error)), State}
    end.

-spec process_iq(module(), atom(), integer(), iq(), state()) -> {ignore | iq(), state()}.
process_iq(Module, Function, NumArgs, IQ, State) when is_record(IQ, pb_iq) ->
    case NumArgs of
        1 -> {Module:Function(IQ), State};
        2 ->
            case Module:Function(IQ, State) of
                {_ResponseIQ, _NewState} = Result -> Result;
                ResponseIQ -> {ResponseIQ, State}
            end;
        _ ->
            ?ERROR("Invalid NumArgs: ~p for Module: ~p, Function: ~p", [NumArgs, Module, Function]),
            {ignore, State}
    end.
