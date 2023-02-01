%%%-------------------------------------------------------------------
%%% File    : mod_server_ts.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%-------------------------------------------------------------------
-module(mod_server_ts).
-behaviour(gen_mod).

-include("packets.hrl").
-include("logger.hrl").


%% gen_mod API.
-export([
    start/2,
    stop/1,
    reload/3,
    mod_options/1,
    depends/2
]).

%% Hooks and API.
-export([
    user_send_packet/1,
    user_receive_packet/1
]).


start(_Host, _Opts) ->
    ejabberd_hooks:add(user_send_packet, halloapp, ?MODULE, user_send_packet, 25),
    ejabberd_hooks:add(user_send_packet, katchup, ?MODULE, user_send_packet, 25),
    ejabberd_hooks:add(user_receive_packet, katchup, ?MODULE, user_receive_packet, 25),
    ok.

stop(_Host) ->
    ejabberd_hooks:delete(user_send_packet, halloapp, ?MODULE, user_send_packet, 25),
    ejabberd_hooks:delete(user_send_packet, katchup, ?MODULE, user_send_packet, 25),
    ejabberd_hooks:delete(user_receive_packet, katchup, ?MODULE, user_receive_packet, 25),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% hooks.
%%====================================================================

user_send_packet({#pb_msg{id = MsgId, from_uid = FromUid, to_uid = ToUid} = Packet, State}) ->
    PayloadType = util:get_payload_type(Packet),
    Timestamp = util:now(),
    Packet1 = util:set_timestamp(Packet, Timestamp),
    ?INFO("setting timestamp MsgId: ~p Ts: ~p", [MsgId, PayloadType, Timestamp]),
    ?INFO("FromUid: ~p PayloadType: ~p ToUid: ~p, MsgId: ~p", [FromUid, PayloadType, ToUid, MsgId]),
    {Packet1, State};

user_send_packet({_Packet, _State} = Acc) ->
    Acc.


user_receive_packet({#pb_msg{id = MsgId, from_uid = FromUid, to_uid = ToUid} = Packet, State}) ->
    PayloadType = util:get_payload_type(Packet),
    ?INFO("FromUid: ~p PayloadType: ~p ToUid: ~p, MsgId: ~p", [FromUid, PayloadType, ToUid, MsgId]),
    {Packet, State};

user_receive_packet({_Packet, _State} = Acc) ->
    Acc.

