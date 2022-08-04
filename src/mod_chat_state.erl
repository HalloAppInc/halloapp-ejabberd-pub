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
-include("packets.hrl").
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
    process_group_chat_state/2,
    user_receive_packet/1
]).

start(Host, _Opts) ->
    ejabberd_hooks:add(user_send_chatstate, Host, ?MODULE, user_send_chatstate, 50),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_send_chatstate, Host, ?MODULE, user_send_chatstate, 50),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
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

user_send_chatstate(State, #pb_chat_state{thread_id = <<>>}) ->
    ?ERROR("Thread id is empty.", []),
    State;

user_send_chatstate(State, #pb_chat_state{thread_id = ThreadId, thread_type = ThreadType} = Packet) ->
    Type = Packet#pb_chat_state.type,
    FromUid = Packet#pb_chat_state.from_uid,
    stat:count("HA/chat_state", atom_to_list(Type), 1, [{thread_type, ThreadType}]),
    ?INFO("Uid: ~s, thread_id: ~s, thread_type: ~s, type: ~s",
        [FromUid, ThreadId, ThreadType, Type]),
    case ThreadType of
        chat ->
            process_chat_state(Packet, ThreadId);
        group_chat ->
            process_group_chat_state(Packet, ThreadId)
    end,
    State.


%% ChatState stanzas are sent only on active connections when the client has available-presence.
%% Else, we drop the packet.
user_receive_packet({#pb_chat_state{} = Packet, #{mode := Mode} = State} = Acc) ->
    case Mode of
        active ->
            %% Passive sessions will not have presence info in the c2s state.
            PresenceType = maps:get(presence, State, undefined),
            case PresenceType of
                available -> Acc;
                _ ->
                    ?INFO("drop packet: ~p on presence_type: ~p", [Packet, PresenceType]),
                    {stop, {drop, State}}
            end;
        passive ->
            ?INFO("drop packet: ~p on mode: ~p", [Packet, Mode]),
            {stop, {drop, State}}
    end;
user_receive_packet(Acc) ->
    Acc.


%%====================================================================
%% internal functions
%%====================================================================


%% Server will send user's chat_state to corresponding recipient in 1-to-1 message
-spec process_chat_state(Packet :: chat_state(), ThreadId :: binary()) -> ok.
process_chat_state(Packet, ThreadId) ->
    FromUid = Packet#pb_chat_state.from_uid,
    NewPacket = Packet#pb_chat_state{to_uid = ThreadId, thread_id = FromUid},
    ?INFO("Uid: ~s, to_uid: ~s, type: ~s, newpacket: ~p",
            [FromUid, ThreadId, Packet#pb_chat_state.type, NewPacket]),
    ejabberd_router:route(NewPacket),
    ok.


%% Server will broadcast user's chat_state to all group member who are online
%% TODO: call send packet function from mod_groups once the function is ready
-spec process_group_chat_state(Packet :: chat_state(), ThreadId :: binary()) -> ok.
process_group_chat_state(Packet, ThreadId) ->
    FromUid = Packet#pb_chat_state.from_uid,
    case mod_groups:get_group(ThreadId, FromUid) of
        {ok, Group} ->
            MUids = lists:map(
                    fun(GroupMember) ->
                        GroupMember#group_member.uid
                    end, Group#group.members),
            ReceiverUids = lists:delete(FromUid, MUids),
            ?INFO("Uid: ~s, broadcast uids: ~p, type: ~s",
                    [FromUid, ReceiverUids, Packet#pb_chat_state.type]),
            mod_groups:broadcast_packet(FromUid, ReceiverUids, Packet);
        {error, not_member} ->
            ?WARNING("invalid chat_state stanza, Uid: ~s, Gid: ~p", [FromUid, ThreadId])
    end,
    ok.


