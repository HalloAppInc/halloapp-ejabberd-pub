%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 24. Apr 2020 11:01 AM
%%%-------------------------------------------------------------------
-module(mod_pubsub_halloapp).
-author("nikola").
-author("murali").
-include("xmpp.hrl").
-include("logger.hrl").
-include("pubsub.hrl").
%% Using a large value to indicate the number of items that can be stored in a node.
%% max-value of 32-bit integer
-define(MAX_ITEMS, 2147483647).

%% Using an atom here to indicate that it never expires.
-define(UNEXPIRED_ITEM_SEC, infinity).

-behaviour(gen_mod).

-export([
    start/2,
    stop/1,
    reload/3,
    mod_options/1,
    depends/2
]).

%% Hooks.
-export([
    register_user/2,
    add_friend/3,
    remove_friend/3
]).

start(Host, _Opts) ->
    %% TODO(murali@): Add logic from mod_pubsub to route messages and handle iqs.
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_friend, Host, ?MODULE, remove_friend, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(remove_friend, Host, ?MODULE, remove_friend, 50),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_pubsub, hard}].

mod_options(_Host) ->
    [].

-spec register_user(Uid :: binary(), Server :: binary()) -> ok.
register_user(Uid, Server) ->
    create_pubsub_nodes(Uid, Server).


%%====================================================================
%% pubsub: create
%%====================================================================


-spec create_pubsub_nodes(binary(), binary()) -> ok.
create_pubsub_nodes(User, Server) ->
    FeedNodeName = util:pubsub_node_name(User, feed),
    MetadataNodeName = util:pubsub_node_name(User, metadata),
    create_pubsub_node(User, Server, FeedNodeName, subscribers,
        headline, ?MAX_ITEMS, ?EXPIRE_ITEM_SEC),
    create_pubsub_node(User, Server, MetadataNodeName, publishers,
        normal, 1, ?UNEXPIRED_ITEM_SEC).


-spec create_pubsub_node(binary(), binary(), binary(), atom(), atom(), integer(), integer()) -> ok.
create_pubsub_node(User, Server, NodeName, PublishModel,
        NotificationType, MaxItems, ItemExpireSec) ->
    Host = mod_pubsub:host(Server),
    ServerHost = Server,
    Node = NodeName,
    From = jid:make(User, Server),
    Type = <<"flat">>,
    Access = pubsub_createnode,
    Config = [{send_last_published_item, never}, {max_items, MaxItems},
        {itemreply, publisher}, {notification_type, NotificationType},
        {notify_retract, true}, {notify_delete, true}, {item_expire, ItemExpireSec},
        {publish_model, PublishModel}, {access_model, whitelist}],
    JID = jid:make(User, Server),
    SubscribeConfig = [],
    Result1 = mod_pubsub:create_node(Host, ServerHost, Node, From, Type, Access, Config),
    Result2 = mod_pubsub:subscribe_node(Host, Node, From, JID, SubscribeConfig),
    ?INFO_MSG("Creating a pubsub node for user: ~p, result: ~p, subscribe result: ~p",
            [From, Result1, Result2]),
    ok.


%%====================================================================
%% pubsub: subscribe
%%====================================================================


-spec add_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
add_friend(UserId, Server, ContactId) ->
    subscribe_to_each_others_node(UserId, Server, ContactId, feed),
    subscribe_to_each_others_node(UserId, Server, ContactId, metadata).


-spec subscribe_to_each_others_node(UserId :: binary(), Server :: binary(),
        ContactId :: binary(), NodeType :: atom()) -> ok.
subscribe_to_each_others_node(UserId, Server, ContactId, NodeType) ->
    UserNodeName = util:pubsub_node_name(UserId, NodeType),
    ContactNodeName =  util:pubsub_node_name(ContactId, NodeType),
    subscribe_to_node(UserId, Server, ContactId, ContactNodeName),
    subscribe_to_node(ContactId, Server, UserId, UserNodeName).


-spec subscribe_to_node(SubscriberId :: binary(), Server :: binary(),
        OwnerId :: binary(), NodeName :: binary()) -> ok.
subscribe_to_node(SubscriberId, Server, OwnerId, NodeName) ->
    Host = mod_pubsub:host(Server),
    Node = NodeName,
    %% Affiliation
    Affs = [#ps_affiliation{jid = jid:make(SubscriberId, Server), type = member}],
    OwnerJID = jid:make(OwnerId, Server),
    AffResult = mod_pubsub:set_affiliations(Host, Node, OwnerJID, Affs),
    ?DEBUG("Owner: ~p tried to set affs to pubsub node: ~p, result: ~p",
                                                        [OwnerJID, Node, AffResult]),
    %% Subscription
    SubscriberJID = jid:make(SubscriberId, Server),
    Config = [],
    SubsResult = mod_pubsub:subscribe_node(Host, Node, SubscriberJID, SubscriberJID, Config),
    ?DEBUG("User: ~p tried to subscribe to pubsub node: ~p, result: ~p",
                                                        [SubscriberJID, Node, SubsResult]),
    ok.


%%====================================================================
%% pubsub: unsubscribe
%%====================================================================


%% Unsubscribes the User to the nodes of the ContactNumber and vice-versa.
-spec remove_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
remove_friend(UserId, Server, ContactId) ->
    unsubscribe_to_each_others_node(UserId, Server, ContactId, feed),
    unsubscribe_to_each_others_node(UserId, Server, ContactId, metadata).


-spec unsubscribe_to_each_others_node(binary(), binary(), binary(), atom()) -> ok.
unsubscribe_to_each_others_node(UserId, Server, ContactId, NodeType) ->
    UserNodeName = util:pubsub_node_name(UserId, NodeType),
    ContactNodeName = util:pubsub_node_name(ContactId, NodeType),
    unsubscribe_to_node(UserId, Server, ContactId, ContactNodeName),
    unsubscribe_to_node(ContactId, Server, UserId, UserNodeName).


-spec unsubscribe_to_node(SubscriberId :: binary(), Server :: binary(),
        OwnerId :: binary(), NodeName :: binary()) -> ok.
unsubscribe_to_node(SubscriberId, Server, OwnerId, NodeName) ->
    Host = mod_pubsub:host(Server),
    Node = NodeName,
    %% Affiliation
    Affs = [#ps_affiliation{jid = jid:make(SubscriberId, Server), type = none}],
    OwnerJID = jid:make(OwnerId, Server),
    Result1 = mod_pubsub:set_affiliations(Host, Node, OwnerJID, Affs),
    ?DEBUG("Owner: ~p tried to set affs to pubsub node: ~p, result: ~p",
                                                        [OwnerJID, Node, Result1]),
    %% Subscription
    SubscriberJID = jid:make(SubscriberId, Server),
    SubId = all,
    Result2 = mod_pubsub:unsubscribe_node(Host, Node, SubscriberJID, SubscriberJID, SubId),
    ?DEBUG("User: ~p tried to unsubscribe to pubsub node: ~p, result: ~p",
                                                        [SubscriberJID, Node, Result2]),
    ok.

