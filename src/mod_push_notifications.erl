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
-include("xmpp.hrl").
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

-spec push_message_hook(message()) -> message().
push_message_hook(#message{} = Message) ->
    ?DEBUG("~p", [Message]),
    case should_push(Message) of
        true -> push_message(Message);
        % TODO: make debug, or don't print the full Msg
        false -> ?INFO("ignoring push: ~p", [Message])
    end,
    Message.


%% Determine whether message should be pushed or not.. based on the content.
-spec should_push(Message :: message()) -> boolean().
should_push(#message{rerequest_count = RerequestCount} = _Message)
        when RerequestCount > 0 ->
    false;
should_push(#message{type = Type, sub_els = [SubEl | _]} = Message) ->
    PayloadType = util:get_payload_type(Message),
    if
        Type =:= groupchat andalso PayloadType =:= group_chat ->
            %% Push all group chat messages: all messages with type=groupchat and group_chat as the subelement.
            true;

        PayloadType =:= chat ->
            %% Push chat messages: all messages with chat as the subelement.
            true;

        PayloadType =:= feed_st andalso SubEl#feed_st.action =:= publish ->
            %% Send pushes for feed messages: both posts and comments.
            true;

        PayloadType =:= contact_list ->
            %% Push contact related notifications: could be contact_hash or new relationship notifications.
            true;

        PayloadType =:= group_feed_st andalso SubEl#group_feed_st.action =:= publish ->
            %% Push all group feed messages with action = publish.
            true;

        Type =:= groupchat andalso PayloadType =:= group_st ->
            %% Push when someone is added to a group
            ToUid = Message#message.to#jid.user,
            WasAdded = lists:any(
                fun (MemberSt) ->
                    MemberSt#member_st.uid =:= ToUid andalso MemberSt#member_st.action =:= add
                end, SubEl#group_st.members),
            % TODO: remove this log, here just to make sure it works initially
            ?INFO("group_st push ~p Message; ~p", [WasAdded, Message]),
            WasAdded;

        true ->
            %% Ignore everything else.
            false
    end.


-spec push_message(Message :: message()) -> ok.
push_message(#message{id = MsgId, to = #jid{luser = User, lserver = Server}} = Message) ->
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


-spec push_message(Message :: message(), PushInfo :: push_info()) -> ok.
push_message(Message, #push_info{os = <<"android">>} = PushInfo) ->
    mod_android_push:push(Message, PushInfo);

push_message(Message, #push_info{os = Os} = PushInfo)
        when Os =:= <<"ios">>; Os =:= <<"ios_dev">> ->
    mod_ios_push:push(Message, PushInfo).

