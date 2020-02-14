%%%-------------------------------------------------------------------
%%% File    : mod_ack.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%  This module is created as a gen_server process attached with ejabberd_gen_mod_sup
%%   as its supervisor. For each of the hooks described below:
%%%  the main logic is in the gen_server callbacks.
%%%  AckState throughout the code refers to the state of this module.
%%%
%%%  This module handles all the ack-stanza related code.
%%% - user_send_packet hook is invoked for every packet received from the user.
%%%   We check if this packet need an ack stanza and if yes, we send an immediately to the user.
%%%   If this is an ack stanza itself:
%%%   then acknowledge the ack stanza and drop the corresponding message.
%%% - user_receive_packet hook is invoked on every packet we send from the server to the user.
%%%   We check if this packet needs an ack. If it needs an ack:
%%%   then, we add it to the ack_wait_queue and retry sending after a few seconds.
%%%   A packet will be sent to offline_msg if we either hit our wait timeout
%%%   (max number of retries) or if there are too many pending packets waiting for ack.
%%%   Retry logic is currently based on a fibonacci series starting with 0, 10 seconds.
%%%   We currently retry until the wait time is about 300 seconds (5min): so about ~8 times.
%%%   If the user goes offline for some reason: during retry: then we remove the packet
%%    from the queue, since the server will attempt to send it using mod_offline.
%%% - c2s_handle_info hook is invoked for every message for this module
%%%   This is used to receive messages from the retry timers for corresponding messages.
%%%    We retry sending these messages. we also update the wait time and the ack_wait_queue.
%%% - Currently, we only send and receive acks for only stanzas of type #message{}.
%%%   We make sure that messages have a corresponding-id attribute:
%%%   if not, we create a uuid and use it.
%%%-------------------------------------------------------------------
-module(mod_ack).
-behaviour(gen_mod).
-behaviour(gen_server).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_opt_type/1, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).
%% hooks
-export([user_receive_packet/1, user_send_packet/1, offline_message_hook/1]).

-include("xmpp.hrl").
-include("logger.hrl").
-include("translate.hrl").

-define(INITIAL_RETRY_INTERVAL_SEC, 10).
-define(WAIT_TO_ROUTE_OFFLINE_MSG_SEC, 5).
-define(needs_ack_packet(Pkt),
        is_record(Pkt, message)).
-define(is_ack_packet(Pkt),
        is_record(Pkt, ack)).

-type queue() :: erlang:queue({binary(), jid(), integer(), xmpp_element() | xmlel()}).
-type state() :: #{ack_wait_queue => queue(),
                   host => binary()}.

%%%===================================================================
%%% gen_mod API
%%%===================================================================

start(Host, Opts) ->
    ?DEBUG("mod_ack: start", []),
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    ?DEBUG("mod_ack: stop", []),
    gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    ?DEBUG("mod_ack: init", []),
    process_flag(trap_exit, true),
    Opts = gen_mod:get_module_opts(Host, ?MODULE),
    store_options(Opts),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 10),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 10),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message_hook, 50),
    {ok, #{ack_wait_queue => queue:new(),
            host => Host}}.

terminate(_Reason, #{host := Host} = _AckState) ->
    ?DEBUG("mod_ack: terminate", []),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 10),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 10),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message_hook, 50),
    ok.

code_change(_OldVsn, AckState, _Extra) ->
    ?DEBUG("mod_ack: code_change", []),
    {ok, AckState}.

%%%===================================================================
%%% Hooks
%%%===================================================================

