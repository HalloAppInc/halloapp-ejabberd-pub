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
        false -> ?WARNING_MSG("ignoring push: ~p", [Message])
    end,
    Acc.


-spec should_push(Message :: message()) -> boolean(). 
should_push(#message{type = Type, sub_els = [SubEl]}) ->
    if
        Type =:= headline ->
            %% TODO(murali@): remove the old api and then disable the format of push.
            %% Push pubsub messages with type=headline, all new published posts and comments.
            true;

        Type =:= groupchat andalso is_record(SubEl, group_chat) ->
            %% Push all group chat messages: all messages with type=groupchat and group_chat as the subelement.
            true;

        is_record(SubEl, chat) ->
            %% Push chat messages: all messages with chat as the subelement.
            true;

        is_record(SubEl, feed_st) andalso SubEl#feed_st.action =:= publish ->
            %% Ignore new feed messages for now.. because we anyways send a push with old stanza.
            false;

        is_record(SubEl, contact_list) ->
            %% Push contact related notifications: could be contact_hash or new relationship notifications.
            true;

        Type =:= groupchat andalso is_record(SubEl, group_feed_st) andalso
                SubEl#group_feed_st.action =:= publish ->
            %% Push all group feed messages with action = publish.
            true;

        true ->
            %% Ignore everything else.
            false
    end.


-spec push_message(Message :: message()) -> ok.
push_message(#message{to = #jid{luser = User, lserver = Server}} = Message) ->
    PushInfo = mod_push_tokens:get_push_info(User, Server),
    case PushInfo#push_info.token of
        undefined -> ?INFO_MSG("Uid: ~s, ignore push: undefined push token", [User]);
        _ -> push_message(Message, PushInfo)
    end.


-spec push_message(Message :: message(), PushInfo :: push_info()) -> ok.
push_message(Message, #push_info{os = <<"android">>} = PushInfo) ->
    mod_android_push:push(Message, PushInfo);

push_message(Message, #push_info{os = Os} = PushInfo)
        when Os =:= <<"ios">>; Os =:= <<"ios_dev">> ->
    mod_ios_push:push(Message, PushInfo).

