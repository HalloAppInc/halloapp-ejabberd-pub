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

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% hooks
-export([
    offline_message_version_filter/4,
    push_version_filter/4
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, _Opts) ->
    ?INFO("mod_packet_filter: start", []),
    ejabberd_hooks:add(offline_message_version_filter, Host, ?MODULE, offline_message_version_filter, 50),
    ejabberd_hooks:add(push_version_filter, Host, ?MODULE, push_version_filter, 50),
    ok.

stop(Host) ->
    ?INFO("mod_packet_filter: stop", []),
    ejabberd_hooks:delete(offline_message_version_filter, Host, ?MODULE, offline_message_version_filter, 50),
    ejabberd_hooks:delete(push_version_filter, Host, ?MODULE, push_version_filter, 50),
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
    PayloadType = util:to_atom(ContentType),
    case check_content_version_rules(Platform, ClientVersion, PayloadType, Message) of
        false ->
            ?INFO("Uid: ~s, Dropping message for msgid: ~s, content: ~s due to client version: ~s",
                    [Uid, MsgId, PayloadType, ClientVersion]),
            deny;
        true -> allow
    end;
offline_message_version_filter(deny, _, _, _) -> deny.


-spec push_version_filter(Acc :: allow | deny, Uid :: binary(), PushInfo :: push_info(),
        Message :: pb_msg()) -> allow | deny.
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
        %% remove these delete_notice filters in 2months - 05-18-2021.
        #pb_packet{stanza = #pb_msg{payload = #pb_contact_list{type = delete_notice}}} ->
            false;
        #pb_packet{stanza = #pb_msg{payload = #pb_contact_list{contacts = [Contact]}}} ->
            case Contact#pb_contact.uid of
                <<>> -> false;
                _ -> true
            end;
        _ ->
            check_version_rules(Platform, ClientVersion, PayloadType)
    end.


%% Common Version rules for both push notifications and messages.
%% In the future - when rules are different we can have specific functions for the additional rules.
%% TODO(murali@): split this rules into separate functions for offline and push.
-spec check_version_rules(Platform :: ios | android,
        ClientVersion :: binary(), ContentType :: atom()) -> boolean().

%% TODO(murali@): we have several accounts with invalid client_version,
%% revisit in 2 months on 05-03-2021 after deleting some inactive accounts.
check_version_rules(_, undefined, _) ->
    ?INFO("should-not-happen, invalid client_version"),
    false;

%% We were sending this a while back and this was blocking offline queue - since clients would not ack it.
%% TODO(murali@): check with teams if they are acking it and only then enable this.
check_version_rules(_, _ClientVersion, error_st) ->
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

check_version_rules(_, _, _) ->
    true.

