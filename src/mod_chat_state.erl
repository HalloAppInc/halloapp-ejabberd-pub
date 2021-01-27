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
-include("groups.hrl").

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
    user_send_chatstate/2,
    process_chat_state/2,
    process_group_chat_state/2
]).

start(Host, _Opts) ->
    ejabberd_hooks:add(user_send_chatstate, Host, ?MODULE, user_send_chatstate, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_send_chatstate, Host, ?MODULE, user_send_chatstate, 50),
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

user_send_chatstate(State, #chat_state{thread_id = <<>>}) ->
    ?ERROR("Thread id is empty.", []),
    State;

user_send_chatstate(State, #chat_state{thread_id = ThreadId, thread_type = ThreadType} = Packet) ->
    Type = Packet#chat_state.type,
    stat:count("HA/chat_state", atom_to_list(Type), 1, [{thread_type, ThreadType}]),
    ?INFO("thread_id: ~s, thread_type: ~s, type: ~s",
            [ThreadId, ThreadType, Type]),
    case ThreadType of
        chat ->
            process_chat_state(Packet, ThreadId);
        group_chat ->
            process_group_chat_state(Packet, ThreadId)
    end,
    State.


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
    ?INFO("Uid: ~s, to_uid: ~s, type: ~s",
            [From#jid.luser, NewToJid#jid.luser, Packet#chat_state.type]),
    ejabberd_router:route(NewPacket),
    ok.


%% Server will broadcast user's chat_state to all group member who are online
%% TODO: call send packet function from mod_groups once the function is ready
-spec process_group_chat_state(Packet :: chat_state(), ThreadId :: binary()) -> ok.
process_group_chat_state(Packet, ThreadId) ->
    Server = util:get_host(),
    From = Packet#chat_state.from,
    FromUid = From#jid.luser,
    case mod_groups:get_group(ThreadId, FromUid) of
        {ok, Group} ->
            MUids = lists:map(
                    fun(GroupMember) ->
                        GroupMember#group_member.uid
                    end, Group#group.members),
            ReceiverUids = lists:delete(FromUid, MUids),
            ?INFO("Uid: ~s, broadcast uids: ~p, type: ~s",
                    [FromUid, ReceiverUids, Packet#chat_state.type]),
            mod_groups:broadcast_packet(From, Server, ReceiverUids, Packet);
        {error, not_member} ->
            ?WARNING("invalid chat_state stanza, Uid: ~s, Gid: ~p", [FromUid, ThreadId])
    end,
    ok.