%% Hook called when the server receives a packet and invoke the gen_server callback.
user_send_packet({_Packet, #{lserver := ServerHost} = _State} = Acc) ->
    ?DEBUG("mod_ack: user_send_packet", []),
    gen_server:call(gen_mod:get_module_proc(ServerHost, ?MODULE), {user_send_packet, Acc}).

%% Hook called when the server sends a packet and invoke the gen_server callback.
user_receive_packet({_Packet, #{lserver := ServerHost} = _State} = Acc) ->
    ?DEBUG("mod_ack: user_receive_packet", []),
    gen_server:call(gen_mod:get_module_proc(ServerHost, ?MODULE), {user_receive_packet, Acc}).

%% Hook called when the server tries sending a message to the user who is offline.
%% This is useful, since it could be trigerred by this module when retrying sending something.
%% So, we can now remove it from our queue: since it is part of the offline_message store.
offline_message_hook({_, #message{to = #jid{luser = _, lserver = ServerHost}} = Message} = Acc) ->
    ?DEBUG("mod_ack: offline_message_hook", []),
    gen_server:cast(gen_mod:get_module_proc(ServerHost, ?MODULE), {offline_message_hook, Message}),
    Acc.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%    gen_server:call    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% When the server receives a packet from the server, we immediately check if the packet needs 
%% an ack and then send it to the client. Currently, we only send acks to messages.
%% When the server receives an ack packet, we remove that packet from our ack_wait_queue,
%% which contains a list of packets waiting for an ack.
handle_call({user_send_packet, {Packet, State} = _Acc}, _From, AckState) ->
    ?DEBUG("mod_ack: handle_call: User just sent a packet to the server: ~p", [Packet]),
    IsStanza = xmpp:is_stanza(Packet),
    send_ack_if_necessary(IsStanza, ?needs_ack_packet(Packet), Packet, AckState),
    NewAckState = check_and_accept_ack_packet(?is_ack_packet(Packet), Packet, AckState),
    {reply, {Packet, State}, NewAckState};
%% When the server tries to send a packet to the client, we store a copy of the packet, its id
%% and timestamp in the ack_wait_queue. The packet will be removed from here
%% when we receive an ack for this packet with the same id.
handle_call({user_receive_packet,{Packet, State} = _Acc}, _From,
                                                #{ack_wait_queue := AckWaitQueue} = AckState) ->
    NewPacket = create_packet_id_if_unavailable(xmpp:get_id(Packet), Packet),
    ?DEBUG("mod_ack: handle_call: Server is sending a packet to the user: ~p", [NewPacket]),
    Id = xmpp:get_id(NewPacket),
    To = jid:remove_resource(xmpp:get_to(NewPacket)),
    IsMember = is_member(Id, To, AckWaitQueue),
    TimestampSec = util:convert_timestamp_secs_to_integer(erlang:timestamp()),
    NewAckState = check_and_add_packet_to_ack_wait_queue(?needs_ack_packet(NewPacket), IsMember,
                                                            TimestampSec,
                                                            NewPacket, AckState),
    check_if_member_and_restart_timer(?needs_ack_packet(NewPacket), IsMember,
                                        NewPacket, NewAckState),
    {reply, {NewPacket, State}, NewAckState};
%% Handle unknown call requests.
handle_call(Request, _From, AckState) ->
    ?DEBUG("mod_ack: handle_call: ~p", [Request]),
    {reply, {error, bad_arg}, AckState}.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%    gen_server:cast       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_cast({offline_message_hook, Packet}, #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?DEBUG("mod_ack: handle_cast: Check and remove packet: ~p from queue: ~p",
                                                                    [Packet, AckWaitQueue]),
    Id = xmpp:get_id(Packet),
    To = jid:remove_resource(xmpp:get_to(Packet)),
    NewAckWaitQueue = remove_packet_from_ack_wait_queue(Id, To, AckWaitQueue),
    {noreply, AckState#{ack_wait_queue => NewAckWaitQueue}};
handle_cast(Request, AckState) ->
    ?DEBUG("mod_ack: handle_cast: Invalid request received, ignoring it: ~p", [Request]),
    {noreply, AckState}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%    gen_server:info: other messages    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% When we receive a retry_sending_packet message, we check if the packet is still
%% available in our queue and retry sending it.
handle_info({retry_sending_packet, {PrevWaitTimeSec0, PrevWaitTimeSec1}, Id, To},
                                                    #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?INFO_MSG("mod_ack: handle_info:
                Received a retry_sending_packet message for a packet with id: ~p to: ~p", [Id, To]),
    IsMember = is_member(Id, To, AckWaitQueue),
    NewAckState = retry_sending_packet(IsMember, Id, To, AckState,
                                        PrevWaitTimeSec0, PrevWaitTimeSec1),
    {noreply, NewAckState};
handle_info({route_offline_message, Packet}, #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?INFO_MSG("mod_ack: handle_info:
                Received a route_offline_message message for a packet: ~p", [Packet]),
    Id = xmpp:get_id(Packet),
    To = jid:remove_resource(xmpp:get_to(Packet)),
    NewAckWaitQueue = remove_packet_from_ack_wait_queue(Id, To, AckWaitQueue),
    route_offline_message(Packet),
    {noreply, AckState#{ack_wait_queue => NewAckWaitQueue}};
handle_info({route_offline_message, Id, To}, #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?INFO_MSG("mod_ack: handle_info:
                Received a route_offline_message message for a packet with id: ~p to: ~p",
                                                                                        [Id, To]),
    {_, _, _, Packet} = lookup_member(Id, To, AckWaitQueue),
    NewAckWaitQueue = remove_packet_from_ack_wait_queue(Id, To, AckWaitQueue),
    route_offline_message(Packet),
    {noreply, AckState#{ack_wait_queue => NewAckWaitQueue}};
%% Handle unknown info requests.
handle_info(Request, AckState) ->
    ?DEBUG("mod_ack: handle_info: received an unknown request: ~p, ~p", [Request, AckState]),
    {noreply, AckState}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Retries sending a packet based on the id and to and updates the AckState accordingly.
-spec retry_sending_packet(boolean(), binary(), jid(), state(), integer(), integer()) -> state().
retry_sending_packet(true, Id, To, #{ack_wait_queue := AckWaitQueue} = AckState,
                            PrevWaitTimeSec0, PrevWaitTimeSec1) ->
    {_Id, _To, _TimestampSec, Packet} = lookup_member(Id, To, AckWaitQueue),
    ?INFO_MSG("mod_ack: Resending this packet: ~p since we haven't received an ack yet.", [Packet]),
    ejabberd_router:route(Packet),
    TimestampSec = util:convert_timestamp_secs_to_integer(erlang:timestamp()),
    CleanAckWaitQueue = clean_up_ack_wait_queue(AckWaitQueue, TimestampSec, lenient),
    check_and_restart_timer(Packet, AckState, PrevWaitTimeSec0, PrevWaitTimeSec1),
    AckState#{ack_wait_queue => CleanAckWaitQueue};
retry_sending_packet(_, Id, To, AckState, _, _) ->
    ?INFO_MSG("mod_ack: Ignoring this packet id : ~p to: ~p
                    since we probably already handled it / sent to offline_msg.", [Id, To]),
    AckState.



%% When the server receives an ack packet for a specific packet id, we remove that id from 
%% the list of packets waiting for an ack.
-spec check_and_accept_ack_packet(boolean(), stanza(), state()) -> state().
check_and_accept_ack_packet(true, #ack{id = AckId, from = From} = Ack,
                            #{ack_wait_queue := AckWaitQueue} = AckState) ->
    AckTo = jid:remove_resource(From),
    ?INFO_MSG("mod_ack: Accepting this ack packet: ~p, ~n AckWaitQueue: ~p", [Ack, AckWaitQueue]),
    NewAckWaitQueue = remove_packet_from_ack_wait_queue(AckId, AckTo, AckWaitQueue),
    AckState#{ack_wait_queue => NewAckWaitQueue};
check_and_accept_ack_packet(_, _Packet, AckState) ->
    AckState.


%% Removes a packet based on Id from the ack_wait_queue and returns the resulting queue.
-spec remove_packet_from_ack_wait_queue(binary(), jid(), queue()) -> queue().
remove_packet_from_ack_wait_queue(AckId, AckTo, AckWaitQueue) ->
    NewAckWaitQueue = queue:filter(fun({Id, To, _Then, _P}) ->
                                        AckId =/= Id orelse AckTo =/= To
                                        end, AckWaitQueue),
    NewAckWaitQueue.



%% Checks if the packet already exists in the ack_wait_queue and adds it if it does not exist yet.
%% Add the packet to the ack_wait_queue.
-spec check_and_add_packet_to_ack_wait_queue(boolean(), boolean(), integer(),
                                                     stanza(), state()) -> state().
check_and_add_packet_to_ack_wait_queue(true, false, TimestampSec, Packet, AckState) ->
    add_packet_to_ack_wait_queue(Packet, TimestampSec, AckState);
check_and_add_packet_to_ack_wait_queue(_, _, _TimestampSec, _Packet, AckState) ->
    AckState.



%% TODO(murali@): Write ack_wait_queue to file if necessary maybe??
%% Adds the packet to the ack_wait_queue.
-spec add_packet_to_ack_wait_queue(stanza(), integer(), state()) -> state().
add_packet_to_ack_wait_queue(Packet, TimestampSec,
                            #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?DEBUG("mod_ack: Adding the packet to the ack_wait_queue, packet: ~p", [Packet]),
    Id = xmpp:get_id(Packet),
    To = jid:remove_resource(xmpp:get_to(Packet)),
    CleanAckWaitQueue = clean_up_ack_wait_queue(AckWaitQueue, TimestampSec, strict),
    NewAckWaitQueue = queue:in({Id, To, TimestampSec, Packet}, CleanAckWaitQueue),
    AckState#{ack_wait_queue => NewAckWaitQueue};
add_packet_to_ack_wait_queue(Packet, _, AckState) ->
    ?ERROR_MSG("mod_ack: Invalid input: packet received here: ~p, state: ~p", [Packet, AckState]),
    AckState.



%% Checks if the packet is member or not based on the first argument and then restarts timer.
-spec check_if_member_and_restart_timer(boolean(), boolean(), stanza(), state()) -> ok.
check_if_member_and_restart_timer(true, false, Packet, AckState) ->
    check_and_restart_timer(Packet, AckState, 0, ?INITIAL_RETRY_INTERVAL_SEC);
check_if_member_and_restart_timer(_, _, _, _) ->
    ok.



%% Checks the NewWaitTime of the packet and restarts timer if necessary.
%% We use a fibonacci sequence for the wait time sequence starting with 0, 10sec.
-spec check_and_restart_timer(stanza(), state(), integer(), integer()) -> ok.
check_and_restart_timer(Packet, _AckState,
                        PrevWaitTimeSec0, PrevWaitTimeSec1) ->
    Id = xmpp:get_id(Packet),
    To = jid:remove_resource(xmpp:get_to(Packet)),
    NewWaitTimeSec = PrevWaitTimeSec0 + PrevWaitTimeSec1,
    WaitTimeout = NewWaitTimeSec > get_packet_timeout_sec(),
    restart_timer(WaitTimeout, Id, To, PrevWaitTimeSec1, NewWaitTimeSec).



%% Restart the timer if the packet time lapse did not hit the timeout.
%% We use a fibonacci sequence for the wait time sequence starting with 0, 10sec.
-spec restart_timer(boolean(), binary(), jid(), integer(), integer()) -> ok.
restart_timer(false, Id, To, PrevWaitTimeSec, NewWaitTimeSec) ->
    ?DEBUG("mod_ack: Restarting timer here for packet id: ~p, to: ~p, NewWaitTimeSec: ~p",
                                                                    [Id, To, NewWaitTimeSec]),
    erlang:send_after(NewWaitTimeSec * 1000, self(),
                        {retry_sending_packet, {PrevWaitTimeSec, NewWaitTimeSec}, Id, To}),
    ok;
restart_timer(true, Id, To, _, _) ->
    send_packet_with_id_to_offline(Id, To),
    ok.



%% Send an ack packet if necessary.
-spec send_ack_if_necessary(boolean(), boolean(), stanza(), state()) -> ok.
send_ack_if_necessary(true, true, Packet, AckState) ->
    send_ack(Packet, AckState);
send_ack_if_necessary(_, _, Packet, _) ->
    ?INFO_MSG("mod_ack: Ignoring this packet and not sending an ack: ~p", [Packet]),
    ok.



%% Sends an ack packet.
-spec send_ack(stanza(), state()) -> ok.
send_ack(Packet, #{host := Host} = _AckState) ->
    Id = xmpp:get_id(Packet),
    From = xmpp:get_from(Packet),
    AckPacket = #ack{id = Id, to = From, from = jid:make(Host)},
    ?INFO_MSG("mod_ack: Sending an ack to the user with this packet: ~p ~n for this packet: ~p",
                                                                    [AckPacket, Packet]),
    ejabberd_router:route(AckPacket),
    ok;
send_ack(Packet, _AckState) ->
    ?DEBUG("mod_ack: Ignoring this packet and not sending an ack: ~p", [Packet]),
    ok.



%% Cleans up the ack_wait_queue by going through all the packets and sends packets that are timed
%% out or very old due to offline_msg if we still hit the limit of items in the ack_wait_queue.
-spec clean_up_ack_wait_queue(queue(), integer(), atom()) -> queue().
clean_up_ack_wait_queue(AckWaitQueue, TimestampSec, CompareAtom) ->
    CurSec = TimestampSec,
    case CompareAtom of
        strict ->
            NewQueue = queue:filter(fun({_Id, _To, ThenSec, Pkt}) ->
                                        Result = CurSec - ThenSec < get_packet_timeout_sec(),
                                        send_packet_to_offline(Result, Pkt),
                                        Result
                                    end, AckWaitQueue);
        lenient ->
            NewQueue = AckWaitQueue
    end,
    case compare(queue:len(NewQueue), get_max_ack_wait_items(), CompareAtom) of
        true ->
            {value, {_, _, _, Pkt}} = queue:peek(NewQueue),
            send_packet_to_offline(false, Pkt),
            queue:drop(NewQueue);
        false ->
            NewQueue
    end.

%% Sends a message to this gen_server process which will then trigger route_offline_message
%% to store the packet in offline_msg to retry sending later.
-spec send_packet_to_offline(boolean(), message()) -> ok.
send_packet_to_offline(false, Pkt) ->
    %% send to offline_msg after WAIT_TO_ROUTE_OFFLINE_MSG_SEC seconds.
    ?DEBUG("mod_ack: will route this packet ~p to offline_msg after ~p sec.",
                                                        [Pkt, ?WAIT_TO_ROUTE_OFFLINE_MSG_SEC]),
    erlang:send_after(?WAIT_TO_ROUTE_OFFLINE_MSG_SEC * 1000, self(),
                        {route_offline_message, Pkt}),
    ok;
send_packet_to_offline(true, _Pkt) ->
    ok.

%% Sends a message to this gen_server process which will then trigger
%% route_offline_message to store the packet in offline_msg to retry sending later.
-spec send_packet_with_id_to_offline(binary(), jid()) -> ok.
send_packet_with_id_to_offline(Id, To) ->
    %% send to offline_msg after WAIT_TO_ROUTE_OFFLINE_MSG_SEC seconds.
    ?DEBUG("mod_ack: will route this packet with id: ~p to: ~p, to offline_msg after ~p sec.",
                                                        [Id, To, ?WAIT_TO_ROUTE_OFFLINE_MSG_SEC]),
    erlang:send_after(?WAIT_TO_ROUTE_OFFLINE_MSG_SEC * 1000, self(),
                        {route_offline_message, Id, To}),
    ok.


%% Routes a message specifically through the offline route using the function from ejabberd_sm.
-spec route_offline_message(message()) -> ok.
route_offline_message(Pkt) ->
    ?DEBUG("mod_ack: routing this packet to offline_msg to retry later: ~p", [Pkt]),
    ejabberd_sm:route_offline_message(Pkt),
    ok.


%% Compares if AckWaitQueueLength is greater than MaxAckWaitItems or not when the atom is lenient
%% strict refers to whether it is greater than or equal to.
%% The atoms strict or lenient refer to:
%% how forcefully we apply the rule of AckWaitQueueLength to be equal to the MaxAckWaitItems.
-spec compare(integer(), integer(), atom()) -> boolean().
compare(AckWaitQueueLength, MaxAckWaitItems, lenient) ->
    AckWaitQueueLength > MaxAckWaitItems;
compare(AckWaitQueueLength, MaxAckWaitItems, strict) ->
    AckWaitQueueLength >= MaxAckWaitItems.



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
-spec is_member(binary(), jid(), queue()) -> boolean().
is_member(AckId, AckTo, Queue) ->
    AckList = queue:to_list(Queue),
    Result = lists:search(fun({Id, To, _Then, _P}) ->
                            AckId == Id andalso AckTo == To
                          end, AckList),
    case Result of
       false -> false;
       _ -> true
    end.


%% Utility function to lookup the items in the queue based on the id.
-spec lookup_member(binary(), jid(), queue()) -> any().
lookup_member(AckId, AckTo, Queue) ->
    AckList = queue:to_list(Queue),
    Result = lists:search(fun({Id, To, _Then, _P}) ->
                            AckId == Id andalso AckTo == To
                          end, AckList),
    case Result of
       false -> {};
       {value, Value} -> Value
    end.


%%%===================================================================
%%% Configuration processing
%%%===================================================================

%% Store the necessary options with persistent_term.
%% [https://erlang.org/doc/man/persistent_term.html]
store_options(Opts) ->
    MaxAckWaitItems = mod_ack_opt:max_ack_wait_items(Opts),
    PacketTimeoutSec = mod_ack_opt:packet_timeout_sec(Opts),
    %% Store MaxAckWaitItems and PacketTimeoutSec.
    persistent_term:put({?MODULE, max_ack_wait_items}, MaxAckWaitItems),
    persistent_term:put({?MODULE, packet_timeout_sec}, PacketTimeoutSec).

-spec get_max_ack_wait_items() -> 'infinity' | pos_integer().
get_max_ack_wait_items() ->
    persistent_term:get({?MODULE, max_ack_wait_items}).

-spec get_packet_timeout_sec() -> 'infinity' | pos_integer().
get_packet_timeout_sec() ->
    persistent_term:get({?MODULE, packet_timeout_sec}).

mod_opt_type(max_ack_wait_items) ->
    econf:pos_int(infinity);
mod_opt_type(packet_timeout_sec) ->
    econf:pos_int(infinity).

mod_options(_Host) ->
    [{max_ack_wait_items, 5000},            %% max number of packets waiting for ack.
     {packet_timeout_sec, 300}].            %% 8 retries and we then send the packet to offline_msg.



