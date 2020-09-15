%%%-------------------------------------------------------------------
%%% File    : mod_retract.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-------------------------------------------------------------------

-module(mod_retract).
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
    process_retract_message/1
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(retract_message, Host, ?MODULE, process_retract_message, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(retract_message, Host, ?MODULE, process_retract_message, 50),
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

-spec process_retract_message(Packet :: message()) -> message().
process_retract_message(#message{from = #jid{luser = Uid},
        sub_els = [#retract_st{} = RetractSt]} = Message) ->
    ?INFO_MSG("Uid: ~s, Id: ~p", [Uid, RetractSt#retract_st.id]),
    if
        RetractSt#retract_st.uid =/= <<>> andalso RetractSt#retract_st.uid =/= undefined ->
            send_chat_retract_message(Message);
        RetractSt#retract_st.gid =/= <<>> orelse RetractSt#retract_st.gid =/= undefined ->
            send_group_chat_retract_message(Message);
        true ->
            ?ERROR_MSG("Invalid packet received: ~p", [Message])
    end.


%%====================================================================
%% internal functions
%%====================================================================


%% Server will send the retract message to corresponding recipient in 1-to-1 message
send_chat_retract_message(#message{from = #jid{luser = Uid}, sub_els = [SubEl]} = Message) ->
    Server = util:get_host(),
    ToUid = SubEl#retract_st.uid,
    ToJid = jid:make(ToUid, Server),
    NewSubEl = SubEl#retract_st{uid = Uid},
    NewMessage = Message#message{to = ToJid, sub_els = [NewSubEl]},
    ?INFO_MSG("Uid: ~s, Id: ~s, to_uid: ~s", [Uid, NewSubEl#retract_st.id, ToUid]),
    ejabberd_router:route(NewMessage),
    ok.


%% Server will broadcast retract message to all the other group members.
send_group_chat_retract_message(#message{from = #jid{luser = Uid} = From,
        sub_els = [SubEl]} = Message) ->
    Server = util:get_host(),
    Gid = SubEl#retract_st.gid,
    MUids = model_groups:get_member_uids(Gid),
    ReceiverUids = lists:delete(Uid, MUids),
    NewMessage = Message#message{type = groupchat},
    ?INFO_MSG("Uid: ~s, Id: ~s, Gid: ~s, ReceiverUids: ~p",
            [Uid, SubEl#retract_st.id, Gid, ReceiverUids]),
    mod_groups:broadcast_packet(From, Server, ReceiverUids, NewMessage),
    ok.

