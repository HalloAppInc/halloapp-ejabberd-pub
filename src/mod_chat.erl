%%%-------------------------------------------------------------------
%%% File    : mod_chat.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-------------------------------------------------------------------

-module(mod_chat).
-author('murali').
-behaviour(gen_mod).

-include("xmpp.hrl").
-include("logger.hrl").


%% gen_mod API.
-export([
    start/2,
    stop/1,
    reload/3,
    mod_options/1,
    depends/2
]).

%% Hooks and API.
-export([
    user_send_packet/1
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% hooks.
%%====================================================================

user_send_packet({#message{id = MsgId} = Packet, State} = _Acc) ->
    From = xmpp:get_from(Packet),
    To = xmpp:get_to(Packet),
    ToUid = To#jid.luser,
    FromUid = From#jid.luser,
    [SubEl] = Packet#message.sub_els,
    SubElementType = element(1, SubEl),
    ?INFO("Uid: ~s sending ~p message to ~s MsgId: ~s",
            [FromUid, SubElementType, ToUid, MsgId]),
    NewPacket = if
        FromUid =:= <<>> ->
            Packet;
        not is_record(SubEl, chat) andalso not is_record(SubEl, silent_chat) ->
            Packet;
        true ->
            set_sender_name(Packet)
    end,
    {NewPacket, State};

user_send_packet({_Packet, _State} = Acc) ->
    Acc.

%%====================================================================
%% internal functions
%%====================================================================

-spec set_sender_name(Packet :: message()) -> message().
set_sender_name(Packet) ->
    MsgId = xmpp:get_id(Packet),
    From = xmpp:get_from(Packet),
    FromUid = From#jid.luser,
    ?INFO("FromUid: ~s, set name on the chat message-id: ~s", [FromUid, MsgId]),
    Name = model_accounts:get_name_binary(FromUid),
    NewPacket = xmpp:set_sender_name(Packet, Name),
    NewPacket.

