%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 07. Aug 2020 2:00 PM
%%%-------------------------------------------------------------------
-module(mod_chat_state).
-author("yexin").

-include("logger.hrl").
-include("xmpp.hrl").

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
    user_send_packet/1,
    process_chat_state/2,
    process_group_chat_state/2
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

user_send_packet({#chat_state{thread_id = <<>>}, _} = Acc) ->
    ?ERROR_MSG("Thread id is empty.", []),
    Acc;

user_send_packet({#chat_state{thread_id = ThreadId, thread_type = ThreadType} = 
        Packet, State} = Acc) ->
    Type = Packet#chat_state.type,
    stat:count_d("HA/chat_state", atom_to_list(Type), [{thread_type, ThreadType}]),
    ?INFO_MSG("thread_id: ~s, thread_type: ~s, type: ~s",
            [ThreadId, ThreadType, Type]),
    case ThreadType of
        chat ->
            process_chat_state(Packet, ThreadId);
        group_chat ->
            process_group_chat_state(Packet, ThreadId)
    end,
    Acc;

user_send_packet({_Packet, _State} = Acc) ->
    Acc.


%%====================================================================
%% internal functions
%%====================================================================


%% Server will send user's chat_state to corresponding recipient in 1-to-1 message
-spec process_chat_state(Packet :: chat_state(), ThreadId :: binary()) -> ok.
process_chat_state(Packet, ThreadId) ->
    Server = util:get_host(),
    NewToJid = jid:make(ThreadId, Server),
    From = Packet#chat_state.from,
    NewPacket = Packet#chat_state{to = NewToJid, thread_id = From#jid.luser},
    ?INFO_MSG("Uid: ~s, to_uid: ~s, type: ~s",
            [From#jid.luser, NewToJid#jid.luser, Packet#chat_state.type]),
    ejabberd_router:route(NewPacket),
    ok.


%% Server will broadcast user's chat_state to all group member who are online
%% TODO: call send packet function from mod_groups once the function is ready
-spec process_group_chat_state(Packet :: chat_state(), ThreadId :: binary()) -> ok.
process_group_chat_state(Packet, ThreadId) ->
    Server = util:get_host(),
    From = Packet#chat_state.from,
    BroadcastUids = model_groups:get_member_uids(ThreadId),
    ?INFO_MSG("Uid: ~s, broadcast uids: ~p, type: ~s",
            [From#jid.luser, BroadcastUids, Packet#chat_state.type]),
    mod_groups:broadcast_packet(From, Server, BroadcastUids, Packet),
    ok.


