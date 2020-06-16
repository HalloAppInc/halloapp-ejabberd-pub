%%%-------------------------------------------------------------------
%%% File    : mod_feed.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-------------------------------------------------------------------

-module(mod_feed).
-author('murali').
-author('nikola').

-include("xmpp.hrl").
-include("translate.hrl").
-include("logger.hrl").
-include("feed.hrl").
-include("pubsub.hrl").
-include("time.hrl").

-define(PUBSUB_HOST, <<"pubsub.s.halloapp.net">>).

%% Number of milliseconds in 7days.
-define(EXPIRE_ITEM_MS, 7 * ?DAYS_MS).

-behaviour(gen_mod).

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
    route/1,
    register_user/3,
    add_friend/3,
    remove_friend/3,
    remove_user/2,
    process_local_iq/1,
    on_user_first_login/2,
    purge_expired_items/0
]).


start(Host, _Opts) ->
    %% TODO(murali@): remove this line after successful migration.
    ejabberd_router:unregister_route(?PUBSUB_HOST),
    ejabberd_router:register_route(?PUBSUB_HOST, Host, {apply, ?MODULE, route}),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?PUBSUB_HOST, ?NS_PUBSUB, ?MODULE, process_local_iq),
    ejabberd_hooks:add(on_user_first_login, Host, ?MODULE, on_user_first_login, 75),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_friend, Host, ?MODULE, remove_friend, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    CronTask = [
        {time, 1},
        {units, hours},
        {timer_type, interval},
        {module, ?MODULE},
        {function, purge_expired_items},
        {arguments, []}
    ],
    mod_cron:add_task(Host, CronTask),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(on_user_first_login, Host, ?MODULE, on_user_first_login, 75),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(remove_friend, Host, ?MODULE, remove_friend, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_PUBSUB),
    ejabberd_router:unregister_route(?PUBSUB_HOST),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_cron, hard}].

mod_options(_Host) ->
    [].

-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
register_user(Uid, Server, _Phone) ->
    create_pubsub_nodes(Uid, Server).


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    mod_feed_mnesia:delete_user_nodes(Uid).

-spec on_user_first_login(Uid :: binary(), Server :: binary()) -> ok.
on_user_first_login(Uid, Server) ->
    send_old_items_to_user(Uid, Server, Uid),
    ok.


-spec purge_expired_items() -> ok.
purge_expired_items() ->
    TimestampMs = util:now_ms(),
    purge_expired_items(TimestampMs).


