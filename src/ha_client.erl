%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 04. Sep 2020 5:00 PM
%%%-------------------------------------------------------------------
-module(ha_client).
-author("nikola").

-behavior(gen_server).

-include_lib("stdlib/include/assert.hrl").

-include("logger.hrl").
-include("ha_types.hrl").
-include("packets.hrl").

%% API
-export([
    start_link/0,
    start_link/1,
    stop/1,
    connect_and_login/2,
    connect_and_login/3,
    send/2,
    recv_nb/1,
    recv_all_nb/1,
    recv/1,
    recv/2,
    send_recv/2,
    wait_for/2,
    wait_for_msg/1,
    wait_for_msg/2,
    wait_for_eoq/1,
    login/3,
    send_iq/4,
    send_ack/2
]).

-export([
    init/1,
    terminate/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).


-record(state, {
    socket :: gen_tcp:socket(),
    % Queue of decoded pb messages received
    recv_q :: list(),
    state = auth :: auth | connected,
    recv_buf = <<>> :: binary(),
    options :: options()
}).

-type state() :: #state{}.

-type options() :: #{
    auto_send_acks => boolean(),
    resource => binary(),
    version => binary(),
    _ => _
}.

-define(DEFAUL_UA, <<"HalloApp/Android0.129">>).
-define(DEFAULT_RESOURCE, <<"android">>).

% TODO: handle acks,
% TODO: send acks to server.

start_link() ->
    start_link(#{auto_send_acks => true}).

start_link(Options) ->
    gen_server:start_link(ha_client, [Options], []).


-spec connect_and_login(Uid :: uid(), Password :: binary()) ->
    {ok, Client :: pid()} | {error, Reason :: term()}.
connect_and_login(Uid, Password) ->
    connect_and_login(Uid, Password, #{auto_send_acks => true}).


-spec connect_and_login(Uid :: uid(), Password :: binary(), Options :: options()) ->
        {ok, Client :: pid()} | {error, Reason :: term()}.
connect_and_login(Uid, Password, Options) ->
    {ok, C} = start_link(Options),
    Result = login(C, Uid, Password),
    case Result of
        #pb_auth_result{result = <<"success">>} ->
            {ok, C};
        #pb_auth_result{result = <<"failure">>, reason = Reason} ->
            stop(C),
            {error, binary_to_atom(Reason, utf8)};
        Any ->
            stop(C),
            {error, {unexpected_result, Any}}
    end.


-spec send(Client :: pid(), Message :: iolist() | pb_packet()) ->
        ok | {error, closed | inet:posix()}.
send(Client, Message) ->
    gen_server:call(Client, {send, Message}).


-spec send_ack(Client :: pid(), MsgId :: binary()) -> ok | {error, closed | inet:posix()}.
send_ack(Client, MsgId) ->
    AckPacket = #pb_packet{
        stanza = #pb_ack{
            id = MsgId,
            timestamp = util:now()
        }
    },
    send(Client, AckPacket).


% Get the next received message or undefined if no message is received.
% This API does not block waiting for network messages, it returns undefined.
-spec recv_nb(Client :: pid()) -> maybe(pb_packet()).
recv_nb(Client) ->
    gen_server:call(Client, {recv_nb}).

-spec recv_all_nb(Client :: pid()) -> list().
recv_all_nb(Client) ->
    recv_all_nb(Client, []).

-spec recv_all_nb(Client :: pid(), Messages :: list()) -> list().
recv_all_nb(Client, Messages) ->
    case recv_nb(Client) of
        undefined -> lists:reverse(Messages);
        Packet -> recv_all_nb(Client, [Packet | Messages])
    end.

% Gets the next received message or waits for one. Blocking API.
-spec recv(Client :: pid()) -> pb_packet().
recv(Client) ->
    gen_server:call(Client, {recv}).


% Gets the next received message or waits for one until TimeoutMs.
-spec recv(Client :: pid(), TimeoutMs :: infinity | integer()) -> maybe(pb_packet()).
recv(Client, TimeoutMs) ->
    gen_server:call(Client, {recv, TimeoutMs}).


