%%%-------------------------------------------------------------------
%%% File    : mod_ack.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the ack-stanza related code. 
%%% - user_send_packet hook is invoked for every packet received from the user.
%%%   We check if this packet need an ack stanza and if yes, we send an immediately to the user.
%%%   If this is an ack stanza itself:
%%%   then acknowledge the ack stanza and drop the corresponding message.
%%% - user_receive_packet hook is invoked on every packet we send from the server to the user.
%%%   We check if this packet needs an ack. If it needs an ack:
%%%   then, we add it to the ack_wait_queue and retry sending after a few seconds.
%%%   A packet could be dropped without acks if we either hit our wait timeout
%%%   (max number of retries) or if there are too many pending packets waiting for ack.
%%%   Retry logic is currently based on a fibonacci series starting with 0, 10 seconds.
%%%   We currently retry until the wait time is about 300 seconds (5min): so about ~8 times.
%%% - c2s_handle_info hook is invoked for every message for this module
%%%   This is used to receive messages from the retry timers for corresponding messages.
%%%    We retry sending these messages. we also update the wait time and the ack_wait_queue.
%%% - Currently, we only send and receive acks for only stanzas of type #message{}.
%%%   We make sure that messages have a corresponding-id attribute:
%%%   if not, we create a uuid and use it.
%%% TODO(murali@): Instead of dropping the stanza: maybe store the packet in offline_messages?
%%%-------------------------------------------------------------------
-module(mod_ack).
-behaviour(gen_mod).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_opt_type/1, mod_options/1]).
%% hooks
-export([user_receive_packet/1, user_send_packet/1, c2s_handle_info/2]).

-include("xmpp.hrl").
-include("logger.hrl").
-include("translate.hrl").

-define(INITIAL_RETRY_INTERVAL_SEC, 10).

-define(needs_ack_packet(Pkt),
        is_record(Pkt, message)).
-define(is_ack_packet(Pkt),
        is_record(Pkt, ack)).

-type state() :: ejabberd_c2s:state().
-type queue() :: erlang:queue({binary(), erlang:timestamp(), xmpp_element() | xmlel()}).

%%%===================================================================
%%% API
%%%===================================================================

start(Host, _Opts) ->
    ejabberd_hooks:add(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 50),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 10),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 10).

stop(Host) ->
    ejabberd_hooks:delete(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 50),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, handle_received_packet, 10),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 10).

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

%%%===================================================================
%%% Hooks
%%%===================================================================

%% When the server receives a packet from the server, we immediately check if the packet needs 
%% an ack and then send it to the client. Currently, we only send acks to messages.
%% When the server receives an ack packet, we remove that packet from our ack_wait_queue,
%% which contains a list of packets waiting for an ack.
user_send_packet({Packet, State0} = _Acc) ->
    ?DEBUG("User just sent a packet to the server: ~p", [Packet]),
    State1 = create_ack_wait_queue_if_unavailable(State0),
    IsStanza = xmpp:is_stanza(Packet),
    send_ack_if_necessary(IsStanza, ?needs_ack_packet(Packet), Packet, State1),
    NewState = check_and_accept_ack_packet(?is_ack_packet(Packet), Packet, State1),
    {Packet, NewState}.



