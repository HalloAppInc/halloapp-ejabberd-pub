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
%%%   then, we add it to the ack_wait_queue and wait for packet_timeout_sec defined in the config.
%%%   A packet will be sent to offline_msg if we either hit our wait timeout
%%%   (max number of retries) or if there are too many pending packets waiting for ack.
%%%   If the user goes offline for some reason: when we send a packet: then we remove the packet
%%%   from the queue, since the server will attempt to send it using mod_offline
%%%   using the offline_message_hook.
%%% - Currently, we only send and receive acks for only stanzas of type #message{}.
%%%   We make sure that messages have a corresponding-id attribute:
%%%   if not, we create a uuid and use it.
%%%-------------------------------------------------------------------
-module(mod_ack).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_opt_type/1, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).
%% hooks
-export([user_receive_packet/1, user_send_packet/1, offline_message_hook/1, c2s_closed/2]).

-include("xmpp.hrl").
-include("logger.hrl").
-include("translate.hrl").

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
    ?DEBUG("start", []),
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    ?DEBUG("stop", []),
    gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    ?DEBUG("init", []),
    process_flag(trap_exit, true),
    Opts = gen_mod:get_module_opts(Host, ?MODULE),
    store_options(Opts),
    %% Run these hooks on the packet at the end.
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 100),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message_hook, 50),
    ejabberd_hooks:add(c2s_closed, Host, ?MODULE, c2s_closed, 10),
    {ok, #{ack_wait_queue => queue:new(),
            host => Host}}.

terminate(_Reason, #{host := Host} = _AckState) ->
    ?DEBUG("terminate", []),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 100),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message_hook, 50),
    ejabberd_hooks:delete(c2s_closed, Host, ?MODULE, c2s_closed, 10),
    ok.

code_change(_OldVsn, AckState, _Extra) ->
    ?DEBUG("mod_ack: code_change", []),
    {ok, AckState}.

%%%===================================================================
%%% Hooks
%%%===================================================================

