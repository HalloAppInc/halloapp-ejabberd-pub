-module(mod_ha_stats).
-author('nikola').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("pubsub.hrl").

-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

-export([
    pubsub_publish_item/7,
    register_user/3,
    re_register_user/2,
    add_friend/3,
    remove_friend/3,
    user_send_packet/1,
    user_receive_packet/1
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(pubsub_publish_item, Host, ?MODULE, pubsub_publish_item, 50),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_friend, Host, ?MODULE, remove_friend, 50),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ok.


stop(Host) ->
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(remove_friend, Host, ?MODULE, remove_friend, 50),
    ejabberd_hooks:delete(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(pubsub_publish_item, Host, ?MODULE, pubsub_publish_item, 50),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{stat, hard}].

mod_options(_Host) ->
    [].


-spec pubsub_publish_item(Server :: binary(), Node :: binary(), Publisher :: jid(),
        Host :: jid(), ItemId :: binary(), ItemType :: binary(), Payloads :: [xmlel()]) -> ok.
pubsub_publish_item(_Server, _Node, Publisher, _Host, _ItemId, ItemType, _Payloads) ->
    ?INFO_MSG("counting uid:~p ItemType:~p", [Publisher, ItemType]),
    case ItemType of
        feedpost ->
            ?INFO_MSG("post",[]),
            stat:count("HA/feed", "post");
        comment ->
            ?INFO_MSG("comment",[]),
            stat:count("HA/feed", "comment");
        _ -> ok
    end,
    ok.


-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
register_user(Uid, _Server, _Phone) ->
    ?INFO_MSG("counting uid:~s", [Uid]),
    stat:count("HA/account", "registration"),
    ok.


-spec re_register_user(Uid :: binary(), Server :: binary()) -> ok.
re_register_user(Uid, _Server) ->
    ?INFO_MSG("counting uid:~s", [Uid]),
    stat:count("HA/account", "re_register"),
    ok.


-spec add_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
add_friend(Uid, _Server, _ContactId) ->
    ?INFO_MSG("counting uid:~s", [Uid]),
    stat:count("HA/graph", "add_friend"),
    ok.


-spec remove_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
remove_friend(Uid, _Server, _ContactId) ->
    ?INFO_MSG("counting uid:~s", [Uid]),
    stat:count("HA/graph", "remove_friend"),
    ok.

-spec user_send_packet({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
user_send_packet({Packet, _State} = Acc) ->
    ?INFO_MSG("Packet: ~p", [Packet]),
    stat:count("HA/user_send_packet", "packet"),
    count_send_packet(Packet),
    Acc.

-spec count_send_packet(Packet :: stanza()) -> ok.
count_send_packet(#ack{}) ->
    stat:count("HA/user_send_packet", "ack");
count_send_packet(#message{sub_els = [SubEl | _Rest]}) ->
    stat:count("HA/user_send_packet", "message"),
    case SubEl of
        #chat{} ->
            stat:count("HA/messaging", "send_im");
        _ -> ok
    end;
count_send_packet(#presence{}) ->
    stat:count("HA/user_send_packet", "presence");
count_send_packet(#iq{}) ->
    stat:count("HA/user_send_packet", "iq");
count_send_packet(_Packet) ->
    stat:count("HA/user_send_packet", "unknown"),
    ok.


-spec user_receive_packet({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
user_receive_packet({#binary_message{} = _BinMessage, _State} = Acc) ->
    stat:count("HA/user_receive_packet", "binary_message"),
    Acc;
user_receive_packet({#message{sub_els = [#receipt_seen{}]}, _State} = Acc) ->
    stat:count("HA/im_receipts", "seen"),
    Acc;
user_receive_packet({#message{sub_els = [#receipt_response{}]}, _State} = Acc) ->
    stat:count("HA/im_receipts", "received"),
    Acc;
user_receive_packet({_Packet, _State} = Acc) ->
    % TODO: implement other types
    Acc.

