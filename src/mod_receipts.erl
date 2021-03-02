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

-include("logger.hrl").
-include("xmpp.hrl").
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

start(Host, _Opts) ->
    ejabberd_hooks:add(user_ack_packet, Host, ?MODULE, user_ack_packet, 10).

stop(Host) ->
    ejabberd_hooks:delete(user_ack_packet, Host, ?MODULE, user_ack_packet, 10).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


%% Hook triggered when user sent the server an ack stanza for this particular message.
%% TODO(murali@): Some of the offline messages will now have thread_id.
%% Start using that from next month around 02-20-2021.
-spec user_ack_packet(Ack :: ack(), OfflineMessage :: offline_message()) -> ok.
user_ack_packet(#pb_ack{} = Ack, #offline_message{content_type = ContentType, msg_id = MsgId,
        message = Msg, protobuf = true} = OfflineMessage)
        when ContentType =:= <<"chat">>; ContentType =:= <<"group_chat">> ->
    ?INFO("MsgId: ~p, ContentType: ~p", [MsgId, ContentType]),
    NewMsg = case enif_protobuf:decode(Msg, pb_packet) of
        {error, Reason} -> <<>>;
        Packet -> packet_parser:proto_to_xmpp(Packet)
    end,
    NewOfflineMessage = OfflineMessage#offline_message{
        message = NewMsg,
        protobuf = false
    },
    user_ack_packet(Ack, NewOfflineMessage);

user_ack_packet(#pb_ack{id = Id, from_uid = FromUid},
        #offline_message{content_type = ContentType, from_uid = MsgFromId, message = Msg})
        when ContentType =:= <<"chat">>; ContentType =:= <<"group_chat">> ->
    ?INFO("Uid: ~s, Id: ~p, ContentType: ~p", [FromUid, Id, ContentType]),
    Server = util:get_host(),
    TimestampSec = util:now_binary(),
    FromJID = jid:make(FromUid, Server),
    ToJID = jid:make(MsgFromId, Server),
    ThreadId = get_thread_id(Msg),
    send_receipt(ToJID, FromJID, Id, ThreadId, TimestampSec),
    log_delivered(ContentType);

user_ack_packet(_, _) ->
    ok.


%% Send a delivery receipt to the ToJID from FromJID using Id and Timestamp.
-spec send_receipt(ToJID :: jid(), FromJID :: jid(), Id :: binary(),
        ThreadId :: binary(), Timestamp :: binary()) -> ok.
send_receipt(ToJID, FromJID, Id, ThreadId, Timestamp) ->
    ToUid = ToJID#jid.user,
    FromUid = FromJID#jid.user,
    ?INFO("FromUid: ~s, ToUid: ~s, Id: ~p, ThreadId: ~p, Timestamp: ~p",
            [FromUid, ToUid, Id, ThreadId, Timestamp]),
    MessageReceipt = #message{
        id = util:new_msg_id(),
        to = ToJID,
        from = FromJID,
        sub_els = [#receipt_response{
            id = Id,
            thread_id = ThreadId,
            timestamp = Timestamp}]},
    ejabberd_router:route(MessageReceipt).


log_delivered(<<"chat">>) ->
    stat:count("HA/im_receipts", "delivered");
log_delivered(<<"group_chat">>) ->
    stat:count("HA/group_im_receipts", "delivered").


% Try to extract the gid from the binary message
%% TODO(murali@): cleanup this function once we switch everything to protobuf.
-spec get_thread_id(Message :: binary()) -> maybe(binary()).
get_thread_id(#message{sub_els = [SubEl]}) ->
    %% Sending undefined should work as usual.. so updating it here to test further.
    %% This should affect only murali.
    case SubEl of
        #group_chat{gid =  Gid} -> Gid;
        #chat{} -> undefined;   % This is the default case we don't need to send thread_id
        _ -> undefined
    end;
get_thread_id(#pb_msg{payload = Payload}) ->
    case Payload of
        #pb_group_chat{gid = Gid} -> Gid;
        _ -> undefined
    end;
get_thread_id(Message) ->
    case fxml_stream:parse_element(Message) of
        {error, Reason} ->
            ?ERROR("failed to parse: ~p, reason: ~p", [Message, Reason]),
            <<>>;
        MessageXmlEl ->
            try
                Packet = xmpp:decode(MessageXmlEl),
                [Child] = Packet#message.sub_els,
                case Child of
                    #group_chat{gid =  Gid} -> Gid;
                    #chat{} -> <<>>   % This is the default case we don't need to send thread_id
                end
            catch
                Class : Reason : Stacktrace ->
                    ?ERROR("failed to decode message: ~s", [
                        lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
                    <<>>
            end
    end.

