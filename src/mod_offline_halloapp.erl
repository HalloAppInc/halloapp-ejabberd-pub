%%%----------------------------------------------------------------------
%%% File    : mod_offline_halloapp.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% TODO(murali@): Add limit for max number of messages per user. 
%%%----------------------------------------------------------------------
%% TODO(murali@): rename this file later.
-module(mod_offline_halloapp).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("offline_message.hrl").

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% API and hooks.
-export([
    offline_message_hook/1,
    user_receive_packet/1,
    user_send_ack/1,
    c2s_self_presence/1,
    remove_user/2,
    count_user_messages/1
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message_hook, 10),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ejabberd_hooks:add(user_send_ack, Host, ?MODULE, user_send_ack, 50),
    ejabberd_hooks:add(c2s_self_presence, Host, ?MODULE, c2s_self_presence, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50).

stop(Host) ->
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message_hook, 10),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 10),
    ejabberd_hooks:delete(user_send_ack, Host, ?MODULE, user_send_ack, 50),
    ejabberd_hooks:delete(c2s_self_presence, Host, ?MODULE, c2s_self_presence, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%      API and hooks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec user_send_ack(Packet :: ack()) -> ok.
user_send_ack(#ack{id = MsgId, from = #jid{user = UserId, server = Server}} = Ack) ->
    {ok, OfflineMessage} = model_messages:get_message(UserId, MsgId),
    case OfflineMessage of
        undefined ->
            ?WARNING_MSG("missing a message on redis, msg_id: ~s, from_uid: ~s", [MsgId, UserId]);
        _ ->
            ok = model_messages:ack_message(UserId, MsgId),
            case OfflineMessage#offline_message.content_type of
                <<"chat">> ->
                    ejabberd_hooks:run(user_ack_packet, Server, [{Ack, OfflineMessage}]);
                _ -> ok
            end
    end.


offline_message_hook({Action, #message{} = Message} = _Acc) ->
    NewMessage = adjust_id_and_store_message(Message),
    {Action, NewMessage}.


user_receive_packet({Packet, #{lserver := _ServerHost} = State} = _Acc)
        when is_record(Packet, message) ->
    NewMessage = adjust_id_and_store_message(Packet),
    {NewMessage, State};
user_receive_packet(Acc) ->
    Acc.


c2s_self_presence({#presence{type = available}, #{jid := JID}} = Acc) ->
    route_offline_messages(JID),
    Acc;
c2s_self_presence(Acc) ->
    Acc.


remove_user(User, _Server) ->
    ?INFO_MSG("removing all user messages, uid: ~s", [User]),
    model_messages:remove_all_user_messages(User).


-spec count_user_messages(UserId :: binary()) -> integer().
count_user_messages(User) ->
    {ok, Res} = model_messages:count_user_messages(User),
    Res.


%% TODO(murali@): Add logic to increment retry count.
-spec route_offline_messages(JID :: jid()) -> ok.
route_offline_messages(#jid{luser = UserId, lserver = ServerHost}) ->
    {ok, OfflineMessages} = model_messages:get_all_user_messages(UserId),
    lists:foreach(
        fun(OfflineMessage) ->
            case OfflineMessage of
                undefined ->
                    ok;
                _ ->
                    FromUid = OfflineMessage#offline_message.from_uid,
                    ToUid = OfflineMessage#offline_message.to_uid,
                    ?INFO_MSG("sending offline message from_uid: ~s to_uid: ~s", [FromUid, ToUid]),
                    To = jid:make(ToUid, ServerHost),
                    From = case FromUid of
                                undefined -> jid:make(ServerHost);
                                FromUid -> jid:make(FromUid, ServerHost)
                            end,
                    ejabberd_router:route(#binary_message{to = To, from = From,
                            message = OfflineMessage#offline_message.message})
            end
        end, OfflineMessages).


-spec adjust_id_and_store_message(message()) -> message().
adjust_id_and_store_message(Message) ->
    NewMessage = xmpp:set_id_if_missing(Message, util:new_msg_id()),
    ok = model_messages:store_message(NewMessage),
    NewMessage.

