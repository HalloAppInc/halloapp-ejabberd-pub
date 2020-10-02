-module(mod_ha_stats).
-author('nikola').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("pubsub.hrl").

-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

-export([
    publish_feed_item/5,
    feed_item_published/3,
    feed_item_retracted/3,
    register_user/3,
    re_register_user/3,
    add_friend/3,
    remove_friend/3,
    user_send_packet/1,
    user_receive_packet/1
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(publish_feed_item, Host, ?MODULE, publish_feed_item, 50),
    ejabberd_hooks:add(feed_item_published, Host, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:add(feed_item_retracted, Host, ?MODULE, feed_item_retracted, 50),
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
    ejabberd_hooks:delete(publish_feed_item, Host, ?MODULE, publish_feed_item, 50),
    ejabberd_hooks:delete(feed_item_published, Host, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:delete(feed_item_retracted, Host, ?MODULE, feed_item_retracted, 50),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{stat, hard}].

mod_options(_Host) ->
    [].


-spec publish_feed_item(Uid :: binary(), Node :: binary(),
        ItemId :: binary(), ItemType :: atom(), Payloads :: [xmlel()]) -> ok.
publish_feed_item(Uid, Node, ItemId, ItemType, _Payload) ->
    ?INFO("counting Uid:~p, Node: ~p, ItemId: ~p, ItemType:~p", [Uid, Node, ItemId, ItemType]),
    case ItemType of
        feedpost ->
            ?INFO("post",[]),
            stat:count("HA/feed", "post");
        comment ->
            ?INFO("comment",[]),
            stat:count("HA/feed", "comment");
        _ -> ok
    end,
    ok.


-spec feed_item_published(Uid :: binary(), ItemId :: binary(), ItemType :: binary()) -> ok.
feed_item_published(Uid, ItemId, ItemType) ->
    ?INFO("counting Uid:~p, ItemId: ~p, ItemType:~p", [Uid, ItemId, ItemType]),
    stat:count("HA/feed", atom_to_list(ItemType)),
    ok.


-spec feed_item_retracted(Uid :: binary(), ItemId :: binary(), ItemType :: binary()) -> ok.
feed_item_retracted(Uid, ItemId, ItemType) ->
    ?INFO("counting Uid:~p, ItemId: ~p, ItemType:~p", [Uid, ItemId, ItemType]),
    stat:count("HA/feed", "retract_" ++ atom_to_list(ItemType)),
    ok.


-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
register_user(Uid, _Server, _Phone) ->
    ?INFO("counting uid:~s", [Uid]),
    stat:count("HA/account", "registration"),
    ok.


-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(Uid, _Server, _Phone) ->
    ?INFO("counting uid:~s", [Uid]),
    stat:count("HA/account", "re_register"),
    ok.


-spec add_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
add_friend(Uid, _Server, _ContactId) ->
    ?INFO("counting uid:~s", [Uid]),
    stat:count("HA/graph", "add_friend"),
    ok.


-spec remove_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
remove_friend(Uid, _Server, _ContactId) ->
    ?INFO("counting uid:~s", [Uid]),
    stat:count("HA/graph", "remove_friend"),
    ok.

-spec user_send_packet({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
user_send_packet({Packet, _State} = Acc) ->
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

