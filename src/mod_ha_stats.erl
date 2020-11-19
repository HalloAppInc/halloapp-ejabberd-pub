-module(mod_ha_stats).
-author('nikola').
-behaviour(gen_mod).
-behavior(gen_server).

-include("logger.hrl").
-include("xmpp.hrl").
-include("pubsub.hrl").
-include("time.hrl").

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

% timer functions
-export([
    trigger_cleanup/0
]).

-export([
    feed_share_old_items/4,
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

-ifdef(TEST).
-export([
    log_new_user/1
]).
-endif.


-record(state, {
    new_user_map = #{} :: map(),
    last_cleanup_ts = 0 :: non_neg_integer()
}).

-record(new_user_stats, {
    registered_at :: non_neg_integer(),
    posts = 0 :: non_neg_integer(),
    comments = 0 :: non_neg_integer()
}).

-define(CLEANUP_INTERVAL, 1 * ?HOURS).
-define(LOG_NEW_USER_TIME, 1 * ?MINUTES_MS).

start_link() ->
    gen_server:start_link({local, get_proc()}, ?MODULE, [], []).

start(Host, _Opts) ->
    ejabberd_hooks:add(publish_feed_item, Host, ?MODULE, publish_feed_item, 50),
    ejabberd_hooks:add(feed_item_published, Host, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:add(feed_item_retracted, Host, ?MODULE, feed_item_retracted, 50),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_friend, Host, ?MODULE, remove_friend, 50),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:add(feed_share_old_items, Host, ?MODULE, feed_share_old_items, 50),
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
    ejabberd_hooks:delete(feed_share_old_items, Host, ?MODULE, feed_share_old_items, 50),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{stat, hard}].

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).

