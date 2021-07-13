-module(mod_ha_stats).
-author('nikola').
-behaviour(gen_mod).
-behavior(gen_server).

-include("logger.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("time.hrl").
-include("proc.hrl").

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
    feed_item_published/4,
    feed_item_retracted/3,
    group_feed_item_published/4,
    group_feed_item_retracted/4,
    register_user/3,
    re_register_user/3,
    add_friend/4,
    remove_friend/3,
    user_send_packet/1,
    user_receive_packet/1
]).

-ifdef(TEST).
-export([
    log_new_user/1
]).
-endif.
-compile([{nowarn_unused_function, [{log_new_user, 1}]}]). % used in tests only


-record(state, {
    new_user_map = #{} :: map(),
    last_cleanup_ts = 0 :: non_neg_integer()
}).

-record(new_user_stats, {
    registered_at :: non_neg_integer(),
    posts = 0 :: non_neg_integer(),
    comments = 0 :: non_neg_integer()
}).

-define(CLEANUP_INTERVAL, 1 * ?HOURS_MS).
-define(LOG_NEW_USER_TIME, 1 * ?MINUTES_MS).

start_link() ->
    gen_server:start_link({local, ?PROC()}, ?MODULE, [], []).

start(Host, Opts) ->
    application:ensure_all_started(prometheus),
    ejabberd_hooks:add(feed_item_published, Host, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:add(group_feed_item_published, Host, ?MODULE, group_feed_item_published, 50),
    ejabberd_hooks:add(feed_item_retracted, Host, ?MODULE, feed_item_retracted, 50),
    ejabberd_hooks:add(group_feed_item_retracted, Host, ?MODULE, group_feed_item_retracted, 50),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:add(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_friend, Host, ?MODULE, remove_friend, 50),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:add(feed_share_old_items, Host, ?MODULE, feed_share_old_items, 50),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ok.


stop(Host) ->
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(remove_friend, Host, ?MODULE, remove_friend, 50),
    ejabberd_hooks:delete(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:delete(feed_item_published, Host, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:delete(group_feed_item_published, Host, ?MODULE, group_feed_item_published, 50),
    ejabberd_hooks:delete(feed_item_retracted, Host, ?MODULE, feed_item_retracted, 50),
    ejabberd_hooks:delete(group_feed_item_retracted, Host, ?MODULE, group_feed_item_retracted, 50),
    ejabberd_hooks:delete(feed_share_old_items, Host, ?MODULE, feed_share_old_items, 50),
    gen_mod:stop_child(?PROC()),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{stat, hard}].

mod_options(_Host) ->
    [].

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

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

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
    gen_server:cast(?PROC(), {new_user, Uid}).

% Test only
log_new_user(Uid) ->
    gen_server:cast(?PROC(), {log_new_user, Uid}).

log_share_old_items(Uid, NumPosts, NumComments) ->
    gen_server:cast(?PROC(), {log_share_old_items, Uid, NumPosts, NumComments}).

trigger_cleanup() ->
    gen_server:cast(?PROC(), {cleanup}).


-spec feed_item_published(Uid :: binary(), ItemId :: binary(), ItemType :: atom(),
        FeedAudienceType :: atom()) -> ok.
feed_item_published(Uid, ItemId, ItemType, FeedAudienceType) ->
    ?INFO("counting Uid:~p, ItemId: ~p, ItemType:~p", [Uid, ItemId, ItemType]),
    {ok, Phone} = model_accounts:get_phone(Uid),
    CC = mod_libphonenumber:get_cc(Phone),
    IsDev = dev_users:is_dev_uid(Uid),
    case ItemType of
        post ->
            ?INFO("post ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            stat:count("HA/feed", "post"),
            stat:count("HA/feed", "post_by_cc", 1, [{cc, CC}]),
            stat:count("HA/feed", "post_by_dev", 1, [{is_dev, IsDev}]),
            stat:count("HA/feed", "post_by_audience_type", 1, [{type, FeedAudienceType}]);
        comment ->
            ?INFO("comment ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            stat:count("HA/feed", "comment"),
            stat:count("HA/feed", "comment_by_cc", 1, [{cc, CC}]),
            stat:count("HA/feed", "comment_by_dev", 1, [{is_dev, IsDev}]);
        _ -> ok
    end,
    ok.


-spec feed_item_retracted(Uid :: binary(), ItemId :: binary(), ItemType :: atom()) -> ok.
feed_item_retracted(Uid, ItemId, ItemType) ->
    ?INFO("counting Uid:~p, ItemId: ~p, ItemType:~p", [Uid, ItemId, ItemType]),
    stat:count("HA/feed", "retract_" ++ atom_to_list(ItemType)),
    ok.


-spec group_feed_item_published(Gid :: binary(), Uid :: binary(), ItemId :: binary(), ItemType :: atom()) -> ok.
group_feed_item_published(Gid, Uid, ItemId, ItemType) ->
    ?INFO("counting Gid: ~p, Uid:~p, ItemId: ~p, ItemType:~p", [Gid, Uid, ItemId, ItemType]),
    {ok, Phone} = model_accounts:get_phone(Uid),
    CC = mod_libphonenumber:get_cc(Phone),
    IsDev = dev_users:is_dev_uid(Uid),
    case ItemType of
        post ->
            ?INFO("post ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            stat:count("HA/group_feed", "post"),
            stat:count("HA/group_feed", "post_by_cc", 1, [{cc, CC}]),
            stat:count("HA/group_feed", "post_by_dev", 1, [{is_dev, IsDev}]);
        comment ->
            ?INFO("comment ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            stat:count("HA/group_feed", "comment"),
            stat:count("HA/group_feed", "comment_by_cc", 1, [{cc, CC}]),
            stat:count("HA/group_feed", "comment_by_dev", 1, [{is_dev, IsDev}]);
        _ -> ok
    end,
    ok.


-spec group_feed_item_retracted(Gid :: binary(), Uid :: binary(), ItemId :: binary(), ItemType :: atom()) -> ok.
group_feed_item_retracted(Gid, Uid, ItemId, ItemType) ->
    ?INFO("counting Gid: ~p, Uid:~p, ItemId: ~p, ItemType:~p", [Gid, Uid, ItemId, ItemType]),
    stat:count("HA/group_feed", "retract_" ++ atom_to_list(ItemType)),
    ok.


-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
register_user(Uid, _Server, Phone) ->
    ?INFO("counting uid:~s", [Uid]),
    case util:is_test_number(Phone) of
        false ->
            stat:count("HA/account", "registration"),
            CC = mod_libphonenumber:get_region_id(Phone),
            stat:count("HA/account", "registration_by_cc", 1, [{cc, CC}]);
        true ->
            stat:count("HA/account", "registration_test_account")
    end,
    new_user(Uid),
    ok.


-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(Uid, _Server, _Phone) ->
    ?INFO("counting uid:~s", [Uid]),
    stat:count("HA/account", "re_register"),
    ok.


-spec add_friend(UserId :: binary(), Server :: binary(), ContactId :: binary(), WasBlocked :: boolean()) -> ok.
add_friend(Uid, _Server, _ContactId, _WasBlocked) ->
    ?INFO("counting uid:~s", [Uid]),
    stat:count("HA/graph", "add_friend"),
    ok.


-spec remove_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
remove_friend(Uid, _Server, _ContactId) ->
    ?INFO("counting uid:~s", [Uid]),
    stat:count("HA/graph", "remove_friend"),
    ok.

-spec user_send_packet({stanza(), halloapp_c2s:state()}) -> {stanza(), halloapp_c2s:state()}.
user_send_packet({Packet, _State} = Acc) ->
    Action = "send",
    Namespace = "HA/user_send_packet",
    stat:count(Namespace, "packet"),
    count_packet(Namespace, Action, Packet),
    Acc.


-spec user_receive_packet({stanza(), halloapp_c2s:state()}) -> {stanza(), halloapp_c2s:state()}.
user_receive_packet({Packet, _State} = Acc) ->
    Action = "receive",
    Namespace = "HA/user_receive_packet",
    stat:count(Namespace, "packet"),
    count_packet(Namespace, Action, Packet),
    Acc.


-spec count_packet(Namespace :: string(), Action :: string(), Packet :: stanza()) -> ok.
count_packet(Namespace, _Action, #pb_ack{}) ->
    stat:count(Namespace, "ack");
count_packet(Namespace, Action, #pb_msg{from_uid = FromUid, to_uid = ToUid, payload = Payload} = Message) ->
    PayloadType = pb:get_payload_type(Message),
    stat:count(Namespace, "message", 1, [{payload_type, PayloadType}]),
    case Payload of
        #pb_chat_stanza{} ->
            stat:count("HA/messaging", Action ++ "_im"),
            Uid = case Action of
                "send" -> FromUid;
                "receive" -> ToUid
            end,
            IsDev = dev_users:is_dev_uid(Uid),
            stat:count("HA/messaging", Action ++ "_im_by_dev", 1, [{is_dev, IsDev}]);
        #pb_seen_receipt{} -> stat:count("HA/im_receipts", Action ++ "_seen");
        #pb_delivery_receipt{} -> stat:count("HA/im_receipts", Action ++ "_received");
        _ -> ok
    end;
count_packet(Namespace, _Action, #pb_presence{}) ->
    stat:count(Namespace, "presence");
count_packet(Namespace, _Action, #pb_iq{} = Iq) ->
    PayloadType = pb:get_payload_type(Iq),
    stat:count(Namespace, "iq", 1, [{payload_type, PayloadType}]);
count_packet(Namespace, _Action, #pb_chat_state{}) ->
    stat:count(Namespace, "chat_state");
count_packet(Namespace, _Action, _Packet) ->
    stat:count(Namespace, "unknown"),
    ok.

feed_share_old_items(_FromUid, ToUid, NumPosts, NumComments) ->
    stat:count("HA/feed", "initial_feed", NumPosts, [{type, post}]),
    stat:count("HA/feed", "initial_feed", NumComments, [{type, comment}]),
    log_share_old_items(ToUid, NumPosts, NumComments),
    ok.