%% Hook called when the server receives a packet and invoke the gen_server callback.
user_send_packet({_Packet, #{lserver := ServerHost} = _State} = Acc) ->
    ?DEBUG(" ", []),
    gen_server:call(gen_mod:get_module_proc(ServerHost, ?MODULE), {user_send_packet, Acc}).

%% Hook called when the server sends a packet and invoke the gen_server callback.
user_receive_packet({_Packet, #{lserver := ServerHost} = _State} = Acc) ->
    ?DEBUG(" ", []),
    gen_server:call(gen_mod:get_module_proc(ServerHost, ?MODULE), {user_receive_packet, Acc}).

%% Hook called when the server tries sending a message to the user who is offline.
%% This is useful, since we can now remove it from our queue:
%% as it will be a part of the offline_message store.
offline_message_hook({_, #message{to = #jid{luser = _, lserver = ServerHost}} = Message} = Acc) ->
    ?DEBUG("offline_message_hook", []),
    gen_server:cast(gen_mod:get_module_proc(ServerHost, ?MODULE), {offline_message_hook, Message}),
    Acc.

%% Hook called when the connection to that particular user is closed.
%% We now ensure that all packets in our ack_wait_queue to that client
%% are sent to offline_msg immediately.
c2s_closed(#{user := User, server := Server, lserver := ServerHost} = State, _Reason) ->
    To = jid:make(User, Server),
    gen_server:cast(gen_mod:get_module_proc(ServerHost, ?MODULE), {c2s_closed, To}),
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%    gen_server:call    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% When the server receives a packet from the server, we immediately check if the packet needs 
%% an ack and then send it to the client. Currently, we only send acks to messages.
%% When the server receives an ack packet, we remove that packet from our ack_wait_queue,
%% which contains a list of packets waiting for an ack.
handle_call({user_send_packet, {Packet, State} = _Acc}, _From, AckState) ->
    ?DEBUG("User just sent a packet to the server: ~p", [Packet]),
    IsStanza = xmpp:is_stanza(Packet),
    send_ack_if_necessary(IsStanza, ?needs_ack_packet(Packet), Packet, AckState),
    NewAckState = check_and_accept_ack_packet(?is_ack_packet(Packet), Packet, AckState),
    {reply, {Packet, State}, NewAckState};
%% When the server tries to send a packet to the client, we store a copy of the packet, its id
%% and timestamp in the ack_wait_queue. The packet will be removed from here
%% when we receive an ack for this packet with the same id.
handle_call({user_receive_packet,{Packet, State} = _Acc}, _From,
                                                #{ack_wait_queue := AckWaitQueue} = AckState) ->
    NewPacket = adjust_packet_id_and_retry_count(Packet),
    ?DEBUG("Server is sending a packet to the user: ~p", [NewPacket]),
    Id = xmpp:get_id(NewPacket),
    To = jid:remove_resource(xmpp:get_to(NewPacket)),
    IsMember = is_member(Id, To, AckWaitQueue),
    TimestampSec = util:timestamp_secs_to_integer(erlang:timestamp()),
    NewAckState = check_and_add_packet_to_ack_wait_queue(?needs_ack_packet(NewPacket), IsMember,
                                                            TimestampSec,
                                                            NewPacket, AckState),
    PacketTimeoutSec = get_packet_timeout_sec(),
    send_packet_with_id_to_offline(?needs_ack_packet(NewPacket), Id, To,
                                    TimestampSec, PacketTimeoutSec),
    {reply, {NewPacket, State}, NewAckState};
%% Handle unknown call requests.
handle_call(Request, _From, AckState) ->
    ?DEBUG("~p", [Request]),
    {reply, {error, bad_arg}, AckState}.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%    gen_server:cast       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_cast({offline_message_hook, Packet}, #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?DEBUG("Check and remove packet: ~p from queue: ~p",
                                                                    [Packet, AckWaitQueue]),
    Id = xmpp:get_id(Packet),
    To = jid:remove_resource(xmpp:get_to(Packet)),
    {_, NewAckWaitQueue} = remove_packet_from_ack_wait_queue(Id, To, AckWaitQueue),
    {noreply, AckState#{ack_wait_queue => NewAckWaitQueue}};
handle_cast({c2s_closed, To}, #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?DEBUG("Check and remove all packet to: ~p from queue: ~p",
                                                                    [To, AckWaitQueue]),
    NewAckWaitQueue = remove_all_packet_with_to_from_ack_wait_queue(To, AckWaitQueue),
    {noreply, AckState#{ack_wait_queue => NewAckWaitQueue}};
handle_cast(Request, AckState) ->
    ?DEBUG("Invalid request received, ignoring it: ~p", [Request]),
    {noreply, AckState}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%    gen_server:info: other messages    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
handle_info({route_offline_message, Packet}, #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?INFO_MSG("Received a route_offline_message message for a packet: ~p", [Packet]),
    Id = xmpp:get_id(Packet),
    To = jid:remove_resource(xmpp:get_to(Packet)),
    {_, NewAckWaitQueue} = remove_packet_from_ack_wait_queue(Id, To, AckWaitQueue),
    route_offline_message(Packet),
    {noreply, AckState#{ack_wait_queue => NewAckWaitQueue}};
handle_info({route_offline_message, Id, To, TimestampSec},
            #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?INFO_MSG("Received a route_offline_message message for a packet with id: ~p to: ~p", [Id, To]),
    case lookup_member(Id, To, AckWaitQueue) of
        {} ->
            ?INFO_MSG("This packet id: ~p to: ~p has already received an ack/sent to offline "
                "already", [Id, To]),
            NewAckWaitQueue = AckWaitQueue;
        {_, _, TimestampSec, Packet} ->
            ?INFO_MSG("This packet id: ~p to: ~p will be sent to offline_msg to retry again later.",
                [Id, To]),
            {_, NewAckWaitQueue} = remove_packet_from_ack_wait_queue(Id, To, AckWaitQueue),
            route_offline_message(Packet);
        _ ->
            ?INFO_MSG("route_offline_message with different timestamp", []),
            NewAckWaitQueue = AckWaitQueue
    end,
    {noreply, AckState#{ack_wait_queue => NewAckWaitQueue}};
%% Handle unknown info requests.
handle_info(Request, AckState) ->
    ?DEBUG("received an unknown request: ~p, ~p", [Request, AckState]),
    {noreply, AckState}.


%%%===================================================================
%%% Internal functions
%%%===================================================================


%% When the server receives an ack packet for a specific packet id, we remove that id from 
%% the list of packets waiting for an ack.
-spec check_and_accept_ack_packet(boolean(), stanza(), state()) -> state().
check_and_accept_ack_packet(true, #ack{id = AckId, from = From} = Ack,
                            #{ack_wait_queue := AckWaitQueue, host := ServerHost} = AckState) ->
    AckTo = jid:remove_resource(From),
    ?INFO_MSG("Accepting this ack packet: ~p", [Ack]),
    {PacketList, NewAckWaitQueue} = remove_packet_from_ack_wait_queue(AckId, AckTo, AckWaitQueue),
    case PacketList of
        [] -> ok;
        [{_, _, _, Packet}] -> ejabberd_hooks:run(user_ack_packet, ServerHost,
                                                            [xmpp:decode_els(Packet)])
    end,
    AckState#{ack_wait_queue => NewAckWaitQueue};
check_and_accept_ack_packet(_, _Packet, AckState) ->
    AckState.


%% Removes a packet based on Id from the ack_wait_queue and returns the resulting queue.
-spec remove_packet_from_ack_wait_queue(binary(), jid(), queue()) ->
                                            {[{binary(), jid(), binary(), stanza()}], queue()}.
remove_packet_from_ack_wait_queue(AckId, AckTo, AckWaitQueue) ->
    AckWaitList = queue:to_list(AckWaitQueue),
    {PacketList, NewAckWaitList} = lists:partition(fun({Id, To, _Then, _P}) ->
                                                        AckId == Id andalso AckTo == To
                                                end, AckWaitList),
    NewAckWaitQueue = queue:from_list(NewAckWaitList),
    {PacketList, NewAckWaitQueue}.

%% Removes a packet based on to from the ack_wait_queue and returns the resulting queue.
-spec remove_all_packet_with_to_from_ack_wait_queue(jid(), queue()) -> queue().
remove_all_packet_with_to_from_ack_wait_queue(AckTo, AckWaitQueue) ->
    NewAckWaitQueue = queue:filter(fun({_Id, To, _Then, Pkt}) ->
                                        Result = (AckTo =/= To),
                                        send_packet_to_offline(Result, Pkt),
                                        Result
                                        end, AckWaitQueue),
    NewAckWaitQueue.



%% Checks if the packet already exists in the ack_wait_queue and adds it if it does not exist yet.
%% Add the packet to the ack_wait_queue.
-spec check_and_add_packet_to_ack_wait_queue(boolean(), boolean(), integer(),
                                                     stanza(), state()) -> state().
check_and_add_packet_to_ack_wait_queue(true, false, TimestampSec, Packet, AckState) ->
    RetryCount = xmpp:get_retry_count(Packet),
    MaxRetryCount = get_max_retry_count(),
    case RetryCount < MaxRetryCount of
        true ->
            add_packet_to_ack_wait_queue(Packet, TimestampSec, AckState);
        false ->
            AckState
    end;
check_and_add_packet_to_ack_wait_queue(_, _, _TimestampSec, _Packet, AckState) ->
    AckState.



%% TODO(murali@): Write ack_wait_queue to file if necessary maybe??
%% Adds the packet to the ack_wait_queue.
-spec add_packet_to_ack_wait_queue(stanza(), integer(), state()) -> state().
add_packet_to_ack_wait_queue(Packet, TimestampSec,
                            #{ack_wait_queue := AckWaitQueue} = AckState) ->
    ?DEBUG("Adding the packet to the ack_wait_queue, packet: ~p", [Packet]),
    Id = xmpp:get_id(Packet),
    To = jid:remove_resource(xmpp:get_to(Packet)),
    CleanAckWaitQueue = clean_up_ack_wait_queue(AckWaitQueue, TimestampSec, strict),
    NewAckWaitQueue = queue:in({Id, To, TimestampSec, Packet}, CleanAckWaitQueue),
    AckState#{ack_wait_queue => NewAckWaitQueue};
add_packet_to_ack_wait_queue(Packet, _, AckState) ->
    ?ERROR_MSG("Invalid input: packet received here: ~p, state: ~p", [Packet, AckState]),
    AckState.



%% Send an ack packet if necessary.
-spec send_ack_if_necessary(boolean(), boolean(), stanza(), state()) -> ok.
send_ack_if_necessary(true, true, Packet, AckState) ->
    send_ack(Packet, AckState);
send_ack_if_necessary(_, _, Packet, _) ->
    ?INFO_MSG("Ignoring this packet and not sending an ack: ~p", [Packet]),
    ok.



%% Sends an ack packet.
-spec send_ack(stanza(), state()) -> ok.
send_ack(Packet, #{host := Host} = _AckState) ->
    Id = xmpp:get_id(Packet),
    From = xmpp:get_from(Packet),
    Timestamp = xmpp:get_timestamp(Packet),
    AckPacket = #ack{id = Id, to = From, from = jid:make(Host), timestamp = Timestamp},
    ?INFO_MSG("Sending an ack to the user with this packet: ~p ~n for this packet: ~p",
                                                                    [AckPacket, Packet]),
    ejabberd_router:route(AckPacket),
    ok;
send_ack(Packet, _AckState) ->
    ?DEBUG("Ignoring this packet and not sending an ack: ~p", [Packet]),
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
    %% send to offline_msg immediately.
    ?DEBUG("mod_ack: will route this packet ~p to offline_msg immediately.", [Pkt]),
    erlang:send(self(), {route_offline_message, Pkt}),
    ok;
send_packet_to_offline(true, _Pkt) ->
    ok.



%% Sends a message to this gen_server process after the timeout mentioned which will then trigger
%% route_offline_message to store the packet in offline_msg to retry sending later.
-spec send_packet_with_id_to_offline(boolean(), binary(), jid(), integer(), integer()) -> ok.
send_packet_with_id_to_offline(true, Id, To, TimestampSec, PacketTimeoutSec) ->
    %% send to offline_msg after PacketTimeoutSec seconds.
    ?DEBUG("will route this packet with id: ~p to: ~p, to offline_msg after ~p sec.",
                                                        [Id, To, PacketTimeoutSec]),
    erlang:send_after(PacketTimeoutSec * 1000, self(),
                        {route_offline_message, Id, To, TimestampSec}),
    ok;
send_packet_with_id_to_offline(false, _, _, _, _) ->
    ok.



%% Routes a message specifically through the offline route using the function from ejabberd_sm.
-spec route_offline_message(message()) -> ok.
route_offline_message(Pkt) ->
    ?DEBUG("routing this packet to offline_msg to retry later: ~p", [Pkt]),
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


%% Adjusts both packet id and retry count for messages.
-spec adjust_packet_id_and_retry_count(stanza()) -> stanza().
adjust_packet_id_and_retry_count(#message{} = Packet) ->
    NewPacket = adjust_packet_id(Packet),
    Count = xmpp:get_retry_count(NewPacket),
    xmpp:set_retry_count(NewPacket, Count + 1);
adjust_packet_id_and_retry_count(Packet) ->
    Packet.


%% Since, some server generated messages go without id, we add an id ourselves.
%% id here is an uuid generated using erlang-uuid repo (this is already added as a deps).
%% We overwrite messages that have pubsub items to have the same id as the item id.
-spec adjust_packet_id(stanza()) -> stanza().
adjust_packet_id(Packet) ->
    NewId = create_packet_id_if_unavailable(xmpp:get_id(Packet)),
    xmpp:set_id(Packet, NewId).


%% Create a packet id for the stanza if it is empty.
-spec create_packet_id_if_unavailable(binary()) -> binary().
create_packet_id_if_unavailable(<<>>) ->
    list_to_binary(uuid:to_string(uuid:uuid4()));
create_packet_id_if_unavailable(Id) ->
    Id.




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
    MaxRetryCount = mod_ack_opt:max_retry_count(Opts),
    PacketTimeoutSec = mod_ack_opt:packet_timeout_sec(Opts),
    %% Store MaxAckWaitItems and PacketTimeoutSec.
    persistent_term:put({?MODULE, max_ack_wait_items}, MaxAckWaitItems),
    persistent_term:put({?MODULE, max_retry_count}, MaxRetryCount),
    persistent_term:put({?MODULE, packet_timeout_sec}, PacketTimeoutSec).

-spec get_max_retry_count() -> 'infinity' | pos_integer().
get_max_retry_count() ->
    persistent_term:get({?MODULE, max_retry_count}).

-spec get_max_ack_wait_items() -> 'infinity' | pos_integer().
get_max_ack_wait_items() ->
    persistent_term:get({?MODULE, max_ack_wait_items}).

-spec get_packet_timeout_sec() -> 'infinity' | pos_integer().
get_packet_timeout_sec() ->
    persistent_term:get({?MODULE, packet_timeout_sec}).

mod_opt_type(max_ack_wait_items) ->
    econf:pos_int(infinity);
mod_opt_type(max_retry_count) ->
    econf:pos_int(infinity);
mod_opt_type(packet_timeout_sec) ->
    econf:pos_int(infinity).

mod_options(_Host) ->
    [{max_ack_wait_items, 5000},            %% max number of packets waiting for ack.
     {max_retry_count, 5},                  %% max number of retries for sending a packet.
     {packet_timeout_sec, 40}].             %% we then send the packet to offline_msg after this.


