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
-include("packets.hrl").
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

user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = Payload} = Packet, State} = _Acc) ->
    LServer = util:get_host(),
    PayloadType = util:get_payload_type(Packet),
    ?INFO("Uid: ~s sending ~p message to ~s MsgId: ~s", [FromUid, PayloadType, ToUid, MsgId]),
    Packet1 = if
        FromUid =:= <<>> ->
            % TODO: (nikola): I don't think this can happen
            ?WARNING("MsgID: ~s Type: ~s has no FromUid", [MsgId, PayloadType]),
            Packet;
        not is_record(Payload, pb_chat_stanza) andalso not is_record(Payload, pb_silent_chat_stanza) ->
            Packet;
        true ->
            case is_record(Payload, pb_chat_stanza) of
                true -> ejabberd_hooks:run_fold(user_send_im, LServer, [FromUid, MsgId, ToUid]);
                false -> ok
            end,
            set_sender_info(Packet)
    end,
    {Packet1, State};

user_send_packet({_Packet, _State} = Acc) ->
    Acc.

%%====================================================================
%% internal functions
%%====================================================================

-spec set_sender_info(Message :: pb_msg()) -> pb_msg().
set_sender_info(#pb_msg{id = MsgId, from_uid = FromUid} = Message) ->
    ?INFO("FromUid: ~s, MsgId: ~s", [FromUid, MsgId]),
    {ok, SenderAccount} = model_accounts:get_account(FromUid),
    set_sender_info(Message, SenderAccount#account.name, SenderAccount#account.client_version).


-spec set_sender_info(Message :: pb_msg(), Name :: binary(), ClientVersion :: binary()) -> message().
set_sender_info(#pb_msg{payload = #pb_chat_stanza{} = Chat} = Message, Name, ClientVersion) ->
    Chat1 = Chat#pb_chat_stanza{sender_name = Name, sender_client_version = ClientVersion},
    Message#pb_msg{payload = Chat1};

set_sender_info(#pb_msg{payload = #pb_silent_chat_stanza{chat_stanza = Chat}} = Message, Name, ClientVersion) ->
    Chat1 = Chat#pb_chat_stanza{sender_name = Name, sender_client_version = ClientVersion},
    Message#pb_msg{payload = #pb_silent_chat_stanza{chat_stanza = Chat1}};

set_sender_info(#pb_msg{} = Message, _Name, _ClientVersion) ->
    ?ERROR("Invalid message to set sender info: ~p", [Message]),
    Message.

