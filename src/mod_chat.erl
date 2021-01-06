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
-include("account.hrl").


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
    Packet1 = if
        FromUid =:= <<>> ->
            % TODO: (nikola): I don't think this can happen
            ?WARNING("MsgID: ~s Type: ~s has no FromUid", [MsgId, SubElementType]),
            Packet;
        not is_record(SubEl, chat) andalso not is_record(SubEl, silent_chat) ->
            Packet;
        true ->
            set_sender_info(Packet)
    end,
    {Packet1, State};

user_send_packet({_Packet, _State} = Acc) ->
    Acc.

%%====================================================================
%% internal functions
%%====================================================================

-spec set_sender_info(Message :: message()) -> message().
set_sender_info(#message{id = MsgId, from = #jid{luser = FromUid}} = Message) ->
    ?INFO("FromUid: ~s, MsgId: ~s", [FromUid, MsgId]),
    {ok, SenderAccount} = model_accounts:get_account(FromUid),
    set_sender_info(Message, SenderAccount#account.name, SenderAccount#account.client_version).


-spec set_sender_info(Message :: message(), Name :: binary(), ClientVersion :: binary()) -> message().
set_sender_info(#message{sub_els = [#chat{} = Chat]} = Message, Name, ClientVersion) ->
    Chat1 = Chat#chat{sender_name = Name, sender_client_version = ClientVersion},
    Message#message{sub_els = [Chat1]};

set_sender_info(#message{sub_els = [#silent_chat{chat = Chat}]} = Message, Name, ClientVersion) ->
    Chat1 = Chat#chat{sender_name = Name, sender_client_version = ClientVersion},
    Message#message{sub_els = [#silent_chat{chat = Chat1}]};

set_sender_info(#message{} = Message, _Name, _ClientVersion) ->
    ?ERROR("Invalid message to set sender info: ~p", [Message]),
    Message.