% Stop the gen_server
-spec stop(Client :: pid()) -> ok.
stop(Client) ->
    gen_server:stop(Client).


% Check the received messages for the first message where Func(Message) returns true.
% If no such message is already received it waits for such message to arrive from the server.
-spec wait_for(Client :: pid(), Func :: fun((term()) -> boolean())) -> pb_packet().
wait_for(Client, MatchFun) ->
    gen_server:call(Client, {wait_for, MatchFun}).


-spec wait_for_msg(Client :: pid()) -> pb_packet().
wait_for_msg(Client) ->
    wait_for(Client,
            fun (P) ->
                case P of
                    #pb_packet{stanza = #pb_msg{}} -> true;
                    _Any -> false
                end
            end).

% wait for message with particular payload
-spec wait_for_msg(Client :: pid(), PayloadTag :: atom()) -> pb_packet().
wait_for_msg(Client, PayloadTag) ->
    wait_for(Client,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{payload = Payload}} -> is_record(Payload, PayloadTag);
                _Any -> false
            end
        end).

-spec wait_for_eoq(Client :: pid()) -> pb_packet().
wait_for_eoq(Client) ->
    wait_for_msg(Client, pb_end_of_queue).

-spec send_recv(Client :: pid(), Packet :: iolist() | pb_packet()) -> pb_packet().
send_recv(Client, Packet) ->
    gen_server:call(Client, {send_recv, Packet}).


% send pb_auth_request message
-spec login(Client :: pid(), Uid :: uid(), Password :: binary()) -> ok.
login(Client, Uid, Password) ->
    gen_server:call(Client, {login, Uid, Password}).

-spec send_iq(Client :: pid(), Id :: any(), Type :: atom(), Payload :: term()) ->
        {ok, pb_iq()} | {error, any()}.
send_iq(Client, Id, Type, Payload) ->
    Packet = #pb_packet{
        stanza = #pb_iq{
            id = Id,
            payload = Payload,
            type = Type
        }
    },
    send(Client, Packet),
    Response = wait_for(Client,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_iq{id = Id}} -> true;
                _Any -> false
            end
        end),
    Response.



init([Options] = _Args) ->
    {ok, Socket} = ssl:connect("localhost", 5210, [binary]),
    State = #state{
        socket = Socket,
        recv_q = queue:new(),
        state = auth,
        recv_buf = <<"">>,
        options = Options
    },
    {ok, State}.


terminate(_Reason, State) ->
    Socket = State#state.socket,
    ssl_close(Socket),
    ok.


handle_call({send, Message}, _From, State) ->
    Socket = State#state.socket,
    Result = send_internal(Socket, Message),
    {reply, Result, State};


