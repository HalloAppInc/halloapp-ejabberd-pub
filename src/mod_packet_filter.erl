%%%----------------------------------------------------------------------
%%% File    : mod_packet_filter.erl
%%%
%%% Copyright (C) 2021 HalloApp inc.
%%%
%%%----------------------------------------------------------------------

-module(mod_packet_filter).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("account.hrl").
-include("offline_message.hrl").
-include ("push_message.hrl").

-dialyzer({no_match, check_version_rules/3}).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% hooks
-export([
    offline_message_version_filter/4,
    push_version_filter/4,
    user_send_packet/1
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("mod_packet_filter: start", []),
    %% HalloApp
    ejabberd_hooks:add(offline_message_version_filter, halloapp, ?MODULE, offline_message_version_filter, 50),
    ejabberd_hooks:add(push_version_filter, halloapp, ?MODULE, push_version_filter, 50),
    ejabberd_hooks:add(user_send_packet, halloapp, ?MODULE, user_send_packet, 100),
    %% Katchup
    ejabberd_hooks:add(offline_message_version_filter, katchup, ?MODULE, offline_message_version_filter, 50),
    ejabberd_hooks:add(push_version_filter, katchup, ?MODULE, push_version_filter, 50),
    ejabberd_hooks:add(user_send_packet, katchup, ?MODULE, user_send_packet, 100),
    %% Photo Sharing
    ejabberd_hooks:add(offline_message_version_filter, ?PHOTO_SHARING, ?MODULE, offline_message_version_filter, 50),
    ejabberd_hooks:add(push_version_filter, ?PHOTO_SHARING, ?MODULE, push_version_filter, 50),
    ejabberd_hooks:add(user_send_packet, ?PHOTO_SHARING, ?MODULE, user_send_packet, 100),
    ok.

stop(_Host) ->
    ?INFO("mod_packet_filter: stop", []),
    %% HalloApp
    ejabberd_hooks:delete(user_send_packet, halloapp, ?MODULE, user_send_packet, 100),
    ejabberd_hooks:delete(offline_message_version_filter, halloapp, ?MODULE, offline_message_version_filter, 50),
    ejabberd_hooks:delete(push_version_filter, halloapp, ?MODULE, push_version_filter, 50),
    %% Katchup
    ejabberd_hooks:delete(user_send_packet, katchup, ?MODULE, user_send_packet, 100),
    ejabberd_hooks:delete(offline_message_version_filter, katchup, ?MODULE, offline_message_version_filter, 50),
    ejabberd_hooks:delete(push_version_filter, katchup, ?MODULE, push_version_filter, 50),
    %% Photo Sharing
    ejabberd_hooks:delete(user_send_packet, ?PHOTO_SHARING, ?MODULE, user_send_packet, 100),
    ejabberd_hooks:delete(offline_message_version_filter, ?PHOTO_SHARING, ?MODULE, offline_message_version_filter, 50),
    ejabberd_hooks:delete(push_version_filter, ?PHOTO_SHARING, ?MODULE, push_version_filter, 50),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% hooks.
%%====================================================================


-spec offline_message_version_filter(Acc :: allow | deny, Uid :: binary(), ClientVersion :: binary(),
        OfflineMessage :: offline_message()) -> allow | deny.
offline_message_version_filter(allow, Uid, ClientVersion,
        #offline_message{msg_id = MsgId, content_type = ContentType,
        message = Message} = _OfflineMessage) ->
    Platform = util_ua:get_client_type(ClientVersion),
    PayloadType = ContentType,
    case check_content_version_rules(Platform, ClientVersion, PayloadType, Message) of
        false ->
            ?INFO("Uid: ~s, Dropping message for msgid: ~s, content: ~s due to client version: ~s",
                    [Uid, MsgId, PayloadType, ClientVersion]),
            deny;
        true -> allow
    end;
offline_message_version_filter(deny, _, _, _) -> deny.


-spec push_version_filter(Acc :: allow | deny, Uid :: binary(), PushInfo :: push_info(),
        Message :: message()) -> allow | deny.
push_version_filter(allow, Uid, PushInfo, #pb_msg{id = MsgId} = Message) ->
    ClientVersion = PushInfo#push_info.client_version,
    Platform = util_ua:get_client_type(ClientVersion),
    PayloadType = util:get_payload_type(Message),
    case check_version_rules(Platform, ClientVersion, PayloadType) of
        false ->
            ?INFO("Uid: ~s, Dropping push for msgid: ~s, content: ~s due to client version: ~s",
                    [Uid, MsgId, PayloadType, ClientVersion]),
            deny;
        true -> allow
    end;
push_version_filter(deny, _, _, _) -> deny.


user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_group_feed_rerequest{}} = Packet, State}) ->
    case model_accounts:get_client_version(ToUid) of
        {ok, ClientVersion} ->
            Platform = util_ua:get_client_type(ClientVersion),
            case check_version_rules(Platform, ClientVersion, pb_group_feed_rerequest) of
                false ->
                    ?INFO("Dropping pb_group_feed_rerequest FromUid: ~s ToUid: ~s MsgId: ~s", [FromUid, ToUid, MsgId]),
                    {drop, State};
                true -> {Packet, State}
            end;
        {error, _} ->
            ?ERROR("Dropping pb_group_feed_rerequest FromUid: ~s ToUid: ~s MsgId: ~s", [FromUid, ToUid, MsgId]),
            {drop, State}
    end;
