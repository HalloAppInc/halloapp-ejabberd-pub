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
    push_message_hook/1,
    push_marketing_alert/2,
    event_push_received/1
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, _Opts) ->
    ?DEBUG("mod_push_notifications: start", []),
    ejabberd_hooks:add(push_message_hook, Host, ?MODULE, push_message_hook, 50),
    ejabberd_hooks:add(event_push_received, ?MODULE, event_push_received, 50),
    ok.

stop(Host) ->
    ?DEBUG("mod_push_notifications: stop", []),
    ejabberd_hooks:delete(event_push_received, ?MODULE, event_push_received, 50),
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

-spec push_message_hook(message()) -> message().
push_message_hook(#pb_msg{} = Message) ->
    ?DEBUG("~p", [Message]),
    push_message(Message),
    Message.


% TODO: add stat:count here to count invalid_token failures.
-spec push_message(Message :: message()) -> ok.
push_message(#pb_msg{id = _MsgId, to_uid = User} = Message) ->
    PushInfo = mod_push_tokens:get_push_info(User),
    ClientType = util_ua:get_client_type(PushInfo#push_info.client_version),
    push_message(Message, PushInfo, ClientType).


-spec push_message(Message :: message(), PushInfo :: push_info(), Os :: client_type()) -> ok.
push_message(#pb_msg{payload = #pb_invitee_notice{}}, _, undefined) -> ok;
push_message(#pb_msg{id = MsgId, to_uid = User} = _Message, PushInfo, undefined) ->
    ?ERROR("Uid: ~s, MsgId: ~p ignore push: invalid client type, push_info: ~p",
        [User, MsgId, PushInfo]);
push_message(#pb_msg{id = MsgId, to_uid = User} = Message, PushInfo, android) ->
    case {PushInfo#push_info.token, PushInfo#push_info.huawei_token} of
        {undefined, undefined} ->
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


-spec push_message_internal(Message :: message(), PushInfo :: push_info()) -> ok.
push_message_internal(#pb_msg{id = MsgId, to_uid = User} = Message, PushInfo) ->
    Server = util:get_host(),
    log_invalid_langId(PushInfo),
    ClientVersion = PushInfo#push_info.client_version,
    case ejabberd_hooks:run_fold(push_version_filter, Server, allow, [User, PushInfo, Message]) of
        allow ->
            ?INFO("Uid: ~s, MsgId: ~p", [User, MsgId]),
            push_message(Message, PushInfo);
        deny ->
            ?INFO("Uid: ~s, MsgId: ~p push denied due to client version: ~p",
                    [User, MsgId, ClientVersion])
    end.


-spec push_message(Message :: message(), PushInfo :: push_info()) -> ok.
push_message(Message, #push_info{os = <<"android">>} = PushInfo) ->
    mod_android_push:push(Message, PushInfo);
push_message(Message, #push_info{os = <<"android_huawei">>} = PushInfo) ->
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


-spec push_marketing_alert(Uid :: binary(), AlertType :: atom()) -> ok.
push_marketing_alert(Uid, AlertType) when AlertType =:= share_post_control orelse
        AlertType =:= invite_friends_control ->
    model_accounts:add_marketing_tag(Uid, util:to_binary(AlertType)),
    ok;

push_marketing_alert(Uid, AlertType) ->
    model_accounts:add_marketing_tag(Uid, util:to_binary(AlertType)),
    MsgId = util_id:new_msg_id(),
    Message = #pb_msg{
        id = MsgId,
        to_uid = Uid,
        payload = #pb_marketing_alert{type = AlertType}
    },
    push_message(Message),
    ok.

event_push_received(#pb_event_data{uid = UidInt, platform = Platform, cc = CC,
        edata = #pb_push_received{id = Id}} = Event) ->
    ?INFO("Uid: ~p Platform: ~s CC: ~s PushId: ~s", [UidInt, Platform, CC, Id]),
    Event;
event_push_received(Event) ->
    Event.