%% When the server tries to send a packet to the client, we store a copy of the packet, its id
%% and timestamp in the ack_wait_queue. The packet will be removed from here
%% when we receive an ack for this packet with the same id.
user_receive_packet({Packet, #{ack_wait_queue := AckWaitQueue} = State} = _Acc) ->
    NewPacket = create_packet_id_if_unavailable(xmpp:get_id(Packet), Packet),
    ?DEBUG("Server is sending a packet to the user: ~p", [NewPacket]),
    State0 = create_ack_wait_queue_if_unavailable(State),
    Id = xmpp:get_id(NewPacket),
    IsMember = is_member(Id, AckWaitQueue),
    NewState = check_and_add_packet_to_ack_wait_queue(?needs_ack_packet(NewPacket), IsMember,
                                                        NewPacket, State0),
    check_if_member_and_restart_timer(?needs_ack_packet(NewPacket), IsMember, NewPacket, NewState),
    {NewPacket, NewState}.



c2s_handle_info(#{ack_wait_queue := AckWaitQueue} = State,
                {retry_sending_packet, {PrevWaitTimeSec0, PrevWaitTimeSec1}, Id}) ->
    ?DEBUG("Received a retry_sending_packet message for a packet with id: ~p", [Id]),
    IsMember = is_member(Id, AckWaitQueue),
    NewState = retry_sending_packet(IsMember, Id, State,
                                    PrevWaitTimeSec0, PrevWaitTimeSec1),
    NewState;
c2s_handle_info(State, _) ->
    State.



%%%===================================================================
%%% Internal functions
%%%===================================================================

retry_sending_packet(true, Id, #{ack_wait_queue := AckWaitQueue, lserver := LServer} = State,
                            PrevWaitTimeSec0, PrevWaitTimeSec1) ->
    {_Id, _Timestamp, Packet} = lookup_member(Id, AckWaitQueue),
    ?DEBUG("Resending this packet: ~p since we haven't received an ack yet.", [Packet]),
    ejabberd_router:route(Packet),
    CleanAckWaitQueue = lazy_clean_up_ack_wait_queue(AckWaitQueue, LServer, lenient),
    check_and_restart_timer(Packet, State, PrevWaitTimeSec0, PrevWaitTimeSec1),
    State#{ack_wait_queue => CleanAckWaitQueue};
retry_sending_packet(_, Id, State, _, _) ->
    ?DEBUG("Ignoring this packet id : ~p since we probably dropped it.", [Id]),
    State.



%% When the server receives an ack packet for a specific packet id, we remove that id from 
%% the list of packets waiting for an ack.
-spec check_and_accept_ack_packet(boolean(), stanza(), state()) -> state().
check_and_accept_ack_packet(true, #ack{id = AckId} = Ack,
                            #{ack_wait_queue := AckWaitQueue} = State) ->
    ?DEBUG("Accepting this ack packet: ~p, ~n AckWaitQueue: ~p", [Ack, AckWaitQueue]),
    NewAckWaitQueue = queue:filter(fun({Id, _Then, _P}) ->
                                        AckId =/= Id
                                        end, AckWaitQueue),
    State#{ack_wait_queue => NewAckWaitQueue};
check_and_accept_ack_packet(_, _Packet, State) ->
    State.



%% Checks if the packet already exists in the ack_wait_queue and adds it if it does not exist yet.
%% Add the packet to the ack_wait_queue.
-spec check_and_add_packet_to_ack_wait_queue(boolean(), boolean(), stanza(), state()) -> state().
check_and_add_packet_to_ack_wait_queue(true, false, Packet, State) ->
    Timestamp = util:convert_timestamp_secs_to_integer(erlang:timestamp()),
    add_packet_to_ack_wait_queue(Packet, Timestamp, State);
check_and_add_packet_to_ack_wait_queue(_, _, _Packet, State) ->
    State.



%% TODO(murali@): Write ack_wait_queue to file if necessary maybe??
%% Adds the packet to the ack_wait_queue.
-spec add_packet_to_ack_wait_queue(stanza(), integer(), state()) -> state().
add_packet_to_ack_wait_queue(Packet, Timestamp,
                            #{ack_wait_queue := AckWaitQueue, lserver := LServer} = State) ->
    ?DEBUG("Adding the packet to the ack_wait_queue, packet: ~p", [Packet]),
    Id = xmpp:get_id(Packet),
    CleanAckWaitQueue = lazy_clean_up_ack_wait_queue(AckWaitQueue, LServer, strict),
    NewAckWaitQueue = queue:in({Id, Timestamp, Packet}, CleanAckWaitQueue),
    State#{ack_wait_queue => NewAckWaitQueue};
add_packet_to_ack_wait_queue(Packet, _, State) ->
    ?ERROR_MSG("Invalid input: packet received here: ~p, state: ~p", [Packet, State]),
    State.



%% Checks if the packet is member or not based on the first argument and then restarts timer.
-spec check_if_member_and_restart_timer(boolean(), boolean(), stanza(), state()) -> ok.
check_if_member_and_restart_timer(true, false, Packet, State) ->
    check_and_restart_timer(Packet, State, 0, ?INITIAL_RETRY_INTERVAL_SEC);
check_if_member_and_restart_timer(_, _, _, _) ->
    ok.



%% Checks the NewWaitTime of the packet and restarts timer if necessary.
%% We use a fibonacci sequence for the wait time sequence starting with 0, 10sec.
-spec check_and_restart_timer(stanza(), state(), integer(), integer()) -> ok.
check_and_restart_timer(Packet, #{lserver := LServer} = _State,
                        PrevWaitTimeSec0, PrevWaitTimeSec1) ->
    Id = xmpp:get_id(Packet),
    NewWaitTimeSec = PrevWaitTimeSec0 + PrevWaitTimeSec1,
    WaitTimeout = NewWaitTimeSec > get_packet_timeout_sec(LServer),
    restart_timer(WaitTimeout, Id, PrevWaitTimeSec1, NewWaitTimeSec).



%% Restart the timer if the packet time lapse did not hit the timeout.
%% We use a fibonacci sequence for the wait time sequence starting with 0, 10sec.
-spec restart_timer(boolean(), binary(), integer(), integer()) -> ok.
restart_timer(false, Id, PrevWaitTimeSec, NewWaitTimeSec) ->
    ?DEBUG("Restarting timer here for packet id: ~p, NewWaitTimeSec: ~p", [Id, NewWaitTimeSec]),
    erlang:send_after(NewWaitTimeSec * 1000, self(),
                        {retry_sending_packet, {PrevWaitTimeSec, NewWaitTimeSec}, Id}),
    ok;
restart_timer(true, _, _, _) ->
    ok.



%% Send an ack packet if necessary.
-spec send_ack_if_necessary(boolean(), boolean(), stanza(), state()) -> ok.
send_ack_if_necessary(true, true, Packet, State) ->
    send_ack(Packet, State);
send_ack_if_necessary(_, _, Packet, _) ->
    ?DEBUG("Ignoring this packet and not sending an ack: ~p", [Packet]),
    ok.



%% Sends an ack packet.
-spec send_ack(stanza(), state()) -> ok.
send_ack(Packet, #{lserver := LServer} = _State) ->
    Id = xmpp:get_id(Packet),
    From = xmpp:get_from(Packet),
    AckPacket = #ack{id = Id, to = From, from = jid:make(LServer)},
    ?DEBUG("Sending an ack to the user with this packet: ~p ~n for this packet: ~p",
                                                                    [AckPacket, Packet]),
    ejabberd_router:route(AckPacket),
    ok;
send_ack(Packet, _State) ->
    ?DEBUG("Ignoring this packet and not sending an ack: ~p", [Packet]),
    ok.



%% Lazy clean up of the ack_wait_queue. Clean up only when we hit the max_ack_wait_items limit.
-spec lazy_clean_up_ack_wait_queue(queue(), binary(), atom()) -> queue().
lazy_clean_up_ack_wait_queue(AckWaitQueue, Host, CompareAtom) ->
    case compare(queue:len(AckWaitQueue), get_max_ack_wait_items(Host), CompareAtom) of
        true ->
            clean_up_ack_wait_queue(AckWaitQueue, Host, CompareAtom);
        false ->
            AckWaitQueue
    end.



%% Cleans up the ack_wait_queue by going through all the packets and dropping packets that are old
%% and we drop one packet if we still hit the limit of the max_items in the ack_wait_queue.
-spec clean_up_ack_wait_queue(queue(), binary(), atom()) -> queue().
clean_up_ack_wait_queue(AckWaitQueue, Host, CompareAtom) ->
    Cur = util:convert_timestamp_secs_to_integer(erlang:timestamp()),
    NewQueue = queue:filter(fun({_Id, Then, _P}) ->
                                    Cur - Then < get_packet_timeout_sec(Host)
                                  end, AckWaitQueue),
    case compare(queue:len(NewQueue), get_max_ack_wait_items(Host), CompareAtom) of
        true ->
            queue:drop(NewQueue);
        false ->
            NewQueue
    end.



%% Compares if AckWaitQueueLength is greater than MaxAckWaitItems or not when the atom is lenient
%% strict refers to whether it is greater than or equal to.
%% The atoms strict or lenient refer to:
%% how forcefully we apply the rule of AckWaitQueueLength to be equal to the MaxAckWaitItems.
-spec compare(integer(), integer(), atom()) -> boolean().
compare(AckWaitQueueLength, MaxAckWaitItems, lenient) ->
    AckWaitQueueLength > MaxAckWaitItems;
compare(AckWaitQueueLength, MaxAckWaitItems, strict) ->
    AckWaitQueueLength >= MaxAckWaitItems.



%% Create an ack_wait_queue if it is unavailable to hold all the packets waiting for an ack.
-spec create_ack_wait_queue_if_unavailable(state()) -> state().
create_ack_wait_queue_if_unavailable(#{ack_wait_queue := _AckWaitQueue} = State) ->
    State;
create_ack_wait_queue_if_unavailable(State) ->
    AckWaitQueue = queue:new(),
    State#{ack_wait_queue => AckWaitQueue}.



%% Create a packet id for the stanza if it is empty.
%% Since, some server generated messages go without id, we add an id ourselves.
%% id here is an uuid generated using erlang-uuid repo (this is already added as a deps).
-spec create_packet_id_if_unavailable(binary(), stanza()) -> stanza().
create_packet_id_if_unavailable(<<>>, Packet) ->
    Id = list_to_binary(uuid:to_string(uuid:uuid4())),
    xmpp:set_id(Packet, Id);
create_packet_id_if_unavailable(_Id, Packet) ->
    Packet.


%% Utility function to check if an item is a member in the queue based on the id.
is_member(AckId, Queue) ->
    AckList = queue:to_list(Queue),
    case lists:keyfind(AckId, 1, AckList) of
           false -> false;
           _ -> true
    end.


%% Utility function to lookup the items in the queue based on the id.
lookup_member(AckId, Queue) ->
    AckList = queue:to_list(Queue),
    case lists:keyfind(AckId, 1, AckList) of
            false -> {};
            Item -> Item
    end.


%%%===================================================================
%%% Configuration processing
%%%===================================================================

get_max_ack_wait_items(Host) ->
    mod_ack_opt:max_ack_wait_items(Host).

get_packet_timeout_sec(Host) ->
    mod_ack_opt:packet_timeout_sec(Host).

mod_opt_type(max_ack_wait_items) ->
    econf:pos_int(infinity);
mod_opt_type(packet_timeout_sec) ->
    econf:pos_int(infinity).

mod_options(_Host) ->
    [{max_ack_wait_items, 5000},            %% max number of packets waiting for ack.
     {packet_timeout_sec, 300}].            %% 8 retries and we then drop the packet.