user_send_packet({_Packet, _State} = Acc) ->
    Acc.


%%====================================================================
%% internal functions.
%%====================================================================

-spec check_content_version_rules(Platform :: ios | android,
        ClientVersion :: binary(), ContentType :: atom(), Message :: binary()) -> boolean().
check_content_version_rules(Platform, ClientVersion, PayloadType, Message) ->
    case enif_protobuf:decode(Message, pb_packet) of
        {error, _} ->
            ?ERROR("Failed decoding message: ~p", [Message]),
            false;
        #pb_packet{stanza = #pb_msg{payload = #pb_group_stanza{group_type = GroupType}}} ->
            case GroupType of
                chat -> mod_groups:is_chat_enabled_client_version(ClientVersion);
                _ -> true
            end;
        #pb_packet{stanza = #pb_msg{payload = #pb_contact_list{contacts = [Contact]}}} ->
            case Contact#pb_contact.uid of
                <<>> -> false;
                _ -> true
            end;
        #pb_packet{stanza = #pb_msg{payload = #pb_moment_notification{prompt = Prompt}}} ->
            %% Filter out problematic messages from peoples offline queues.
            case Prompt =:= <<32,54,32,49,32,142,32,37,32,63,32,83>> of
                true -> false;
                false -> true
            end;
        #pb_packet{stanza = #pb_msg{payload = #pb_feed_item{action = expire}}} ->
            Platform = util_ua:get_client_type(ClientVersion),
            case Platform of
                ios ->
                    util_ua:is_version_greater_than(ClientVersion, <<"Katchup/iOS0.05.41">>);
                _ ->
                    true
            end;
        _ ->
            check_version_rules(Platform, ClientVersion, PayloadType)
    end.


%% Common Version rules for both push notifications and messages.
%% In the future - when rules are different we can have specific functions for the additional rules.
%% TODO(murali@): split this rules into separate functions for offline and push.
-spec check_version_rules(Platform :: ios | android,
        ClientVersion :: maybe(binary()), ContentType :: atom()) -> boolean().

%% TODO(murali@): we have several accounts with invalid client_version,
%% revisit in 2 months on 05-03-2021 after deleting some inactive accounts.
check_version_rules(_, undefined, _) ->
    ?INFO("should-not-happen, invalid client_version"),
    false;


%% Dont send group_feed messages and pushes to ios clients < 0.3.65
check_version_rules(ios, ClientVersion, group_feed_st) ->
    util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS0.3.65">>);

%% Dont send group_feed messages and pushes to android clients < 0.93
check_version_rules(android, ClientVersion, group_feed_st) ->
    util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android0.93">>);

%% Dont send group_chat messages and pushes to android clients >= 0.129
check_version_rules(android, ClientVersion, group_chat) ->
    util_ua:is_version_less_than(ClientVersion, <<"HalloApp/Android0.129">>);

%% Dont send group_chat messages and pushes to ios clients >= 1.3.95
check_version_rules(ios, ClientVersion, group_chat) ->
    util_ua:is_version_less_than(ClientVersion, <<"HalloApp/iOS1.3.95">>);

%% Dont send group_feed_rerequest messages and pushes to android clients v1.2
check_version_rules(android, ClientVersion, pb_group_feed_rerequest) ->
    util_ua:is_version_less_than(ClientVersion, <<"HalloApp/Android1.1">>) orelse
        util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android1.2">>);

check_version_rules(_, _, _) ->
    true.

