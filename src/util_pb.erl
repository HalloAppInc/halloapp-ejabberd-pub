%%%----------------------------------------------------------------------
%%% File    : util_pb.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the utility functions related to pb packets
%%%----------------------------------------------------------------------

-module(util_pb).
-author('murali').
-include("logger.hrl").
-include("xmpp.hrl").
-include("server.hrl").
-include("ha_types.hrl").

-export([
    get_to/1,
    get_from/1,
    set_to/2,
    set_from/2,
    set_to_from/3,
    is_pb_packet/1,
    get_packet_type/1,
    get_payload_type/1,
    get_type/1,
    make_iq_result/1,
    make_iq_result/2,
    make_error/2,
    get_id/1,
    set_id/2
]).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.


-spec get_to(pb_packet()) -> binary().
get_to(#pb_iq{to_uid = ToUid}) -> ToUid;
get_to(#pb_msg{to_uid = ToUid}) -> ToUid;
get_to(#pb_presence{to_uid = ToUid}) -> ToUid;
get_to(#pb_chat_state{to_uid = ToUid}) -> ToUid;
get_to(#pb_ack{to_uid = ToUid}) -> ToUid;
get_to(Pkt) ->
    To = xmpp:get_to(Pkt),
    To#jid.luser.


-spec get_from(pb_packet()) -> binary().
get_from(#pb_iq{from_uid = FromUid}) -> FromUid;
get_from(#pb_msg{from_uid = FromUid}) -> FromUid;
get_from(#pb_presence{from_uid = FromUid}) -> FromUid;
get_from(#pb_chat_state{from_uid = FromUid}) -> FromUid;
get_from(#pb_ack{from_uid = FromUid}) -> FromUid;
get_from(Pkt) ->
    From = xmpp:get_from(Pkt),
    From#jid.luser.


-spec set_to(pb_packet(), binary()) -> pb_packet().
set_to(#pb_iq{} = Pkt, ToUid) -> Pkt#pb_iq{to_uid = ToUid};
set_to(#pb_msg{} = Pkt, ToUid) -> Pkt#pb_msg{to_uid = ToUid};
set_to(#pb_presence{} = Pkt, ToUid) -> Pkt#pb_presence{to_uid = ToUid};
set_to(#pb_chat_state{} = Pkt, ToUid) -> Pkt#pb_chat_state{to_uid = ToUid};
set_to(#pb_ack{} = Pkt, ToUid) -> Pkt#pb_ack{to_uid = ToUid};
set_to(Pkt, ToUid) ->
    Server = util:get_host(),
    xmpp:set_to(Pkt, jid:make(ToUid, Server)).


-spec set_from(pb_packet(), binary()) -> pb_packet().
set_from(#pb_iq{} = Pkt, FromUid) -> Pkt#pb_iq{from_uid = FromUid};
set_from(#pb_msg{} = Pkt, FromUid) -> Pkt#pb_msg{from_uid = FromUid};
set_from(#pb_presence{} = Pkt, FromUid) -> Pkt#pb_presence{from_uid = FromUid};
set_from(#pb_chat_state{} = Pkt, FromUid) -> Pkt#pb_chat_state{from_uid = FromUid};
set_from(#pb_ack{} = Pkt, FromUid) -> Pkt#pb_ack{from_uid = FromUid};
set_from(Pkt, FromUid) ->
    Server = util:get_host(),
    xmpp:set_from(Pkt, jid:make(FromUid, Server)).


-spec set_to_from(pb_packet(), binary(), binary()) -> pb_packet().
set_to_from(Pkt, ToUid, FromUid) -> set_from(set_to(Pkt, ToUid), FromUid).


-spec get_type(pb_packet()) -> atom().
get_type(#pb_iq{type = Type}) -> Type;
get_type(#pb_msg{type = Type}) -> Type;
get_type(#pb_presence{type = Type}) -> Type;
get_type(#pb_chat_state{type = Type}) -> Type;
get_type(#pb_ack{}) -> undefined.


-spec get_id(pb_packet()) -> undefined | binary().
get_id(#pb_iq{id = Id}) -> Id;
get_id(#pb_msg{id = Id}) -> Id;
get_id(#pb_presence{id = Id}) -> Id;
get_id(#pb_chat_state{}) -> undefined;
get_id(#pb_ack{id = Id}) -> Id;
get_id(Pkt) ->
    xmpp:get_id(Pkt).


-spec set_id(pb_packet(), binary()) -> pb_packet().
set_id(#pb_iq{} = Pkt, Id) -> Pkt#pb_iq{id = Id};
set_id(#pb_msg{} = Pkt, Id) -> Pkt#pb_msg{id = Id};
set_id(#pb_presence{} = Pkt, Id) -> Pkt#pb_presence{id = Id};
set_id(#pb_chat_state{} = Pkt, Id) -> Pkt;
set_id(#pb_ack{} = Pkt, Id) -> Pkt#pb_ack{id = Id};
set_id(Pkt, Id) ->
    xmpp:set_id(Pkt, Id).


-spec is_pb_packet(Packet :: stanza()) -> boolean().
is_pb_packet(#pb_iq{}) -> true;
is_pb_packet(#pb_msg{}) -> true;
is_pb_packet(#pb_presence{}) -> true;
is_pb_packet(#pb_chat_state{}) -> true;
is_pb_packet(#pb_ack{}) -> true;
is_pb_packet(_) -> false.


-spec get_packet_type(Packet :: stanza()) -> atom.
get_packet_type(#pb_iq{}) -> pb_iq;
get_packet_type(#pb_msg{}) -> pb_msg;
get_packet_type(#pb_presence{}) -> pb_presence;
get_packet_type(#pb_chat_state{}) -> pb_chat_state;
get_packet_type(#pb_ack{}) -> pb_ack.


-spec get_payload_type(Packet :: stanza()) -> atom.
get_payload_type(#pb_iq{payload = undefined}) -> undefined;
get_payload_type(#pb_msg{payload = undefined}) -> undefined;
get_payload_type(#pb_iq{payload = Payload}) -> util:to_atom(element(1, Payload));
get_payload_type(#pb_msg{payload = Payload}) -> util:to_atom(element(1, Payload));
get_payload_type(_) -> undefined.


-spec make_iq_result(Iq :: pb_iq()) -> pb_iq().
make_iq_result(#pb_iq{} = Iq) ->
    make_iq_result(Iq, undefined).


-spec make_iq_result(Iq :: pb_iq(), Payload :: any()) -> pb_iq().
make_iq_result(#pb_iq{to_uid = ToUid, from_uid = FromUid} = Iq, Payload) ->
    Iq#pb_iq{type = result, to_uid = FromUid, from_uid = ToUid, payload = Payload}.


-spec make_error(Pkt :: pb_iq() | pb_msg(), Payload :: any()) -> pb_iq() | pb_msg().
make_error(#pb_iq{to_uid = ToUid, from_uid = FromUid} = Iq, Error) ->
    Iq#pb_iq{type = error, to_uid = FromUid, from_uid = ToUid, payload = Error};
make_error(#pb_msg{to_uid = ToUid, from_uid = FromUid} = Msg, Error) ->
    Msg#pb_msg{type = error, to_uid = FromUid, from_uid = ToUid, payload = Error}.


