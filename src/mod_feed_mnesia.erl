%%%-------------------------------------------------------------------
%%% File: mod_feed_mnesia.erl
%%%
%%% @copyright (C) 2020, Halloapp Inc.
%%%
%%% This file handles all the mnesia db queries related to the new pubsub.
%%%
%%%-------------------------------------------------------------------
-module(mod_feed_mnesia).
-author('murali').
-behaviour(gen_mod).

-include("xmpp.hrl").
-include("logger.hrl").
-include("feed.hrl").
-include("pubsub.hrl").

-export([
    start/2,
    stop/1,
    reload/3,
    mod_options/1,
    depends/2
]).

%% API.
-export([
    create_node/1,
    get_node/1,
    delete_node/1,
    get_user_nodes/1,
    get_all_nodes/0,
    delete_user_nodes/1,
    publish_item/1,
    get_item/1,
    retract_item/1,
    get_all_items/1,
    get_item_by_id/1,
    %% TODO(murali@): remove after migration
    migrate_old_pubsub_data/0,
    get_node_type/1
]).

start(_Host, _Opts) ->
    ejabberd_mnesia:create(?MODULE, psnode,
        [{disc_copies, [node()]}, {index, [uid]},
        {type, set}, {attributes, record_info(fields, psnode)}]),
    ejabberd_mnesia:create(?MODULE, item,
        [{disc_copies, [node()]},
        {type, set}, {attributes, record_info(fields, item)}]),
    ok.

stop(_Host) ->
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% API
%%====================================================================


-spec create_node(Node :: psnode()) -> ok | {error, any()}.
create_node(Node) ->
    ok = mnesia:dirty_write(Node).


-spec get_node(NodeId :: binary()) -> {ok, undefined | psnode()} | {error, any()}.
get_node(NodeId) ->
    Result = case mnesia:dirty_match_object(#psnode{id = NodeId, _ = '_'}) of
        [] -> undefined;
        [Node] -> Node
    end,
    {ok, Result}.


-spec delete_node(NodeId :: binary()) -> ok | {error, any()}.
delete_node(NodeId) ->
    case mnesia:dirty_match_object(#psnode{id = NodeId, _ = '_'}) of
        [] -> ok;
        [Node] -> ok = mnesia:dirty_delete_object(Node)
    end.


-spec delete_user_nodes(Uid :: binary()) -> ok | {error, any()}.
delete_user_nodes(Uid) ->
    Nodes = mnesia:dirty_match_object(#psnode{uid = Uid, _ = '_'}),
    ok = lists:foreach(fun mnesia:delete_object/1, Nodes).


-spec get_all_nodes() -> {ok, list(psnode())} | {error, any()}.
get_all_nodes() ->
    Result = case mnesia:dirty_match_object(#psnode{_ = '_'}) of
        [] -> [];
        Nodes -> Nodes
    end,
    {ok, Result}.


-spec get_user_nodes(Uid :: binary()) -> {ok, undefined | list(node())} | {error, any()}.
get_user_nodes(Uid) ->
    Result = case mnesia:dirty_match_object(#psnode{uid = Uid, _ = '_'}) of
        [] -> undefined;
        Nodes -> Nodes
    end,
    {ok, Result}.


-spec publish_item(Item :: item()) -> ok | {error, any()}.
publish_item(Item) ->
    ok = mnesia:dirty_write(Item).


-spec get_item(ItemKey :: {binary(), binary()}) -> {ok, undefined | item()} | {error, any()}.
get_item(ItemKey) ->
    Result = case mnesia:dirty_match_object(#item{key = ItemKey, _ = '_'}) of
        [] -> undefined;
        [Item] -> Item
    end,
    {ok, Result}.


-spec get_item_by_id(ItemId :: binary()) -> {ok, undefined | item()}.
get_item_by_id(ItemId) ->
    Result = case mnesia:dirty_match_object(#item{key = {ItemId, '_'}, _ = '_'}) of
        [] -> undefined;
        [Item] -> Item
    end,
    {ok, Result}.


-spec retract_item(ItemKey :: {binary(), binary()}) -> ok | {error, any()}.
retract_item(ItemKey) ->
    case mnesia:dirty_match_object(#item{key = ItemKey, _ = '_'}) of
        [] -> ok;
        [Item] -> ok = mnesia:dirty_delete_object(Item)
    end.


-spec get_all_items(NodeId :: binary()) -> {ok, list(item())} | {error, any()}.
get_all_items(NodeId) ->
    Result = case mnesia:dirty_match_object(#item{key = {'_', NodeId}, _ = '_'}) of
        [] -> [];
        Items -> Items
    end,
    {ok, Result}.


%% TODO(murali@): remove migration functions after use.
migrate_old_pubsub_data() ->
    case mnesia:dirty_match_object(mnesia:table_info(pubsub_node, wild_pattern)) of
        [] -> ok;
        PubsubNodes ->
            lists:foreach(
                fun(#pubsub_node{
                        nodeid = {_Host, NodeId},
                        id = NodeIdx,
                        owners = [{Uid, _, _}]
                    }) ->
                    NodeType = get_node_type(NodeId),
                    CTsMs = util:now_ms(),
                    Node = #psnode{
                        id = NodeId,
                        uid = Uid,
                        type = NodeType,
                        creation_ts_ms = CTsMs
                    },
                    ok = create_node(Node),
                    migrate_old_pubsub_items(NodeId, NodeIdx)
                end, PubsubNodes)
    end.


migrate_old_pubsub_items(NodeId, NodeIdx) ->
    case mnesia:dirty_match_object(#pubsub_item_new{nodeidx = NodeIdx, _ = '_'}) of
        [] -> ok;
        Items ->
            lists:foreach(
                fun(#pubsub_item_new{
                        itemid = {ItemId, _},
                        itemtype = ItemType,
                        creation = {ErlTimestamp, {PublisherUid, _, _}},
                        payload = ItemPayload
                    }) ->
                    Item = #item{
                        key = {ItemId, NodeId},
                        type = ItemType,
                        uid = PublisherUid,
                        creation_ts_ms = binary_to_integer(util:timestamp_to_binary(ErlTimestamp)) * 1000,
                        payload = ItemPayload
                    },
                    ok = mod_feed_mnesia:publish_item(Item)
                end, Items)
    end.

get_node_type(<<"feed-", _Rest/binary>>) -> feed;
get_node_type(_) -> metadata.

