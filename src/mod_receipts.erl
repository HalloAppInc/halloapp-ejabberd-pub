%%%----------------------------------------------------------------------
%%% File    : mod_receipts.erl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%
%%% This module registers using the user_send_packet hook to be notified 
%%% on every new packet received by the server. If the packet is a message stanza
%%% and if it is about a receipt of the message by a client to another client,
%%% the server updates the timestamp on the receipt and returns the new packet.
%%% This is useful so that the clients need not worry about having the wrong
%%% timestamp on the devices.
%%% Currently, we do this for both delivery and seen receipts.
%%%----------------------------------------------------------------------

-module(mod_receipts).
-author('murali').
-behaviour(gen_mod).

-dialyzer({no_match, log_delivered/1}).

-include("logger.hrl").
-include("packets.hrl").
-include("ha_types.hrl").
-include("offline_message.hrl").


%% gen_mod API.
-export([start/2, stop/1, depends/2, mod_options/1, reload/3]).
%% Hooks and API.
-export([
    user_ack_packet/2,
    get_thread_id/1
]).

start(_Host, _Opts) ->
    ejabberd_hooks:add(user_ack_packet, halloapp, ?MODULE, user_ack_packet, 10),
    ejabberd_hooks:add(user_ack_packet, katchup, ?MODULE, user_ack_packet, 10).

stop(_Host) ->
    ejabberd_hooks:delete(user_ack_packet, halloapp, ?MODULE, user_ack_packet, 10),
    ejabberd_hooks:delete(user_ack_packet, katchup, ?MODULE, user_ack_packet, 10).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


%% Hook triggered when user sent the server an ack stanza for this particular message.
-spec user_ack_packet(Ack :: ack(), OfflineMessage :: offline_message()) -> ok.
user_ack_packet(#pb_ack{id = Id, from_uid = FromUid}, #offline_message{content_type = ContentType,
        from_uid = MsgFromId, thread_id = ThreadId, message = Message})
        when ContentType =:= chat; ContentType =:= group_chat; ContentType =:= pb_chat_stanza;
        ContentType =:= pb_group_chat_stanza; ContentType =:= pb_group_chat ->
    ?INFO("Uid: ~s, Id: ~p, ContentType: ~p", [FromUid, Id, ContentType]),
    case enif_protobuf:decode(Message, pb_packet) of
        {error, DecodeReason} ->
            ?ERROR("MsgId: ~p, Message: ~p, failed decoding reason: ~s", [Id, Message, DecodeReason]);
        #pb_packet{stanza = #pb_msg{payload = Payload}} ->
            case Payload of
                #pb_chat_stanza{chat_type = chat_reaction} -> ok;
                _ ->
                    %% Count only chat stanzas here.
                    Timestamp = util:now(),
                    send_receipt(MsgFromId, FromUid, Id, ThreadId, Timestamp),
                    log_delivered(ContentType)
            end;
        DecodedPacket ->
            ?ERROR("MsgId: ~p, Message: ~p, failed decoding packet: ~p", [Id, Message, DecodedPacket]),
            Timestamp = util:now(),
            send_receipt(MsgFromId, FromUid, Id, ThreadId, Timestamp)
    end;
user_ack_packet(_, _) ->
    ok.


%% Send a delivery receipt to the ToUid from FromUid using Id and Timestamp.
-spec send_receipt(ToUid :: binary(), FromUid :: binary(), Id :: binary(),
        ThreadId :: binary(), Timestamp :: integer()) -> ok.
send_receipt(ToUid, FromUid, Id, ThreadId, Timestamp) ->
    ?INFO("FromUid: ~s, ToUid: ~s, Id: ~p, ThreadId: ~p, Timestamp: ~p",
            [FromUid, ToUid, Id, ThreadId, Timestamp]),
    MessageReceipt = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = ToUid,
        from_uid = FromUid,
        payload = #pb_delivery_receipt{
            id = Id,
            thread_id = ThreadId,
            timestamp = Timestamp}},
    ejabberd_router:route(MessageReceipt).


log_delivered(chat) ->
    stat:count("HA/im_receipts", "delivered");
log_delivered(pb_chat_stanza) ->
    stat:count("HA/im_receipts", "delivered");
log_delivered(group_chat) ->
    stat:count("HA/group_im_receipts", "delivered");
log_delivered(pb_group_chat) ->
    stat:count("HA/group_im_receipts", "delivered");
log_delivered(pb_group_chat_stanza) ->
    stat:count("HA/group_im_receipts", "delivered");
log_delivered(_) -> ok.


% Try to extract the gid from the binary message
-spec get_thread_id(Message :: message()) -> maybe(binary()).
get_thread_id(#pb_msg{payload = Payload}) ->
    case Payload of
        #pb_group_chat{gid = Gid} -> Gid;
        #pb_group_chat_stanza{gid = Gid} -> Gid;
        _ -> undefined
    end.

