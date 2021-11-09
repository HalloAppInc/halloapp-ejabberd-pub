%%%----------------------------------------------------------------------
%%% File    : mod_push_notifications.erl
%%%
%%% Copyright (C) 2020 HalloApp inc.
%%%
%%%----------------------------------------------------------------------

-module(mod_push_notifications).
-author('murali').
-behaviour(gen_mod).

-include("ha_types.hrl").
-include("logger.hrl").
-include("packets.hrl").
-include("account.hrl").
-include ("push_message.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% hooks
-export([
    push_message_hook/1
]).

-ifdef(TEST).
-export([
    should_push/1
]).
-endif.


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, _Opts) ->
    ?DEBUG("mod_push_notifications: start", []),
    ejabberd_hooks:add(push_message_hook, Host, ?MODULE, push_message_hook, 50),
    ok.

stop(Host) ->
    ?DEBUG("mod_push_notifications: stop", []),
    ejabberd_hooks:delete(push_message_hook, Host, ?MODULE, push_message_hook, 50),
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

-spec push_message_hook(pb_msg()) -> pb_msg().
push_message_hook(#pb_msg{} = Message) ->
    ?DEBUG("~p", [Message]),
    case should_push(Message) of
        true -> push_message(Message);
        false -> ?INFO("ignoring push, MsgId: ~p", [Message#pb_msg.id])
    end,
    Message.


%% Determine whether message should be pushed or not.. based on the content.
-spec should_push(Message :: pb_msg()) -> boolean().
should_push(#pb_msg{type = Type, payload = Payload} = Message) ->
    PayloadType = util:get_payload_type(Message),
    if
        Type =:= groupchat andalso PayloadType =:= pb_group_chat ->
            %% Push all group chat messages: all messages with type=groupchat and group_chat as the subelement.
            true;

        Type =:= groupchat andalso PayloadType =:= pb_group_chat_retract ->
            %% Send silent pushes for all group chat retract messages.
            true;

        PayloadType =:= pb_chat_stanza ->
            %% Push chat messages: all messages with chat as the subelement.
            true;

        PayloadType =:= pb_chat_retract ->
            %% Send silent pushes for all chat retract messages.
            true;

        PayloadType =:= pb_feed_item andalso Payload#pb_feed_item.action =:= publish ->
            %% Send pushes for feed messages: both posts and comments.
            true;

        PayloadType =:= pb_feed_item andalso Payload#pb_feed_item.action =:= retract ->
            %% Send silent pushes for retract feed messages: both posts and comments.
            true;

        PayloadType =:= pb_contact_list andalso PayloadType#pb_contact_list.type =:= delete_notice ->
            %% Dont push deleted notice contact notifications to the clients.
            false;

        PayloadType =:= pb_contact_list orelse PayloadType =:= pb_contact_hash ->
            %% Push contact related notifications: could be contact_hash or new relationship notifications.
            true;

        PayloadType =:= pb_group_feed_item andalso Payload#pb_group_feed_item.action =:= publish ->
            %% Push all group feed messages with action = publish.
            true;

        PayloadType =:= pb_group_feed_item andalso Payload#pb_group_feed_item.action =:= retract ->
            %% Send silent pushes for all group feed messages with action = retract.
            true;

        PayloadType =:= pb_rerequest ->
            %% Send silent pushes for rerequest stanzas.
            true;

        PayloadType =:= pb_group_feed_rerequest ->
            %% Send silent pushes for group feed rerequest stanzas.
            true;

        PayloadType =:= pb_home_feed_rerequest ->
            %% Send silent pushes for home feed rerequest stanzas.
            true;

        PayloadType =:= pb_group_feed_items ->
            %% Send silent pushes for group feed items stanzas.
            true;

        PayloadType =:= pb_feed_items ->
            %% Send silent pushes for home feed items stanzas.
            true;

        PayloadType =:= pb_request_logs ->
            %% Send silent pushes for request logs notification
            true;

        Type =:= groupchat andalso PayloadType =:= pb_group_stanza ->
            %% Push when someone is added to a group
            ToUid = Message#pb_msg.to_uid,
            WasAdded = lists:any(
                fun (MemberSt) ->
                    MemberSt#pb_group_member.uid =:= ToUid andalso MemberSt#pb_group_member.action =:= add
                end, Payload#pb_group_stanza.members),
            WasAdded;

        PayloadType =:= pb_wake_up ->
            %% Push sms_app wakeup notifications
            true;

        %% Send push notifications for all call related messages.
        PayloadType =:= pb_incoming_call ->
            true;

        true ->
            %% Ignore everything else.
            false
    end.


% TODO: add stat:count here to count invalid_token failures.
-spec push_message(Message :: pb_msg()) -> ok.
push_message(#pb_msg{id = _MsgId, to_uid = User} = Message) ->
    PushInfo = mod_push_tokens:get_push_info(User),
    ClientType = util_ua:get_client_type(PushInfo#push_info.client_version),
    push_message(Message, PushInfo, ClientType).


-spec push_message(Message :: pb_msg(), PushInfo :: push_info(), Os :: client_type()) -> ok.
push_message(#pb_msg{id = MsgId, to_uid = User} = _Message, PushInfo, undefined) ->
    ?ERROR("Uid: ~s, MsgId: ~p ignore push: invalid client version: ~p",
        [User, MsgId, PushInfo#push_info.client_version]);
push_message(#pb_msg{id = MsgId, to_uid = User} = Message, PushInfo, android) ->
    case PushInfo#push_info.token of
        undefined ->
            %% invalid fcm-token for android.
            ?INFO("Uid: ~s, MsgId: ~p ignore push: no push token", [User, MsgId]);
        _ ->
            push_message_internal(Message, PushInfo)
    end;
push_message(#pb_msg{id = MsgId, to_uid = User} = Message, PushInfo, ios) ->
    case {util:is_voip_incoming_message(Message), PushInfo#push_info.voip_token, PushInfo#push_info.token} of
        {true, undefined, _} ->
            %% voip message with invalid voip token - should never happen.
            ?WARNING("Uid: ~s, MsgId: ~p ignore push: no voip-push token", [User, MsgId]);
        {true, _, _} ->
            %% voip message with valid voip token.
            push_message_internal(Message, PushInfo);
        {false, _, undefined} ->
            %% normal message with invalid apns token.
            ?INFO("Uid: ~s, MsgId: ~p ignore push: no push token", [User, MsgId]);
        {false, _, _} ->
            %% normal message with valid apns token.
            push_message_internal(Message, PushInfo)
    end.


-spec push_message_internal(Message :: pb_msg(), PushInfo :: push_info()) -> ok.
push_message_internal(#pb_msg{id = MsgId, to_uid = User} = Message, PushInfo) ->
    Server = util:get_host(),
    log_invalid_langId(PushInfo),
    ClientVersion = PushInfo#push_info.client_version,
    case ejabberd_hooks:run_fold(push_version_filter, Server, allow, [User, PushInfo, Message]) of
        allow ->
            ?INFO("Uid: ~s, MsgId: ~p", [User, MsgId]),
            push_message(Message, PushInfo);
        deny ->
            ?INFO("Uid: ~s, MsgId: ~p ignore push: invalid client version: ~p",
                    [User, MsgId, ClientVersion])
    end.


-spec push_message(Message :: pb_msg(), PushInfo :: push_info()) -> ok.
push_message(Message, #push_info{os = <<"android">>} = PushInfo) ->
    mod_android_push:push(Message, PushInfo);
push_message(Message, #push_info{os = Os} = PushInfo)
        when Os =:= <<"ios">>; Os =:= <<"ios_dev">> ->
    mod_ios_push:push(Message, PushInfo);
push_message(Message, #push_info{voip_token = VoipToken} = PushInfo)
        when VoipToken =/= undefined ->
    mod_ios_push:push(Message, PushInfo);
push_message(#pb_msg{id = MsgId, to_uid = Uid}, #push_info{os = <<"ios_appclip">>}) ->
    ?INFO("ignoring ios_appclip push, Uid: ~p, MsgId: ~p", [Uid, MsgId]),
    ok.


-spec log_invalid_langId(PushInfo :: push_info()) -> ok.
log_invalid_langId(#push_info{uid = Uid,
        lang_id = LangId, client_version = ClientVersion} = _PushInfo) ->
    case mod_client_version:is_valid_version(ClientVersion) =:= true andalso
            LangId =:= undefined of
        true ->
            ?WARNING("Uid: ~p, Invalid lang_id: ~p", [Uid, LangId]);
        false -> ok
    end.

