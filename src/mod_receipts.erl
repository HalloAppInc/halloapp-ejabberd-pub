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
-include("offline_message.hrl").


%% gen_mod API.
-export([start/2, stop/1, depends/2, mod_options/1, reload/3]).
%% Hooks.
-export([user_ack_packet/2]).

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
-spec user_ack_packet(Ack :: ack(), OfflineMessage :: offline_message()) -> ok.
user_ack_packet(#ack{id = Id, from = #jid{server = ServerHost} = AckFrom},
        #offline_message{content_type = ContentType, from_uid = MsgFromId, message = Msg})
        when ContentType =:= <<"chat">>; ContentType =:= <<"group_chat">> ->
    TimestampSec = util:now_binary(),
    FromJID = AckFrom,
    ToJID = jid:make(MsgFromId, ServerHost),
    ThreadId = get_thread_id(Msg),
    send_receipt(ToJID, FromJID, Id, ThreadId, TimestampSec),
    log_delivered(ContentType);

user_ack_packet(_, _) ->
    ok.


%% Send a delivery receipt to the ToJID from FromJID using Id and Timestamp.
-spec send_receipt(ToJID :: jid(), FromJID :: jid(), Id :: binary(),
        ThreadId :: binary(), Timestamp :: binary()) -> ok.
send_receipt(ToJID, FromJID, Id, ThreadId, Timestamp) ->
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
-spec get_thread_id(Message :: binary()) -> binary().
get_thread_id(Message) ->
    case fxml_stream:parse_element(Message) of
        {error, Reason} ->
            ?ERROR("failed to parse: ~p, reason: ~s", [Message, Reason]),
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

