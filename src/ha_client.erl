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
-export([start_link/0]).

-export([
    send/2,
    recv_nb/1,
    recv/1,
    close/1,
    send_auth/3,
    wait_for/2,
    send_recv/2
]).

-export([
    init/1,
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

% TODO: move this somewhere else
-type pb_packet() :: #pb_packet{}.


start_link() ->
    gen_server:start_link(ha_client, [], []).


-spec send(Client :: pid(), Message :: iolist() | pb_packet()) -> ok | {error, closed | inet:posix()}.
send(Client, Message) ->
    gen_server:call(Client, {send, Message}).


% Get the next received message or undefined if no message is received.
-spec recv_nb(Client :: pid()) -> maybe(pb_packet()).
recv_nb(Client) ->
    gen_server:call(Client, {recv_nb}).

% Gets the next received message or waits for one.
-spec recv(Client :: pid()) -> pb_packet().
recv(Client) ->
    gen_server:call(Client, {recv}).

% Close the connection
-spec close(Client :: pid()) -> ok.
close(Client) ->
    gen_server:call(Client, {close}).

-spec wait_for(Client :: pid(), function()) -> pb_packet().
wait_for(Client, MatchFun) ->
    gen_server:call(Client, {wait_form, MatchFun}).


-spec send_recv(Cleint :: pid(), Message :: iolist() | pb_packet()) -> pb_packet().
send_recv(Client, Message) ->
    gen_server:call(Client, {send_recv, Message}).


% send pb_auth_request message
-spec send_auth(Client :: pid(), Uid :: uid(), Password :: binary()) -> ok.
send_auth(Client, Uid, Password) ->
    gen_server:call(Client, {send_auth, Uid, Password}).


init(_Args) ->
    {ok, Socket} = ssl:connect("localhost", 5210, [binary]),
    State = #state{
        socket = Socket,
        recv_q = queue:new(),
        state = auth,
        recv_buf = <<"">>
    },
    {ok, State}.


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
    Result = case Val of
        empty ->
            receive
                {ssl, _Socket, Message} ->
                    ?INFO_MSG("recv got ~p", [Message]),
                    Message

            end;
        {value, Message} -> Message
    end,
    {reply, Result, NewState};

handle_call({close}, _From, State) ->
    Socket = State#state.socket,
    ssl:close(Socket),
    NewState = State#state{socket = undefined},
    {reply, ok, NewState};

handle_call({send_auth, Uid, Passwd}, _From, State) ->
    ct:pal("sending_auth"),
    Socket = State#state.socket,
    HaAuth = #pb_auth_request{
        uid = Uid,
        pwd = Passwd,
        cm = #pb_client_mode{mode = active},
        cv = #pb_client_version{version = <<"HalloAppAndroid/82D">>},
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
    Results = lists:filter(MatchFun, queue:to_list(Q)),
    {Message, NewState} = case Results of
        [] ->
            {Message, NewState} = network_receive_until(State, MatchFun);
        [Message | _Rest] ->
            NewQueue = queue:filter(
                fun (X) ->
                    X =/= Message
                end,
                Q
            ),
            NewState = State#state{recv_q = NewQueue},
            {Message, NewState}
    end,
    {reply, Message, NewState}.


handle_cast(Something, State) ->
    ?INFO_MSG("handle_cast ~p", [Something]),
    {noreply, State}.

handle_info({ha_packet, PacketBytes}, State) ->
    ?INFO_MSG("got ~p", [PacketBytes]),
    NewState = case State#state.state of
        auth ->
            PBAuthResult = enif_protobuf:decode(PacketBytes, pb_auth_result),
            handle_auth_result(PBAuthResult, State);
        connected ->
            Packet = enif_protobuf:decode(PacketBytes, pb_packet),
            ?INFO_MSG("recv packet ~p", [Packet]),
            RecvQ = queue:in(Packet, State#state.recv_q),
            State#state{recv_q = RecvQ}
    end,
    {noreply, NewState};

handle_info({ssl, _Socket, Message}, State) ->
    ?INFO_MSG("recv ~p", [Message]),
    OldRecvBuf = State#state.recv_buf,
    Buffer = <<OldRecvBuf/binary, Message/binary>>,
    NewRecvBuf = decode_ha_packets(Buffer),
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
    Message = enif_protobuf:encode(PBRecord),
    ?INFO_MSG("Message ~p", [Message]),
    send_internal(Socket, Message).


receive_wait(State) ->
    receive
        {ha_packet, PacketBytes} ->
            {noreply, NewState} = hanlde_info({ha_packet, PacketBytes}, State),
            PBAuthResult = enif_protobuf:decode(PacketBytes, pb_auth_result),
            NewState = handle_auth_result(PBAuthResult, State),
            {PBAuthResult, NewState};
        {ssl, _Socket, _SocketBytes} = Pkt ->
            {noreply, NewState} = handle_info(Pkt, State),
            receive_wait(NewState)
    end.


decode_ha_packets(Buffer) ->
    case byte_size(Buffer) >= 4 of
        true ->
            <<_ControlByte:8, PacketSize:24, Rest/binary>> = Buffer,
            case byte_size(Rest) >= PacketSize of
                true ->
                    <<Packet:PacketSize/binary, Rem/binary>> = Rest,
                    self() ! {ha_packet, Packet},
                    decode_ha_packets(Rem);
                false ->
                    Buffer
            end;
        false ->
            Buffer
    end.


-spec network_receive_until(State :: #state{}, fun((term()) -> boolean())) -> {#pb_packet{}, #state{}}.
network_receive_until(State, MatchFun) ->
    Packet = receive_one(),
    case MatchFun(Packet) of
        true ->
            {Packet, State};
        false ->
            NewState1 = State#state{recv_q = queue:in(Packet, State#state.recv_q)},
            network_receive_until(NewState1, MatchFun)
    end.

receive_one() ->
    receive
        {ssl, _Socket, Message} ->
            ?INFO_MSG("recv got ~p", [Message]),
            parse_message(Message)
    end.


parse_message(Message) ->
    <<Size:32/big, Payload/binary>> = Message,
    ?assert(byte_size(Payload) =:= Size),
    enif_protobuf:decode(Payload, pb_packet).

