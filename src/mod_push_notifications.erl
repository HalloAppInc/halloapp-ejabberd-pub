%%%----------------------------------------------------------------------
%%% File    : mod_push_notifications.erl
%%%
%%% Copyright (C) 2020 HalloApp inc.
%%%
%%%----------------------------------------------------------------------

-module(mod_push_notifications).
-author('murali').
-behaviour(gen_mod).

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
should_push(#pb_msg{rerequest_count = RerequestCount} = _Message)
        when RerequestCount > 0 ->
    false;
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

        Type =:= groupchat andalso PayloadType =:= pb_group_stanza ->
            %% Push when someone is added to a group
            ToUid = Message#pb_msg.to_uid,
            WasAdded = lists:any(
                fun (MemberSt) ->
                    MemberSt#pb_group_member.uid =:= ToUid andalso MemberSt#pb_group_member.action =:= add
                end, Payload#pb_group_stanza.members),
            WasAdded;

        true ->
            %% Ignore everything else.
            false
    end.


-spec push_message(Message :: pb_msg()) -> ok.
push_message(#pb_msg{id = MsgId, to_uid = User} = Message) ->
    Server = util:get_host(),
    PushInfo = mod_push_tokens:get_push_info(User, Server),
    case PushInfo#push_info.token of
        undefined ->
            % TODO: add stat:count here to count this
            ?INFO("Uid: ~s, MsgId: ~p ignore push: no push token", [User, MsgId]);
        _ ->
            ClientVersion = PushInfo#push_info.client_version,
            case ejabberd_hooks:run_fold(push_version_filter, Server, allow, [User, PushInfo, Message]) of
                allow ->
                    ?INFO("Uid: ~s, MsgId: ~p", [User, MsgId]),
                    push_message(Message, PushInfo);
                deny ->
                    ?INFO("Uid: ~s, MsgId: ~p ignore push: invalid client version: ~p",
                            [User, MsgId, ClientVersion])
            end
    end.


-spec push_message(Message :: pb_msg(), PushInfo :: push_info()) -> ok.
push_message(Message, #push_info{os = <<"android">>} = PushInfo) ->
    mod_android_push:push(Message, PushInfo);

push_message(Message, #push_info{os = Os} = PushInfo)
        when Os =:= <<"ios">>; Os =:= <<"ios_dev">> ->
    mod_ios_push:push(Message, PushInfo).