% gen_server
init(_Stuff) ->
    {ok, _Tref1} = timer:apply_interval(?CLEANUP_INTERVAL, ?MODULE, trigger_cleanup, []),
    prometheus_histogram:new([{name, ha_new_user_initial_feed_posts},
        {labels, []},
        {buckets, [0, 1, 3, 5, 10, 20, 50]},
        {help, "New user initial feed number of posts"}]),
    prometheus_histogram:new([{name, ha_new_user_initial_feed_comments},
        {labels, []},
        {buckets, [0, 5, 10, 20, 50, 100]},
        {help, "New user initial feed number of comments"}]),
    {ok, #state{}}.


handle_call(_Message, _From, State) ->
    ?ERROR("unexpected call ~p from ", _Message),
    {reply, ok, State}.

handle_cast({new_user, Uid}, #state{new_user_map = NUMap} = State) ->
    NUMap2 = NUMap#{Uid => #new_user_stats{registered_at = util:now()}},
    _Tref = erlang:send_after(?LOG_NEW_USER_TIME, self(), {log_new_user, Uid}),
    {noreply, State#state{new_user_map = NUMap2}};

handle_cast({log_new_user, _Uid} = Msg, State) ->
    handle_info(Msg, State);

handle_cast({log_share_old_items, Uid, NumPosts, NumComments}, #state{new_user_map = NUMap} = State) ->
    NUMap2 = case maps:get(Uid, NUMap, undefined) of
        #new_user_stats{
            posts = Posts,
            comments = Comments
        } = NUS ->
            NUMap#{Uid => NUS#new_user_stats{
                posts = Posts + NumPosts,
                comments = Comments + NumComments}};
        undefined ->
            ?WARNING("User ~s not found in map", [Uid]),
            NUMap
    end,
    {noreply, State#state{new_user_map = NUMap2}};

handle_cast({cleanup}, #state{new_user_map = NUMap} = State) ->
    NUMap2 = maps:filter(
        fun(_Uid, NUS) ->
            NUS#new_user_stats.registered_at > util:now() - ?CLEANUP_INTERVAL
        end,
        NUMap),
    ?INFO_MSG("cleanup old ~p -> new ~p", [maps:size(NUMap), maps:size(NUMap2)]),
    {noreply, State#state{new_user_map = NUMap2}};


handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({log_new_user, Uid}, #state{new_user_map = NUMap} = State) ->
    NUMap2 = case maps:get(Uid, NUMap, undefined) of
        #new_user_stats{
            posts = Posts,
            comments = Comments
        } ->
            prometheus_histogram:observe(ha_new_user_initial_feed_posts, Posts),
            prometheus_histogram:observe(ha_new_user_initial_feed_comments, Comments),
            maps:remove(Uid, NUMap);
        undefined ->
        ?WARNING("User ~s not found in map", [Uid]),
        NUMap
    end,
    {noreply, State#state{new_user_map = NUMap2}};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

new_user(Uid) ->
    gen_server:cast(get_proc(), {new_user, Uid}).

% Test only
log_new_user(Uid) ->
    gen_server:cast(get_proc(), {log_new_user, Uid}).

log_share_old_items(Uid, NumPosts, NumComments) ->
    gen_server:cast(get_proc(), {log_share_old_items, Uid, NumPosts, NumComments}).

trigger_cleanup() ->
    gen_server:cast(get_proc(), {cleanup}).


-spec publish_feed_item(Uid :: binary(), Node :: binary(),
        ItemId :: binary(), ItemType :: atom(), Payloads :: [xmlel()]) -> ok.
publish_feed_item(Uid, Node, ItemId, ItemType, _Payload) ->
    ?INFO("counting Uid:~p, Node: ~p, ItemId: ~p, ItemType:~p", [Uid, Node, ItemId, ItemType]),
    {ok, Phone} = model_accounts:get_phone(Uid),
    CC = mod_libphonenumber:get_cc(Phone),
    IsDev = dev_users:is_dev_uid(Uid),
    % TODO: maybe try to combine the logic for post and comment
    case ItemType of
        feedpost ->
            ?INFO("post ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            stat:count("HA/feed", "post"),
            stat:count("HA/feed", "post_by_cc", 1, [{cc, CC}]),
            stat:count("HA/feed", "post_by_dev", 1, [{is_dev, IsDev}]);
        comment ->
            ?INFO("comment ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            stat:count("HA/feed", "comment"),
            stat:count("HA/feed", "comment_by_cc", 1, [{cc, CC}]),
            stat:count("HA/feed", "comment_by_dev", 1, [{is_dev, IsDev}]);
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
register_user(Uid, _Server, Phone) ->
    ?INFO("counting uid:~s", [Uid]),
    stat:count("HA/account", "registration"),
    CC = mod_libphonenumber:get_region_id(Phone),
    stat:count("HA/account", "registration_by_cc", 1, [{cc, CC}]),
    new_user(Uid),
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
    Action = "send",
    Namespace = "HA/user_send_packet",
    stat:count(Namespace, "packet"),
    count_packet(Namespace, Action, Packet),
    Acc.


-spec user_receive_packet({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
user_receive_packet({Packet, _State} = Acc) ->
    Action = "receive",
    Namespace = "HA/user_receive_packet",
    stat:count(Namespace, "packet"),
    count_packet(Namespace, Action, Packet),
    Acc.


-spec count_packet(Namespace :: string(), Action :: string(), Packet :: stanza()) -> ok.
count_packet(Namespace, _Action, #ack{}) ->
    stat:count(Namespace, "ack");
count_packet(Namespace, Action, #message{sub_els = [SubEl | _Rest]} = Message) ->
    PayloadType = util:get_payload_type(Message),
    stat:count(Namespace, "message", 1, [{payload_type, PayloadType}]),
    case SubEl of
        #chat{} -> stat:count("HA/messaging", Action ++ "_im");
        #receipt_seen{} -> stat:count("HA/im_receipts", Action ++ "_seen");
        #receipt_response{} -> stat:count("HA/im_receipts", Action ++ "_received");
        _ -> ok
    end;
count_packet(Namespace, _Action, #presence{}) ->
    stat:count(Namespace, "presence");
count_packet(Namespace, _Action, #iq{} = Iq) ->
    PayloadType = util:get_payload_type(Iq),
    stat:count(Namespace, "iq", 1, [{payload_type, PayloadType}]);
count_packet(Namespace, _Action, #chat_state{}) ->
    stat:count(Namespace, "chat_state");
count_packet(Namespace, _Action, _Packet) ->
    stat:count(Namespace, "unknown"),
    ok.

feed_share_old_items(_FromUid, ToUid, NumPosts, NumComments) ->
    stat:count("HA/feed", "initial_feed", NumPosts, [{type, post}]),
    stat:count("HA/feed", "initial_feed", NumComments, [{type, comment}]),
    log_share_old_items(ToUid, NumPosts, NumComments),
    ok.
