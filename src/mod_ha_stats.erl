-module(mod_ha_stats).
-author('nikola').
-behaviour(gen_mod).
-behavior(gen_server).

-include("sms.hrl").
-include("logger.hrl").
-include("packets.hrl").
-include("stanza.hrl").
-include("time.hrl").
-include("proc.hrl").
-include("invites.hrl").

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
    user_send_im/4,
    feed_share_old_items/4,
    feed_item_published/8,
    feed_item_retracted/3,
    group_feed_item_published/7,
    group_feed_item_retracted/4,
    register_user/4,
    re_register_user/4,
    add_friend/4,
    remove_friend/3,
    user_send_packet/1,
    user_receive_packet/1,
    event_fab_action/1
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
    %% HalloApp
    ejabberd_hooks:add(user_send_im, halloapp, ?MODULE, user_send_im, 50),
    ejabberd_hooks:add(feed_item_published, halloapp, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:add(group_feed_item_published, halloapp, ?MODULE, group_feed_item_published, 50),
    ejabberd_hooks:add(feed_item_retracted, halloapp, ?MODULE, feed_item_retracted, 50),
    ejabberd_hooks:add(group_feed_item_retracted, halloapp, ?MODULE, group_feed_item_retracted, 50),
    ejabberd_hooks:add(register_user, halloapp, ?MODULE, register_user, 50),
    ejabberd_hooks:add(re_register_user, halloapp, ?MODULE, re_register_user, 50),
    ejabberd_hooks:add(add_friend, halloapp, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_friend, halloapp, ?MODULE, remove_friend, 50),
    ejabberd_hooks:add(user_send_packet, halloapp, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:add(user_receive_packet, halloapp, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:add(feed_share_old_items, halloapp, ?MODULE, feed_share_old_items, 50),
    ejabberd_hooks:add(event_fab_action, halloapp, ?MODULE, event_fab_action, 50),
    %% Katchup
    ejabberd_hooks:add(feed_item_published, katchup, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:add(register_user, katchup, ?MODULE, register_user, 50),
    ejabberd_hooks:add(user_send_packet, katchup, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:add(user_receive_packet, katchup, ?MODULE, user_receive_packet, 50),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ok.


stop(_Host) ->
    %% HalloApp
    ejabberd_hooks:delete(user_send_im, halloapp, ?MODULE, user_send_im, 50),
    ejabberd_hooks:delete(user_receive_packet, halloapp, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:delete(user_send_packet, halloapp, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(remove_friend, halloapp, ?MODULE, remove_friend, 50),
    ejabberd_hooks:delete(add_friend, halloapp, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(register_user, halloapp, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(re_register_user, halloapp, ?MODULE, re_register_user, 50),
    ejabberd_hooks:delete(feed_item_published, halloapp, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:delete(group_feed_item_published, halloapp, ?MODULE, group_feed_item_published, 50),
    ejabberd_hooks:delete(feed_item_retracted, halloapp, ?MODULE, feed_item_retracted, 50),
    ejabberd_hooks:delete(group_feed_item_retracted, halloapp, ?MODULE, group_feed_item_retracted, 50),
    ejabberd_hooks:delete(feed_share_old_items, halloapp, ?MODULE, feed_share_old_items, 50),
    ejabberd_hooks:delete(event_fab_action, halloapp, ?MODULE, event_fab_action, 50),
    %% Katchup
    ejabberd_hooks:delete(feed_item_published, katchup, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:delete(register_user, katchup, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(user_send_packet, katchup, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(user_receive_packet, katchup, ?MODULE, user_receive_packet, 50),
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
            ?INFO("User ~s not found in map", [Uid]),
            NUMap
    end,
    {noreply, State#state{new_user_map = NUMap2}};

handle_cast({cleanup}, #state{new_user_map = NUMap} = State) ->
    NUMap2 = maps:filter(
        fun(_Uid, NUS) ->
            NUS#new_user_stats.registered_at > util:now() - ?CLEANUP_INTERVAL
        end,
        NUMap),
    ?INFO("cleanup old ~p -> new ~p", [maps:size(NUMap), maps:size(NUMap2)]),
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



-spec user_send_im(FromUid :: binary(), MsgId :: binary(),
    ToUid :: binary(), MediaCounters :: pb_media_counters()) -> ok.
user_send_im(_FromUid, _MsgId, _ToUid, MediaCounters) ->
    %% TODO: move im counters logic here.
    report_media_counters(chat, MediaCounters),
    ok.


-spec feed_item_published(Uid :: binary(), PostOwnerUid :: binary(), ItemId :: binary(), ItemType :: atom(), ItemTag :: atom(),
        FeedAudienceType :: atom(), FeedAudienceSize :: integer(), MediaCounters :: pb_media_counters()) -> ok.
feed_item_published(Uid, PostOwnerUid, ItemId, ItemType, ItemTag, FeedAudienceType, FeedAudienceSize, MediaCounters) ->
    ?INFO("counting Uid:~p, ItemId: ~p, ItemType:~p, ItemTag: ~p", [Uid, ItemId, ItemType, ItemTag]),
    {ok, Phone} = model_accounts:get_phone(Uid),
    CC = mod_libphonenumber:get_cc(Phone),
    IsDev = dev_users:is_dev_uid(Uid),
    StatNamespace = util:get_stat_namespace(Uid),
    ZoneOffsetRegion = mod_moment_notification2:get_region_by_uid(Uid),
    case ItemType of
        post ->
            ?INFO("post ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            mod_ka_vanity:report_metrics(Uid, post),
            ha_events:log_user_event(Uid, post_published),
            report_media_counters(post, MediaCounters),
            case ItemTag of
                moment ->
                    ha_events:log_user_event(Uid, secret_post_published),
                    report_media_counters(secret_post, MediaCounters);
                _ ->
                    ok
            end,
            stat:count(StatNamespace ++ "/feed", "post"),
            report_audience_size("feed", "post", CC, FeedAudienceSize),
            stat:count(StatNamespace ++ "/feed", "post_by_cc", 1, [{cc, CC}]),
            stat:count(StatNamespace ++ "/feed", "post_by_dev", 1, [{is_dev, IsDev}]),
            stat:count(StatNamespace ++ "/feed", "post_by_audience_type", 1, [{type, FeedAudienceType}]),

            %% Add counters for posts by tags.
            stat:count(StatNamespace ++ "/feed", "post_by_tag", 1, [{tag, ItemTag}]),
            stat:count(StatNamespace ++ "/feed", "post_by_tag_cc", 1, [{cc, CC}, {tag, ItemTag}]),
            stat:count(StatNamespace ++ "/feed", "post_by_tag_dev", 1, [{is_dev, IsDev}, {tag, ItemTag}]),
            stat:count(StatNamespace ++ "/feed", "post_by_tag_audience_type", 1, [{type, FeedAudienceType}, {tag, ItemTag}]),

            stat:count(StatNamespace ++ "/feed", "zone_offset_region", 1, [{offset_region, ZoneOffsetRegion}]),
            stat:count(StatNamespace ++ "/feed", "zone_offset_region_by_cc", 1,
                [{offset_region, ZoneOffsetRegion}, {cc, CC}]),
            stat:count(StatNamespace ++ "/feed", "zone_offset_region_by_dev", 1,
                [{offset_region, ZoneOffsetRegion}, {is_dev, IsDev}]),
            ok;
        comment ->
            ?INFO("comment ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            mod_ka_vanity:report_metrics(Uid, comment),
            ha_events:log_user_event(Uid, comment_published),
            ha_events:log_friend_event(PostOwnerUid, Uid, ItemId, comment_published),
            report_media_counters(comment, MediaCounters),
            stat:count(StatNamespace ++ "/feed", "comment"),
            report_audience_size("feed", "comment", CC, FeedAudienceSize),
            stat:count(StatNamespace ++ "/feed", "comment_by_cc", 1, [{cc, CC}]),
            stat:count(StatNamespace ++ "/feed", "comment_by_dev", 1, [{is_dev, IsDev}]);
        comment_reaction ->
            ?INFO("comment_reaction ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            ha_events:log_user_event(Uid, comment_reaction_published),
            ha_events:log_friend_event(PostOwnerUid, Uid, ItemId, comment_reaction_published),
            stat:count(StatNamespace ++ "/feed", "comment_reaction"),
            stat:count(StatNamespace ++ "/feed", "comment_reaction_by_cc", 1, [{cc, CC}]),
            stat:count(StatNamespace ++ "/feed", "comment_reaction_by_dev", 1, [{is_dev, IsDev}]);
        post_reaction ->
            ?INFO("post_reaction ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            ha_events:log_user_event(Uid, post_reaction_published),
            ha_events:log_friend_event(PostOwnerUid, Uid, ItemId, post_reaction_published),
            stat:count(StatNamespace ++ "/feed", "post_reaction"),
            stat:count(StatNamespace ++ "/feed", "post_reaction_by_cc", 1, [{cc, CC}]),
            stat:count(StatNamespace ++ "/feed", "post_reaction_by_dev", 1, [{is_dev, IsDev}]);
        _ -> ok
    end,
    ok.


report_audience_size(Namespace, Metric, CC, AudienceSize) when AudienceSize >= 0 ->
    stat:count("HA/" ++ Namespace, Metric ++ "_audience_size", AudienceSize, [{cc, CC}]);
report_audience_size(_Namespace, _Metric, _CC, _AudienceSize) ->
    ok.


-spec feed_item_retracted(Uid :: binary(), ItemId :: binary(), ItemType :: atom()) -> ok.
feed_item_retracted(Uid, ItemId, ItemType) ->
    ?INFO("counting Uid:~p, ItemId: ~p, ItemType:~p", [Uid, ItemId, ItemType]),
    ha_events:log_user_event(Uid, item_retracted),
    stat:count("HA/feed", "retract_" ++ atom_to_list(ItemType)),
    ok.


-spec group_feed_item_published(Gid :: binary(), Uid :: binary(), PostOwnerUid :: binary(),
    ItemId :: binary(), ItemType :: atom(), AudienceSize :: integer(),
    MediaCounters :: pb_media_counters()) -> ok.
group_feed_item_published(Gid, Uid, PostOwnerUid, ItemId, ItemType, AudienceSize, MediaCounters) ->
    ?INFO("counting Gid: ~p, Uid:~p, ItemId: ~p, ItemType:~p", [Gid, Uid, ItemId, ItemType]),
    {ok, Phone} = model_accounts:get_phone(Uid),
    CC = mod_libphonenumber:get_cc(Phone),
    IsDev = dev_users:is_dev_uid(Uid),
    case ItemType of
        post ->
            ?INFO("post ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            ha_events:log_user_event(Uid, group_post_published),
            report_media_counters(group_post, MediaCounters),
            stat:count("HA/group_feed", "post"),
            report_audience_size("group_feed", "post", CC, AudienceSize),
            stat:count("HA/group_feed", "post_by_cc", 1, [{cc, CC}]),
            stat:count("HA/group_feed", "post_by_dev", 1, [{is_dev, IsDev}]);
        comment ->
            ?INFO("comment ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            ha_events:log_user_event(Uid, group_comment_published),
            ha_events:log_friend_event(PostOwnerUid, Uid, ItemId, group_comment_published),
            report_media_counters(group_comment, MediaCounters),
            stat:count("HA/group_feed", "comment"),
            report_audience_size("group_feed", "comment", CC, AudienceSize),
            stat:count("HA/group_feed", "comment_by_cc", 1, [{cc, CC}]),
            stat:count("HA/group_feed", "comment_by_dev", 1, [{is_dev, IsDev}]);
        comment_reaction ->
            ?INFO("comment_reaction ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            ha_events:log_user_event(Uid, group_comment_reaction_published),
            ha_events:log_friend_event(PostOwnerUid, Uid, ItemId, group_comment_reaction_published),
            stat:count("HA/group_feed", "comment_reaction"),
            stat:count("HA/group_feed", "comment_reaction_by_cc", 1, [{cc, CC}]),
            stat:count("HA/group_feed", "comment_reaction_by_dev", 1, [{is_dev, IsDev}]);
        post_reaction ->
            ?INFO("post_reaction ~s from Uid: ~s CC: ~s IsDev: ~p",[ItemId, Uid, CC, IsDev]),
            ha_events:log_user_event(Uid, group_post_reaction_published),
            ha_events:log_friend_event(PostOwnerUid, Uid, ItemId, group_post_reaction_published),
            stat:count("HA/group_feed", "post_reaction"),
            stat:count("HA/group_feed", "post_reaction_by_cc", 1, [{cc, CC}]),
            stat:count("HA/group_feed", "post_reaction_by_dev", 1, [{is_dev, IsDev}]);
        _ -> ok
    end,
    ok.


-spec group_feed_item_retracted(Gid :: binary(), Uid :: binary(), ItemId :: binary(), ItemType :: atom()) -> ok.
group_feed_item_retracted(Gid, Uid, ItemId, ItemType) ->
    ?INFO("counting Gid: ~p, Uid:~p, ItemId: ~p, ItemType:~p", [Gid, Uid, ItemId, ItemType]),
    ha_events:log_user_event(Uid, item_retracted),
    stat:count("HA/group_feed", "retract_" ++ atom_to_list(ItemType)),
    ok.


-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
register_user(Uid, _Server, Phone, CampaignId) ->
    ?INFO("counting uid:~s", [Uid]),
    AppType = util_uid:get_app_type(Uid),
    StatNamespace = util:get_stat_namespace(AppType),
    case util:is_test_number(Phone) of
        false ->
            stat:count(StatNamespace ++ "/account", "registration"),
            CC = mod_libphonenumber:get_region_id(Phone),
            IsInvitedTag = {is_invited, model_invites:is_invited(Phone)},
            stat:count(StatNamespace ++ "/account", "registration_by_cc", 1, [{cc, CC}, IsInvitedTag]),
            stat:count(StatNamespace ++ "/account", "registration_by_cc_and_campaign_id", 1, [{cc, CC}, {campaign_id, CampaignId}]),
            stat:count(StatNamespace ++ "/account", "registration_invites", 1, [IsInvitedTag]),
            %% Fetch their last verified response and count the registration with that lang_id.
            {ok, GatewayResponses} = model_phone:get_all_gateway_responses(Phone, AppType),
            LangId = case lists:search(
                    fun(GatewayResponse) ->
                        GatewayResponse#gateway_response.verified
                    end, GatewayResponses) of
                {value, VerifiedResponse} ->
                    VerifiedResponse#gateway_response.lang_id;
                false ->
                    undefined
            end,
            LangId1 = mod_translate:recast_langid(LangId),
            stat:count(StatNamespace ++ "/account", "registration_by_lang_id", 1,
                [{lang_id, util:to_list(LangId1)}]),
            % get most recent inviter and track invite string used
            case IsInvitedTag of
                {is_invited, true} ->
                    {ok, InviterList} = model_invites:get_inviters_list(Phone),
                    {RecentInviterUid, _Ts} = lists:nth(1, InviterList),
                    Event = #{
                        phone => Phone,
                        inviter_uid => RecentInviterUid
                    },
                    ha_events:log_event(<<"server.invite_strings">>, Event);
                _ -> ok
            end,
            ok;
        true ->
            stat:count(StatNamespace ++ "/account", "registration_test_account")
    end,
    new_user(Uid),
    ok.


-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
re_register_user(Uid, _Server, Phone, CampaignId) ->
    ?INFO("counting uid:~s", [Uid]),
    case util:is_test_number(Phone) of
        false ->
            stat:count("HA/account", "re_register"),
            CC = mod_libphonenumber:get_region_id(Phone),
            stat:count("HA/account", "re_registration_by_cc", 1, [{cc, CC}]),
            stat:count("HA/account", "re_registration_by_cc_and_campaign_id", 1, [{cc, CC}, {campaign_id, CampaignId}]),
            ok;
        true ->
            stat:count("HA/account", "re_register_test_account")
    end,
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
        #pb_chat_stanza{chat_type = chat} ->
            stat:count("HA/messaging", Action ++ "_im"),
            Uid = case Action of
                "send" ->
                    ha_events:log_user_event(FromUid, im_sent),
                    FromUid;
                "receive" ->
                    ha_events:log_user_event(ToUid, im_recv),
                    ToUid
            end,
            {ok, Phone} = model_accounts:get_phone(Uid),
            CC = mod_libphonenumber:get_cc(Phone),
            IsDev = dev_users:is_dev_uid(Uid),
            stat:count("HA/messaging", Action ++ "_im_by_cc", 1, [{cc, CC}]),
            stat:count("HA/messaging", Action ++ "_im_by_dev", 1, [{is_dev, IsDev}]);
        #pb_chat_stanza{chat_type = chat_reaction} ->
            stat:count("HA/messaging", Action ++ "_im_reaction"),
            Uid = case Action of
                "send" ->
                    ha_events:log_user_event(FromUid, im_reaction_sent),
                    FromUid;
                "receive" ->
                    ha_events:log_user_event(ToUid, im_reaction_recv),
                    ToUid
            end,
            {ok, Phone} = model_accounts:get_phone(Uid),
            CC = mod_libphonenumber:get_cc(Phone),
            IsDev = dev_users:is_dev_uid(Uid),
            stat:count("HA/messaging", Action ++ "_im_reaction_by_cc", 1, [{cc, CC}]),
            stat:count("HA/messaging", Action ++ "_im_reaction_by_dev", 1, [{is_dev, IsDev}]);
        #pb_seen_receipt{thread_id = ThreadId, id = ContentId} ->
            case ThreadId of
                undefined ->
                    stat:count("HA/im_receipts", Action ++ "_seen"),
                    case Action of
                        "send" ->
                            %% FromUid saw im
                            ha_events:log_user_event(FromUid, im_send_seen);
                        "receive" ->
                            %% ToUid's im was seen by FromUid
                            ha_events:log_user_event(ToUid, im_receive_seen),
                            ha_events:log_friend_event(ToUid, FromUid, ContentId, im_receive_seen)
                    end;
                _ ->
                    StatNamespace = util:get_stat_namespace(FromUid),
                    stat:count(StatNamespace ++ "/feed_receipts", Action ++ "_seen"),
                    %% TODO (murali@): Doing a lookup for every seen receipt is not great.
                    %% This is okay for now but eventually - we should ask clients to send this info.
                    PostTag = case model_feed:get_post_tag(ContentId) of
                        {ok, Tag} -> Tag;
                        {error, _} -> undefined
                    end,
                    case Action of
                        "send" ->
                            %% FromUid saw post
                            {ok, FromPhone} = model_accounts:get_phone(FromUid),
                            FromCC = mod_libphonenumber:get_cc(FromPhone),
                            stat:count(StatNamespace ++ "/feed_receipts", "post_viewed"),
                            stat:count(StatNamespace ++ "/feed_receipts", "post_viewed_by_cc", 1, [{cc, FromCC}]),

                            %% Add seen receipt counters by post_tag.
                            stat:count(StatNamespace ++ "/feed_receipts", "post_viewed_by_tag", 1, [{tag, PostTag}]),
                            stat:count(StatNamespace ++ "/feed_receipts", "post_viewed_by_tag_cc", 1, [{cc, FromCC}, {tag, PostTag}]),
                            ha_events:log_user_event(FromUid, post_send_seen),
                            mod_ka_vanity:report_metrics(ToUid, ContentId, seen),
                            case PostTag =:= moment of
                                true -> ha_events:log_user_event(FromUid, secret_post_send_seen);
                                false -> ok
                            end;
                        "receive" ->
                            %% ToUid's post was seen by FromUid
                            ha_events:log_user_event(ToUid, post_receive_seen),
                            ha_events:log_friend_event(ToUid, FromUid, ContentId, post_receive_seen),
                            case PostTag =:= moment of
                                true -> ha_events:log_user_event(ToUid, secret_post_receive_seen);
                                false -> ok
                            end
                    end
            end;
        #pb_screenshot_receipt{thread_id = ThreadId} ->
            case ThreadId of
                undefined -> ok;
                <<"feed">> ->
                    StatNamespace = util:get_stat_namespace(FromUid),
                    stat:count(StatNamespace ++ "/feed_receipts", Action ++ "_screenshot"),
                    case Action of
                        "send" ->
                            %% FromUid screenshots the post
                            {ok, FromPhone} = model_accounts:get_phone(FromUid),
                            FromCC = mod_libphonenumber:get_cc(FromPhone),
                            stat:count(StatNamespace ++ "/feed_receipts", "post_screenshot"),
                            stat:count(StatNamespace ++ "/feed_receipts", "post_screenshot_by_cc", 1, [{cc, FromCC}]),
                            ha_events:log_user_event(FromUid, post_send_screenshot);
                        "receive" ->
                            %% ToUid's post was screenshot
                            ha_events:log_user_event(ToUid, post_receive_screenshot)
                    end
                end;
        #pb_delivery_receipt{} -> stat:count("HA/im_receipts", Action ++ "_received");
        _ -> ok
    end;
count_packet(Namespace, _Action, #pb_presence{}) ->
    stat:count(Namespace, "presence");
count_packet(Namespace, _Action, #pb_iq{} = Iq) ->
    ?DEBUG("Iq: ~p", [Iq]),
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

-spec report_media_counters(ContentType :: atom(), MediaCounters :: pb_media_counters()) -> ok.
report_media_counters(_ContentType, undefined) -> ok;
report_media_counters(ContentType, MediaCounters) ->
    try
        ContentTypeList = util:to_list(ContentType),
        MediaType = util:get_detailed_media_type(MediaCounters),
        stat:count("HA/media", "agg_content", 1,
                [{"content_type", ContentTypeList}, {"media_type", util:to_list(MediaType)}]),

        NumImages = MediaCounters#pb_media_counters.num_images,
        NumVideos = MediaCounters#pb_media_counters.num_videos,
        NumAudio = MediaCounters#pb_media_counters.num_audio,
        %% Count images.
        if
            NumImages =:= 0 -> ok;
            true ->
                stat:count("HA/media", "agg_media", NumImages,
                    [{"content_type", ContentTypeList}, {"media_type", "image"}])
        end,
        %% Count videos.
        if
            NumVideos =:= 0 -> ok;
            true ->
                stat:count("HA/media", "agg_media", NumVideos,
                    [{"content_type", ContentTypeList}, {"media_type", "video"}])
        end,
        %% Count audio notes.
        if
            NumAudio =:= 0 -> ok;
            true ->
                stat:count("HA/media", "agg_media", NumAudio,
                    [{"content_type", ContentTypeList}, {"media_type", "audio"}])
        end,
        ok
    catch
        Class: Reason: Stacktrace ->
            ?ERROR("report_media_counters failed, Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end.


event_fab_action(#pb_event_data{uid = _UidInt, platform = _Platform, cc = _CC,
        edata = #pb_fab_action{type = FabActionType}} = Event) ->
    stat:count("HA/fab_action", "action_type", 1, [{type, FabActionType}]),
    Event;
event_fab_action(Event) ->
    Event.