-spec route(stanza()) -> ok.
route(#iq{to = To} = IQ) when To#jid.lresource == <<"">> ->
    ejabberd_router:process_iq(IQ);
route(_Pkt) ->
    ?ERROR_MSG("invalid packet received: ~p", [_Pkt]),
    ok.

%%====================================================================
%% pubsub: IQs
%%====================================================================

%% TODO(murali@): Check if uid is allowed to access the node items.
%% Ideally, client should never use this get-api.
%% This get-api is kind of flaky too.. we dont purge expired items here.
process_local_iq(#iq{from = #jid{luser = Uid, lserver = Server}, type = get, lang = Lang,
        sub_els = [#pubsub{items = #ps_items{node = NodeId, items = ItemsEls}}]} = IQ) ->
    ?INFO_MSG("Uid: ~s, get_items", [Uid]),
    {ok, Node} = mod_feed_mnesia:get_node(NodeId),
    if
        Node =:= undefined ->
            ?INFO_MSG("Uid: ~s, Invalid node", [Uid]),
            Txt = ?T("Invalid node"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        ItemsEls =:= undefined ->
            {ok, Items} = mod_feed_mnesia:get_all_items(NodeId),
            xmpp:make_iq_result(IQ, #pubsub{items = items_els(NodeId, Items, Server)});
        true ->
            Items = lists:foldr(
                fun(#ps_item{id = ItemId}, Res) ->
                    case mod_feed_mnesia:get_item({ItemId, NodeId}) of
                        {ok, undefined} -> Res;
                        {ok, Item} -> [Item | Res]
                    end
                end, [], ItemsEls),
            xmpp:make_iq_result(IQ, #pubsub{items = items_els(NodeId, Items, Server)})
    end;

process_local_iq(#iq{from = #jid{luser = Uid, lserver = Server}, type = set, lang = Lang,
        sub_els = [#pubsub{publish = #ps_publish{node = NodeId,
            items = [#ps_item{id = ItemId, type = ItemType, sub_els = Payload}]}}]} = IQ) ->
    ?INFO_MSG("Uid: ~s, publish item_id: ~s", [Uid, ItemId]),
    {ok, Node} = mod_feed_mnesia:get_node(NodeId),
    case Node =/= undefined of
        false ->
            ?INFO_MSG("Uid: ~s, Invalid node", [Uid]),
            Txt = ?T("Invalid node"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        true ->
            case is_allowed_to_publish(Uid, Node#psnode.uid, Node#psnode.type, ItemType) of
                false ->
                    ?INFO_MSG("Uid: ~s, Unauthorized to publish", [Uid]),
                    Txt = ?T("Unauthorized to publish"),
                    xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
                true ->
                    ?INFO_MSG("Uid: ~s, publish_item", [Uid]),
                    Item = publish_item(Uid, Server, ItemId, ItemType, Payload, Node),
                    Timestamp = util:ms_to_sec(Item#item.creation_ts_ms),
                    xmpp:make_iq_result(IQ,
                        #pubsub{publish = #ps_publish{
                            node = NodeId,
                            items = [#ps_item{
                                id = ItemId,
                                type = ItemType,
                                timestamp = integer_to_binary(Timestamp)
                        }]}})
            end
    end;

process_local_iq(#iq{from = #jid{luser = Uid, lserver = Server}, type = set, lang = Lang,
    sub_els = [#pubsub{retract = #ps_retract{node = NodeId, notify = Notify,
        items = [#ps_item{id = ItemId, type = _ItemType, sub_els = Payload}]}}]} = IQ) ->
    ?INFO_MSG("Uid: ~s, retract item_id: ~s", [Uid, ItemId]),
    {ok, Node} = mod_feed_mnesia:get_node(NodeId),
    {ok, Item} = mod_feed_mnesia:get_item({ItemId, NodeId}),
    if
        Node =:= undefined ->
            ?INFO_MSG("Uid: ~s, Invalid node", [Uid]),
            Txt = ?T("Invalid node"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        Item =:= undefined ->
            ?INFO_MSG("Uid: ~s, Invalid item-id", [Uid]),
            Txt = ?T("Invalid item-id"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        Item#item.uid =/= Uid ->
            ?INFO_MSG("Uid: ~s, Unauthorized to delete item", [Uid]),
            Txt = ?T("Unauthorized to delete item"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        true ->
            ?INFO_MSG("Uid: ~s, retract_item", [Uid]),
            retract_item(Uid, Server, Item, Payload, Node, Notify),
            xmpp:make_iq_result(IQ)
    end.


-spec publish_item(Uid :: binary(), Server :: binary(), ItemId :: binary(),
        ItemType :: item_type(), Payload :: xmpp_element(), Node :: psnode()) -> item().
publish_item(Uid, Server, ItemId, ItemType, Payload, Node) ->
    ?INFO_MSG("Uid: ~s, ItemId: ~p", [Uid, ItemId]),
    TimestampMs = util:now_ms(),
    NodeId = Node#psnode.id,
    NodeType = Node#psnode.type,
    NewItem = #item{
        key = {ItemId, NodeId},
        type = ItemType,
        uid = Uid,
        creation_ts_ms = TimestampMs,
        payload = Payload
    },
    {ok, ItemResult} = mod_feed_mnesia:get_item({ItemId, NodeId}),
    FinalItem = case {ItemResult, NodeType} of
        {IRes, NType} when IRes =:= undefined; NType =:= metadata->
            ok = mod_feed_mnesia:publish_item(NewItem),
            broadcast_event(Uid, Server, Node, NewItem, Payload, publish),
            NewItem;
        {Item, feed} ->
            Item
    end,
    FinalItem.


-spec retract_item(Uid :: binary(), Server :: binary(), Item :: item(),
        Payload :: xmpp_element(), Node :: psnode(), Notify :: boolean()) -> ok.
retract_item(Uid, Server, Item, Payload, Node, Notify) ->
    ?INFO_MSG("Uid: ~s, Item: ~p", [Uid, Item]),
    ok = mod_feed_mnesia:retract_item(Item#item.key),
    case Notify of
        true -> broadcast_event(Uid, Server, Node, Item, Payload, retract);
        false -> ok
    end.


-spec broadcast_event(Uid :: binary(), Server :: binary(), Node :: psnode(), Item :: item(),
        Payload :: xmpp_element(), EventType :: event_type()) -> ok.
broadcast_event(Uid, Server, Node, Item, Payload, EventType) ->
    ?INFO_MSG("Node: ~p, Item: ~p", [Node, Item]),
    {ItemId, NodeId} = Item#item.key,
    Timestamp = util:ms_to_sec(Item#item.creation_ts_ms),
    PublisherUid = Item#item.uid,
    ItemPublisher = jid:encode(jid:make(PublisherUid, Server)),
    PublisherName = model_accounts:get_name_binary(PublisherUid),
    ItemType = Item#item.type,
    ItemPayload = Payload,
    ItemsEls = case EventType of
        publish ->
            #ps_items{node = NodeId,
                items = [#ps_item{
                    id = ItemId,
                    timestamp = integer_to_binary(Timestamp),
                    publisher = ItemPublisher,
                    publisher_name = PublisherName,
                    type = ItemType,
                    sub_els = ItemPayload
                    }]};
        retract ->
            #ps_items{node = NodeId,
                retract = #ps_event_retract{
                    id = ItemId,
                    timestamp = integer_to_binary(Timestamp),
                    publisher = ItemPublisher,
                    publisher_name = PublisherName,
                    type = ItemType,
                    sub_els = ItemPayload
                    }}
    end,
    broadcast_items(Uid, Server, Node, ItemsEls, EventType),
    ok.


-spec broadcast_items(Uid :: binary(), Server :: binary(), Node :: psnode(),
        ItemsEls :: ps_items(), EventType :: event_type()) -> ok.
broadcast_items(Uid, Server, Node, ItemsEls, EventType) ->
    ?INFO_MSG("Node: ~p, ItemsEls: ~p", [Node, ItemsEls]),
    OwnerUid = Node#psnode.uid,
    MsgType = get_message_type(Node, EventType),
    Packet = #message{type = MsgType, sub_els = [#ps_event{items = ItemsEls}]},
    {ok, FriendUids} = model_friends:get_friends(OwnerUid),
    TempList = lists:delete(OwnerUid, FriendUids),
    BroadcastUids = case OwnerUid =:= Uid of
        true -> TempList;
        false -> lists:delete(Uid, [OwnerUid | TempList])
    end,
    BroadcastJids = util:uids_to_jids(BroadcastUids, Server),
    From = jid:make(?PUBSUB_HOST),
    ?INFO_MSG("Node: ~p, ItemsEls: ~p, FriendUids: ~p", [Node, ItemsEls, BroadcastUids]),
    ejabberd_router_multicast:route_multicast(From, Server, BroadcastJids, Packet),
    ok.


-spec is_allowed_to_publish(PublisherUid :: binary(), OwnerUid :: binary(),
        NodeType :: node_type(), ItemType :: item_type()) -> boolean().
is_allowed_to_publish(Uid, Uid, _NodeType, _ItemType) ->
    true;
is_allowed_to_publish(PublisherUid, OwnerUid, feed, comment) ->
    model_friends:is_friend(PublisherUid, OwnerUid);
is_allowed_to_publish(_, _, _, _) ->
    false.


-spec get_message_type(Node :: psnode(), EventType :: event_type()) -> headline | normal.
get_message_type(#psnode{type = feed}, publish) -> headline;
get_message_type(#psnode{type = metadata}, publish) -> normal;
get_message_type(#psnode{type = _ }, retract) -> normal.


%%====================================================================
%% pubsub: create
%%====================================================================


-spec create_pubsub_nodes(Uid :: binary(), Server :: binary()) -> ok.
create_pubsub_nodes(Uid, _Server) ->
    ?INFO_MSG("Uid: ~s", [Uid]),
    FeedNodeName = util:pubsub_node_name(Uid, feed),
    MetadataNodeName = util:pubsub_node_name(Uid, metadata),
    create_pubsub_node(Uid, FeedNodeName, feed),
    create_pubsub_node(Uid, MetadataNodeName, metadata).


-spec create_pubsub_node(Uid :: binary(), NodeName :: binary(), NodeType :: node_type()) -> ok.
create_pubsub_node(Uid, NodeName, NodeType) ->
    ?INFO_MSG("Uid: ~s, node_name: ~s, node_type: ~s", [Uid, NodeName, NodeType]),
    Node = #psnode{
        id = NodeName,
        uid = Uid,
        type = NodeType,
        creation_ts_ms = util:now_ms()
    },
    ok = mod_feed_mnesia:create_node(Node).

%%====================================================================
%% pubsub: add_friend
%%====================================================================

-spec add_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
add_friend(UserId, Server, ContactId) ->
    ?INFO_MSG("Uid: ~s, ContactId: ~s", [UserId, ContactId]),
    purge_expired_items(),
    %% Send their non-expired pubsub items to each other.
    send_old_items_to_user(UserId, Server, ContactId),
    send_old_items_to_user(ContactId, Server, UserId),
    ok.


%%====================================================================
%% pubsub: remove_friend
%%====================================================================

-spec remove_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
remove_friend(UserId, _Server, ContactId) ->
    ?INFO_MSG("Uid: ~s, ContactId: ~s", [UserId, ContactId]),
    ok.


%%====================================================================
%% pubsub: internal functions
%%====================================================================

-spec send_old_items_to_user(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
send_old_items_to_user(UserId, Server, ContactId) ->
    case mod_feed_mnesia:get_user_nodes(UserId) of
        {ok, undefined} -> ok;
        {ok, Nodes} ->
            lists:foreach(fun(Node) ->
                send_all_node_items(Node, ContactId, Server)
            end, Nodes)
    end.


-spec send_all_node_items(Node :: psnode(), ContactId :: binary(), Server :: binary()) -> ok.
send_all_node_items(#psnode{id = NodeId} = _Node, ContactId, Server) ->
    ?INFO_MSG("NodeId: ~s, ContactId: ~s", [NodeId, ContactId]),
    {ok, Items} = mod_feed_mnesia:get_all_items(NodeId),
    MsgType = normal,
    From = jid:make(?PUBSUB_HOST),
    Packet = #message{
        to = jid:make(ContactId, Server),
        from = From,
        type = MsgType,
        sub_els = [#ps_event{items = items_els(NodeId, Items, Server)}]
    },
    ejabberd_router:route(Packet).


-spec items_els(NodeId :: binary(), Items :: list(item()), Server :: binary()) -> ps_items().
items_els(NodeId, Items, Server) ->
    ItemEls = lists:map(
        fun(Item) ->
            item_els(Item, Server)
        end, Items),
    #ps_items{node = NodeId, items = ItemEls}.


-spec item_els(Item :: item(), Server :: binary()) -> ps_item().
item_els(#item{key = {ItemId, _}, type = ItemType, uid = PublisherUid,
        creation_ts_ms = TimestampMs, payload = Payload}, Server) ->
    Timestamp = util:ms_to_sec(TimestampMs),
    PublisherName = model_accounts:get_name_binary(PublisherUid),
    ItemPublisher = jid:encode(jid:make(PublisherUid, Server)),
    #ps_item{
        id = ItemId,
        timestamp = integer_to_binary(Timestamp),
        type = ItemType,
        publisher = ItemPublisher,
        publisher_name = PublisherName,
        sub_els = Payload
    }.


-spec purge_expired_items(TimestampMs :: integer()) -> ok.
purge_expired_items(TimestampMs) ->
    {ok, Nodes} = mod_feed_mnesia:get_all_nodes(),
    lists:foreach(
        fun(#psnode{type = metadata}) -> ok;
            (Node) ->  purge_expired_items(Node, TimestampMs)
        end, Nodes).


-spec purge_expired_items(Node :: psnode(), TimestampMs :: integer()) -> ok.
purge_expired_items(#psnode{id = NodeId} = _Node, TimestampMs) ->
    {ok, Items} = mod_feed_mnesia:get_all_items(NodeId),
    lists:foreach(
        fun(#item{key = ItemKey, creation_ts_ms = ThenTimestampMs}) ->
            if
                TimestampMs - ThenTimestampMs < ?EXPIRE_ITEM_MS ->
                    ok;
                true ->
                    mod_feed_mnesia:retract_item(ItemKey)
            end
        end, Items).


%% TODO(murali@): Add migration functions.