handle_call({recv_nb}, _From, State) ->
    {Val, RecvQ2} = queue:out(State#state.recv_q),
    NewState = State#state{recv_q = RecvQ2},
    Result = case Val of
        empty -> undefined;
        {value, Message} -> Message
    end,
    {reply, Result, NewState};


handle_call({recv}, _From, State) ->
    {Val, RecvQ2} = queue:out(State#state.recv_q),
    NewState = State#state{recv_q = RecvQ2},
    {Result, NewState2} = case Val of
        empty ->
            receive_wait(NewState);
        {value, Message} ->
            {Message, NewState}
    end,
    {reply, Result, NewState2};

handle_call({recv, TimeoutMs}, _From, State) ->
    {Val, RecvQ2} = queue:out(State#state.recv_q),
    NewState = State#state{recv_q = RecvQ2},
    {Result, NewState2} = case Val of
        empty ->
            receive_wait(NewState, TimeoutMs);
        {value, Message} ->
            {Message, NewState}
    end,
    {reply, Result, NewState2};

handle_call({login, Uid, Passwd}, _From,
        #state{options = Options} = State) ->
    Socket = State#state.socket,
    HaAuth = #pb_auth_request{
        uid = Uid,
        pwd = Passwd,
        client_mode = #pb_client_mode{mode = active},
        %% TODO(murali@): add version based tests.
        client_version = #pb_client_version{
            version = maps:get(version, Options, ?DEFAUL_UA)},
        resource = maps:get(resource, Options, ?DEFAULT_RESOURCE)
    },
    send_internal(Socket, HaAuth),
    ?assert(auth =:= State#state.state),
    {Result, NewState} = receive_wait(State),
    {reply, Result, NewState};

handle_call({wait_for, MatchFun}, _From, State) ->
    Q = State#state.recv_q,
    % look over the recv_q first for the first Packet where MatchFun(P) -> true
    % return the list minus this element
    {Packet, NewQueueReversed} = lists:foldl(
        fun (X, {FoundPacket, NewQueue}) ->
            case {FoundPacket, MatchFun(X)} of
                {undefined, true} ->
                    {X, NewQueue};
                {undefined, false} ->
                    {undefined, [X | NewQueue]};
                {FoundPacket, _} ->
                    {FoundPacket, [X | NewQueue]}
            end
        end, {undefined, []}, queue:to_list(Q)),
    NewQueue2 = lists:reverse(NewQueueReversed),

    {Packet2, NewState2} = case {Packet, NewQueue2} of
        {undefined, _} ->
            network_receive_until(State, MatchFun);
        {Packet, NewQueue2} ->
            NewState = State#state{recv_q = queue:from_list(NewQueue2)},
            {Packet, NewState}
    end,
    {reply, Packet2, NewState2}.


handle_cast(Something, State) ->
    ?INFO("handle_cast ~p", [Something]),
    {noreply, State}.


handle_info({ha_raw_packet, PacketBytes}, State) ->
    {_Packet, NewState} = handle_raw_packet(PacketBytes, State),
    {noreply, NewState};

handle_info({ssl, _Socket, Message}, State) ->
    ?INFO("recv ~p", [Message]),
    OldRecvBuf = State#state.recv_buf,
    Buffer = <<OldRecvBuf/binary, Message/binary>>,
    NewRecvBuf = parse_and_queue_ha_packets(Buffer),
    NewState = State#state{recv_buf = NewRecvBuf},
    {noreply, NewState};

handle_info(Something, State) ->
    ?INFO("handle_info ~p", [Something]),
    {noreply, State}.

handle_packet(#pb_auth_result{} = Packet, State) ->
    NewState = handle_auth_result(Packet, State),
    {Packet, NewState};
handle_packet(#pb_packet{stanza = #pb_ack{id = Id} = _Ack} = Packet, State) ->
    ?INFO_MSG("recv ack: ~s", [Id]),
    NewState = queue_in(Packet, State),
    {Packet, NewState};
handle_packet(#pb_packet{stanza = #pb_msg{id = Id}} = Packet,
        #state{options = #{auto_send_acks := AutoSendAcks}} = State) ->
    ?INFO_MSG("recv msg: ~s", [Id]),
    State1 = case AutoSendAcks of
        true -> send_ack_internal(Id, State);
        false -> State
    end,
    State2 = queue_in(Packet, State1),
    {Packet, State2};
handle_packet(#pb_packet{} = Packet, State) ->
    NewState = queue_in(Packet, State),
    {Packet, NewState};
handle_packet(Packet, State) ->
    {Packet, State}.

handle_raw_packet(PacketBytes, State) ->
    ?INFO_MSG("got ~p", [PacketBytes]),
    {Packet1, State1} = case State#state.state of
        auth ->
            PBAuthResult = enif_protobuf:decode(PacketBytes, pb_auth_result),
            ?INFO_MSG("recv pb_auth_result ~p", [PBAuthResult]),
            handle_packet(PBAuthResult, State);
        connected ->
            Packet = enif_protobuf:decode(PacketBytes, pb_packet),
            ?INFO_MSG("recv packet ~p", [Packet]),
            handle_packet(Packet, State)
    end,
    {Packet1, State1}.

handle_auth_result(
        #pb_auth_result{result = Result, reason = Reason, props_hash = _PropsHash} = PBAuthResult,
        State) ->
    ?INFO("auth result: ~p", [PBAuthResult]),
    case Result of
        <<"success">> ->
            ?INFO("auth success", []),
            State#state{state = connected};
        <<"failure">> ->
            ?INFO("auth failure reason: ~p", [Reason]),
            State
    end.

-spec send_ack_internal(Id :: any(), State :: state()) -> state().
send_ack_internal(Id, State) ->
    Packet = #pb_packet{
        stanza = #pb_ack{
            id = Id,
            timestamp = util:now()
        }
    },
    ok = send_internal(State#state.socket, Packet),
    State.


send_internal(Socket, Message) when is_binary(Message) ->
    Size = byte_size(Message),
    Result = ssl_send(Socket, <<Size:32/big, Message/binary>>),
    ?INFO("sent message, result: ~p", [Result]),
    Result;
send_internal(Socket, PBRecord)
        when is_record(PBRecord, pb_auth_request); is_record(PBRecord, pb_packet) ->
    ?INFO("Encoding Record ~p", [PBRecord]),
    % TODO: handle encode error and raise it
    case enif_protobuf:encode(PBRecord) of
        {error, Reason} ->
            ?ERROR("Failed to encode PB: Reason ~p Record: ~p", [Reason, PBRecord]),
            erlang:error({protobuf_encode_error, Reason, PBRecord});
        Message ->
            ?INFO("Message ~p", [Message]),
            send_internal(Socket, Message)
    end.



-spec receive_wait(State :: state()) -> {Packet :: maybe(pb_packet()), NewState :: state()}.
receive_wait(State) ->
    receive_wait(State, infinity).


-spec receive_wait(State :: state(), TimeoutMs :: integer() | infinity) ->
        {Packet :: maybe(pb_packet()), NewState :: state()}.
receive_wait(State, TimeoutMs) ->
    receive
        {ha_raw_packet, PacketBytes} ->
            handle_raw_packet(PacketBytes, State);
        {ssl, _Socket, _SocketBytes} = Pkt ->
            {noreply, NewState} = handle_info(Pkt, State),
            receive_wait(NewState)
    after TimeoutMs ->
        {undefined, State}
    end.


parse_and_queue_ha_packets(Buffer) ->
    case byte_size(Buffer) >= 4 of
        true ->
            <<_ControlByte:8, PacketSize:24, Rest/binary>> = Buffer,
            case byte_size(Rest) >= PacketSize of
                true ->
                    <<Packet:PacketSize/binary, Rem/binary>> = Rest,
                    self() ! {ha_raw_packet, Packet},
                    parse_and_queue_ha_packets(Rem);
                false ->
                    Buffer
            end;
        false ->
            Buffer
    end.


-spec network_receive_until(State :: state(), fun((term()) -> boolean())) -> {pb_packet(), state()}.
network_receive_until(State, MatchFun) ->
    {Packet, NewState1} = receive_wait(State),
    case MatchFun(Packet) of
        true ->
            % Remove packet from the rear/end of the queue, It should be the one we just received.
            {{value, Packet}, Q2} = queue:out_r(NewState1#state.recv_q),
            NewState2 = NewState1#state{recv_q = Q2},
            {Packet, NewState2};
        false ->
            network_receive_until(NewState1, MatchFun)
    end.


-spec queue_in(Packet :: pb_packet(), State :: state()) -> state().
queue_in(Packet, State) ->
    State#state{recv_q = queue:in(Packet, State#state.recv_q)}.


-spec ssl_close(Socket :: any()) -> ok | {error, any()}.
ssl_close(undefined) ->
    ?ERROR("Socket is undefined"),
    ok;
ssl_close(Socket) ->
    ssl:close(Socket).


-spec ssl_send(Socket :: any(), Data :: binary()) -> ok | {error, any()}.
ssl_send(Socket, Data) ->
    ssl:send(Socket, Data).

