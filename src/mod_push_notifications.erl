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
-include("translate.hrl").
-include("account.hrl").
-include ("push_message.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% hooks
-export([
    offline_message_hook/1
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, _Opts) ->
    ?DEBUG("mod_push_notifications: start", []),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message_hook, 50),
    ok.

stop(Host) ->
    ?DEBUG("mod_push_notifications: stop", []),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message_hook, 50),
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

offline_message_hook({_, #message{} = Message} = Acc) ->
    ?DEBUG("~p", [Message]),
    case should_push(Message) of
        true -> push_message(Message);
        % TODO: make debug, or don't print the full Msg
        false -> ?INFO("ignoring push: ~p", [Message])
    end,
    Acc.


%% Determine whether message should be pushed or not.. based on the content.
-spec should_push(Message :: message()) -> boolean().
should_push(#message{rerequest_count = RerequestCount} = Message)
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
            case version_check_packet(ClientVersion, Message) of
                true ->
                    ?INFO("Uid: ~s, MsgId: ~p", [User, MsgId]),
                    push_message(Message, PushInfo);
                false ->
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


%% Determine whether message should be pushed or not.. based on client_version.
-spec version_check_packet(ClientVersion :: binary(), Message :: message()) -> boolean().
version_check_packet(undefined, #message{to = #jid{luser = Uid}} = _Message) ->
    ?INFO("Uid: ~s, ClientVersion is still undefined", [Uid]),
    true;
version_check_packet(ClientVersion, #message{id = MsgId, to = #jid{luser = Uid}} = Message) ->
    Platform = util_ua:get_client_type(ClientVersion),
    PayloadType = util:get_payload_type(Message),
    case check_version_rules(Platform, ClientVersion, Message) of
        false ->
            ?INFO("Uid: ~s, Dropping msgid: ~s, content: ~s due to client version: ~s",
                    [Uid, MsgId, PayloadType, ClientVersion]),
            false;
        true -> true
    end.


%% Version rules
-spec check_version_rules(Platform :: ios | android,
        ClientVersion :: binary(), Message :: message()) -> boolean().
%% Dont send pubsub messages to ios clients > 0.3.65
check_version_rules(ios, ClientVersion,
        #message{from = #jid{lserver = <<"pubsub.s.halloapp.net">>}}) ->
    util_ua:is_version_less_than(ClientVersion, <<"HalloApp/iOS0.3.65">>);

%% Dont send pubsub messages to android clients > 0.89
check_version_rules(android, ClientVersion,
        #message{from = #jid{lserver = <<"pubsub.s.halloapp.net">>}}) ->
    util_ua:is_version_less_than(ClientVersion, <<"HalloApp/Android0.89">>);

%% Dont send group_feed messages to ios clients < 0.3.65
check_version_rules(ios, ClientVersion,
        #message{sub_els = [#group_feed_st{}]}) ->
    util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS0.3.65">>);

%% Dont send group_feed messages to android clients < 0.93
check_version_rules(android, ClientVersion,
        #message{sub_els = [#group_feed_st{}]}) ->
    util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android0.93">>);

check_version_rules(_, _, _) ->
    true.

