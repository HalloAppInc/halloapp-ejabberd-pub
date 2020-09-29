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
-include("ha_auth.hrl").

%% API
-export([
    start_link/0,
    stop/1,
    connect_and_login/2,
    send/2,
    recv_nb/1,
    recv/1,
    send_recv/2,
    wait_for/2,
    login/3

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
    recv_buf = <<>> :: binary()
}).

-type state() :: #state{}.


% TODO: move this somewhere else
-type pb_packet() :: #pb_packet{}.

% TODO: handle acks,
% TODO: send acks to server.
start_link() ->
    gen_server:start_link(ha_client, [], []).

-spec connect_and_login(Uid :: uid(), Password :: binary()) ->
        {ok, Client :: pid()} | {error, Reason :: term()}.
connect_and_login(Uid, Password) ->
    {ok, C} = start_link(),
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


% Get the next received message or undefined if no message is received.
% This API does not block waiting for network messages, it returns undefined.
-spec recv_nb(Client :: pid()) -> maybe(pb_packet()).
recv_nb(Client) ->
    gen_server:call(Client, {recv_nb}).

% Gets the next received message or waits for one. Blocking API.
-spec recv(Client :: pid()) -> pb_packet().
recv(Client) ->
    gen_server:call(Client, {recv}).


% Stop the gen_server
-spec stop(Client :: pid()) -> ok.
stop(Client) ->
    gen_server:stop(Client).

% Check the received messages for the first message where Func(Message) returns true.
% If no such message is already received it waits for such message to arrive from the server.
-spec wait_for(Client :: pid(), Func :: fun((term()) -> boolean())) -> pb_packet().
wait_for(Client, MatchFun) ->
    gen_server:call(Client, {wait_for, MatchFun}).


-spec send_recv(Client :: pid(), Packet :: iolist() | pb_packet()) -> pb_packet().
send_recv(Client, Packet) ->
    gen_server:call(Client, {send_recv, Packet}).


% send pb_auth_request message
-spec login(Client :: pid(), Uid :: uid(), Password :: binary()) -> ok.
login(Client, Uid, Password) ->
    gen_server:call(Client, {login, Uid, Password}).


init(_Args) ->
    {ok, Socket} = ssl:connect("localhost", 5210, [binary]),
    State = #state{
        socket = Socket,
        recv_q = queue:new(),
        state = auth,
        recv_buf = <<"">>
    },
    {ok, State}.


terminate(_Reason, State) ->
    Socket = State#state.socket,
    ssl:close(Socket),
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

handle_call({close}, _From, State) ->
    Socket = State#state.socket,
    ssl:close(Socket),
    NewState = State#state{socket = undefined},
    {reply, ok, NewState};

handle_call({login, Uid, Passwd}, _From, State) ->
    ct:pal("sending_auth"),
    Socket = State#state.socket,
    HaAuth = #pb_auth_request{
        uid = util:to_integer(Uid),
        pwd = Passwd,
        cm = #pb_client_mode{mode = active},
        cv = #pb_client_version{version = <<"HalloApp/Android0.82D">>},
        resource = <<"android">>
    },
    ct:pal("before send"),
    send_internal(Socket, HaAuth),
    ct:pal("after send"),
    ?assert(auth =:= State#state.state),
    ct:pal("waiting for auth response"),
    {Result, NewState} = receive_wait(State),
    {reply, Result, NewState};

handle_call({wait_for, MatchFun}, _From, State) ->
    Q = State#state.recv_q,
    % look over the recv_q first for the first Packet where MatchFun(P) -> true
    % return the list minus this element
    {Packet, NewQueueReversed} = lists:foldr(
        fun (X, {FoundPacket, NewQueue}) ->
            case {FoundPacket, MatchFun(X)} of
                {undefined, true} ->
                    {X, NewQueue};
                {undefined, false} ->
                    {undefined, [X | NewQueue]};
                {FoundPacket, _} ->
                    {FoundPacket, [X | NewQueue]}
            end
        end, queue:to_list(Q), {undefined, []}),
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
    ?INFO_MSG("handle_cast ~p", [Something]),
    {noreply, State}.

handle_info({ha_packet, PacketBytes}, State) ->
    ?INFO_MSG("got ~p", [PacketBytes]),
    Result = case State#state.state of
        auth ->
            PBAuthResult = enif_protobuf:decode(PacketBytes, pb_auth_result),
            NewState = handle_auth_result(PBAuthResult, State),
            {PBAuthResult, NewState};
        connected ->
            Packet = enif_protobuf:decode(PacketBytes, pb_packet),
            ?INFO_MSG("recv packet ~p", [Packet]),
            RecvQ = queue:in(Packet, State#state.recv_q),
            {Packet, State#state{recv_q = RecvQ}}
    end,
    {noreply, Result};

handle_info({ssl, _Socket, Message}, State) ->
    ?INFO_MSG("recv ~p", [Message]),
    OldRecvBuf = State#state.recv_buf,
    Buffer = <<OldRecvBuf/binary, Message/binary>>,
    NewRecvBuf = parse_ha_packets(Buffer),
    NewState = State#state{recv_buf = NewRecvBuf},
    {noreply, NewState};

handle_info(Something, State) ->
    ?INFO_MSG("handle_info ~p", [Something]),
    {noreply, State}.

handle_auth_result(
        #pb_auth_result{result = Result, reason = Reason, props_hash = _PropsHash} = PBAuthResult,
        State) ->
    ?INFO_MSG("auth result: ~p", [PBAuthResult]),
    case Result of
        <<"success">> ->
            ?INFO_MSG("auth success", []),
            State#state{state = connected};
        <<"failure">> ->
            ?INFO_MSG("auth failure reason: ~p", [Reason]),
            State
    end.


send_internal(Socket, Message) when is_binary(Message) ->
    Size = byte_size(Message),
    ssl:send(Socket, <<Size:32/big, Message/binary>>);
send_internal(Socket, PBRecord)
        when is_record(PBRecord, pb_auth_request); is_record(PBRecord, pb_packet) ->
    ?INFO_MSG("Encoding Record ~p", [PBRecord]),
    % TODO: handle encode error and raise it
    Message = enif_protobuf:encode(PBRecord),
    ?INFO_MSG("Message ~p", [Message]),
    send_internal(Socket, Message).


-spec receive_wait(State :: state()) -> {Packet :: pb_packet(), NewState :: state()}.
receive_wait(State) ->
    receive
        {ha_packet, PacketBytes} ->
            {noreply, {Packet, NewState}} = handle_info({ha_packet, PacketBytes}, State),
            {Packet, NewState};
        {ssl, _Socket, _SocketBytes} = Pkt ->
            {noreply, NewState} = handle_info(Pkt, State),
            receive_wait(NewState)
    end.


parse_ha_packets(Buffer) ->
    case byte_size(Buffer) >= 4 of
        true ->
            <<_ControlByte:8, PacketSize:24, Rest/binary>> = Buffer,
            case byte_size(Rest) >= PacketSize of
                true ->
                    <<Packet:PacketSize/binary, Rem/binary>> = Rest,
                    self() ! {ha_packet, Packet},
                    parse_ha_packets(Rem);
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
            {{value, Packet}, Q2} = queue:out_r(Packet, NewState1#state.recv_q),
            NewState2 = NewState1#state{recv_q = Q2},
            {Packet, NewState2};
        false ->
            network_receive_until(NewState1, MatchFun)
    end.

