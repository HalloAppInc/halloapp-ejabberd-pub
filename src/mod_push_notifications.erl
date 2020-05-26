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

offline_message_hook({_, #message{type = Type} = Message} = Acc)
        when Type =:= headline ->
    ?DEBUG("~p", [Message]),
    push_message(Message),
    Acc;

offline_message_hook({_, #message{sub_els = [SubEl]} = Message} = Acc)
        when is_record(SubEl, chat) ->
    ?DEBUG("~p", [Message]),
    push_message(Message),
    Acc;

offline_message_hook({_, #message{} = Message} = Acc) ->
    ?WARNING_MSG("ignoring push: ~p", [Message]),
    Acc.


%% TODO(murali@): delete this function if unnecessary.
-spec should_push(Message :: message()) -> {ShouldPush :: boolean(), PushInfo :: push_info()}.
should_push(#message{to = #jid{luser = User, lserver = Server}, sub_els = [#ps_event{
        items = #ps_items{node = Node, items = [#ps_item{type = ItemType}]}}]}) ->
    PushInfo = mod_push_tokens:get_push_info(User, Server),
    ShouldPush = case PushInfo of
        undefined -> false;
        #push_info{os = <<"android">>} -> true;
        #push_info{os = <<"ios_dev">>} -> true;
        #push_info{os = <<"ios">>} -> case ItemType of
            feedpost -> true;
            comment ->
                case Node of
                    <<"feed-", OwnerId/binary>> -> User =:= OwnerId;
                    _ -> false
                end
        end
    end,
    {ShouldPush, PushInfo}.


-spec push_message(Message :: message()) -> ok.
push_message(#message{to = #jid{luser = User, lserver = Server}} = Message) ->
    PushInfo = mod_push_tokens:get_push_info(User, Server),
    case PushInfo of
        undefined -> ?INFO_MSG("Uid: ~s, ignore push: undefined push token", [User]);
        _ -> push_message(Message, PushInfo)
    end.


-spec push_message(Message :: message(), PushInfo :: push_info()) -> ok.
push_message(Message, #push_info{os = <<"android">>} = PushInfo) ->
    mod_android_push:push(Message, PushInfo);

push_message(Message, #push_info{os = Os} = PushInfo)
        when Os =:= <<"ios">>; Os =:= <<"ios_dev">> ->
    mod_ios_push:push(Message, PushInfo).

