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
-include("ha_enoise.hrl").

-type keypair() :: enoise:noise_keypair().

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
    send_ack/2,
    clear_queue/1
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
    options :: options(),
    noise_socket :: noise_socket()
}).

-type state() :: #state{}.

-type options() :: #{
    auto_send_acks => boolean(),
    auto_send_pongs => boolean(),
    resource => binary(),
    version => binary(),
    host => string(),
    port => string(),
    _ => _
}.

%% TODO(murali@): add version based tests.
-define(DEFAUL_UA, <<"HalloApp/Android0.129">>).
-define(DEFAULT_RESOURCE, <<"android">>).

-define(DEFAULT_OPT, #{
    auto_send_acks => true,
    auto_send_pongs => true,
    host => "localhost",
    port => 5222
}).


start_link() ->
    start_link(?DEFAULT_OPT).

start_link(Options) ->
    gen_server:start_link(ha_client, [Options], []).


-spec connect_and_login(Uid :: uid(), Keypair :: keypair()) ->
    {ok, Client :: pid()} | {error, Reason :: term()}.
connect_and_login(Uid, Keypair) ->
    connect_and_login(Uid, Keypair, ?DEFAULT_OPT).


-spec connect_and_login(Uid :: uid(), Keypair :: keypair(), Options :: options()) ->
        {ok, Client :: pid()} | {error, Reason :: term()}.
connect_and_login(Uid, Keypair, Options) ->
    {ok, C} = start_link(Options),
    Result = login(C, Uid, Keypair),
    case Result of
        #pb_auth_result{result_string = <<"success">>} ->
            {ok, C};
        #pb_auth_result{result_string = <<"failure">>, reason = Reason} ->
            stop(C),
            {error, Reason};
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


% Clear the recv queue of the client.
-spec clear_queue(Client :: pid()) -> ok.
clear_queue(Client) ->
    gen_server:call(Client, {clear_queue}).


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
-spec login(Client :: pid(), Uid :: uid(), Keypair :: keypair()) -> ok.
login(Client, Uid, Keypair) ->
    gen_server:call(Client, {login, Uid, Keypair}).

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
    Host = maps:get(host, Options, maps:get(host, ?DEFAULT_OPT)),
    Port = maps:get(port, Options, maps:get(port, ?DEFAULT_OPT)),
    %% TODO: use a default root_public key to verify the certificate.

    %% Connect via tcp
    {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {active, true}]),

    State = #state{
        socket = Socket,
        recv_q = queue:new(),
        state = auth,
        recv_buf = <<"">>,
        options = Options,
        noise_socket = undefined
    },
    {ok, State}.


terminate(_Reason, State) ->
    NoiseSocket = State#state.noise_socket,
    noise_close(NoiseSocket),
    ok.


handle_call({send, Message}, _From, State) ->
    NoiseSocket = State#state.noise_socket,
    {Result, NoiseSocket2} = case send_internal(NoiseSocket, Message) of
        {ok, NoiseSocket1} -> {ok, NoiseSocket1};
        Error -> {Error, NoiseSocket}
    end,
    {reply, Result, State#state{noise_socket = NoiseSocket2}};


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

handle_call({login, Uid, ClientKeypair}, _From, State) ->
    %% TODO: add other noise patterns.
    %% TODO: use root_pub key to verify the certificate received from the server.
    %% Using xx always for now.
    {Result, NewState} = noise_xx(Uid, ClientKeypair, State),

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
    {reply, Packet2, NewState2};

handle_call({clear_queue}, _From, State) ->
    {reply, ok, State#state{recv_q = queue:new()}}.


handle_cast(Something, State) ->
    ?INFO("handle_cast ~p", [Something]),
    {noreply, State}.


handle_info({ha_raw_packet, PacketBytes}, State) ->
    {_Packet, NewState} = handle_raw_packet(PacketBytes, State),
    {noreply, NewState};

handle_info({tcp, _TcpSock, EncryptedData}, #state{noise_socket = NoiseSocket} = State) ->
    NewState = case ha_enoise:recv_data(NoiseSocket, EncryptedData) of
        {ok, NoiseSocket1, [], _Payload} ->
            State#state{noise_socket = NoiseSocket1};
        {ok, NoiseSocket1, Decrypted, <<>>} ->
            send_to_self(Decrypted),
            State#state{noise_socket = NoiseSocket1}
    end,
    {noreply, NewState};

handle_info(Something, State) ->
    ?INFO("ha_client handle_info ~p", [Something]),
    {noreply, State}.

handle_packet(#pb_auth_result{} = Packet, State) ->
    NewState = handle_auth_result(Packet, State),
    {Packet, NewState};
handle_packet(#pb_packet{stanza = #pb_ack{id = Id} = _Ack} = Packet, State) ->
    ?DEBUG("recv ack: ~s", [Id]),
    NewState = queue_in(Packet, State),
    {Packet, NewState};
handle_packet(#pb_packet{stanza = #pb_msg{id = Id}} = Packet,
        #state{options = #{auto_send_acks := AutoSendAcks}} = State) ->
    ?DEBUG("recv msg: ~s", [Id]),
    State1 = case AutoSendAcks of
        true -> send_ack_internal(Id, State);
        false -> State
    end,
    State2 = queue_in(Packet, State1),
    {Packet, State2};
handle_packet(#pb_packet{stanza = #pb_iq{id = Id, type = get, payload = #pb_ping{}}} = Packet,
        #state{options = #{auto_send_pongs := AutoSendPongs}} = State) ->
    State1 = case AutoSendPongs of
        true -> send_pong_internal(Id, State);
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
   % ?DEBUG("got ~p", [PacketBytes]),
    {Packet1, State1} = case State#state.state of
        auth ->
            PBAuthResult = enif_protobuf:decode(PacketBytes, pb_auth_result),
            % ?DEBUG("recv pb_auth_result ~p", [PBAuthResult]),
            handle_packet(PBAuthResult, State);
        connected ->
            Packet = enif_protobuf:decode(PacketBytes, pb_packet),
            % ?DEBUG("recv packet ~p", [Packet]),
            handle_packet(Packet, State)
    end,
    {Packet1, State1}.

handle_auth_result(
        #pb_auth_result{result_string = Result, reason_string = Reason, props_hash = _PropsHash} = _PBAuthResult,
        State) ->
    % ?DEBUG("auth result: ~p", [PBAuthResult]),
    case Result of
        <<"success">> ->
            % ?DEBUG("auth success", []),
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
    {ok, NoiseSocket} = send_internal(State#state.noise_socket, Packet),
    State#state{noise_socket = NoiseSocket}.


-spec send_pong_internal(Id :: any(), State :: state()) -> state().
send_pong_internal(Id, State) ->
    Packet = #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result
        }
    },
    {ok, NoiseSocket} = send_internal(State#state.noise_socket, Packet),
    State#state{noise_socket = NoiseSocket}.


send_internal(NoiseSocket, Message) when is_binary(Message) ->
    {ok, NoiseSocket1} = ha_enoise:send(NoiseSocket, Message),
    % ?DEBUG("sent message, result: ~p", [NoiseSocket]),
    {ok, NoiseSocket1};
send_internal(NoiseSocket, PBRecord)
        when is_record(PBRecord, pb_auth_request); is_record(PBRecord, pb_packet) ->
    ?DEBUG("Encoding Record ~p", [PBRecord]),
    case enif_protobuf:encode(PBRecord) of
        {error, Reason} ->
            ?ERROR("Failed to encode PB: Reason ~p Record: ~p", [Reason, PBRecord]),
            erlang:error({protobuf_encode_error, Reason, PBRecord});
        Message ->
            % ?DEBUG("Message ~p", [Message]),
            send_internal(NoiseSocket, Message)
    end.



-spec receive_wait(State :: state()) -> {Packet :: maybe(pb_packet()), NewState :: state()}.
receive_wait(State) ->
    receive_wait(State, infinity).


-spec receive_wait(State :: state(), TimeoutMs :: integer() | infinity) ->
        {Packet :: maybe(pb_packet()), NewState :: state()}.
receive_wait(#state{socket = TcpSock, noise_socket = NoiseSocket} = State, TimeoutMs) ->
    receive
        {ha_raw_packet, PacketBytes} ->
            handle_raw_packet(PacketBytes, State);
        {tcp, TcpSock, EncryptedData} ->
            case ha_enoise:recv_data(NoiseSocket, EncryptedData) of
                {ok, NoiseSocket1, [], _Payload} ->
                    receive_wait(State#state{noise_socket = NoiseSocket1});
                {ok, NoiseSocket1, Decrypted, <<>>} ->
                    send_to_self(Decrypted),
                    receive_wait(State#state{noise_socket = NoiseSocket1})
            end
    after TimeoutMs ->
        {undefined, State}
    end.


-spec send_to_self(DecryptedPkts :: [binary()]) -> ok.
send_to_self(DecryptedPkts) ->
    lists:foreach(
        fun(Pkt) ->
            self() ! {ha_raw_packet, Pkt}
        end, DecryptedPkts),
    ok.


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


-spec noise_close(NoiseSocket :: any()) -> ok | {error, any()}.
noise_close(undefined) ->
    ?ERROR("Socket is undefined"),
    ok;
noise_close(NoiseSocket) ->
    ha_enoise:close(NoiseSocket).


%% Performs xx pattern handshake with the server.
-spec noise_xx(Uid :: binary(), ClientKeypair :: keypair(), State :: state()) -> {any(), state()}.
noise_xx(Uid, ClientKeypair, #state{options = Options, socket = TcpSock} = State) ->
    %% Initialize noise state ourselves.
    %% ha_enoise provides apis only for server side.
    Protocol = enoise_protocol:from_name(?NOISE_PATTERN_XX),
    NoiseOptions = [{noise, Protocol}, {s, ClientKeypair}],
    {ok, Crypto} = enoise:handshake(NoiseOptions, initiator),
    NoiseSocket = #noise_socket{tcpsock = TcpSock, crypto = Crypto, pattern = ?NOISE_PATTERN_XX},

    %% send <<"HA00">> header.
    gen_tcp:send(TcpSock, <<"HA00">>),

    %% send xx_a handshake message: message A.
    case noise_handshake_util:send_data(NoiseSocket, <<>>, xx_a) of
        {ok, NoiseSocket1} ->
            %% receive message B
            {ok, MsgB, NoiseSocket2} = noise_handshake_util:recv_loop(NoiseSocket1),

            %% read messageB and update state
            {ok, NoiseSocket3} = noise_handshake_util:read_data(NoiseSocket2, MsgB),

            HaAuth = #pb_auth_request{
                uid = Uid,
                client_mode = #pb_client_mode{mode = active},
                client_version = #pb_client_version{
                    version = maps:get(version, Options, ?DEFAUL_UA)
                },
                resource = maps:get(resource, Options, ?DEFAULT_RESOURCE)
            },
            ClientConfig = enif_protobuf:encode(HaAuth),
            % send message C and complete handshake
            {ok, NoiseSocket4} = noise_handshake_util:send_data(NoiseSocket3, ClientConfig, xx_c),

            %% Set noise header.
            NoiseSocket5 = NoiseSocket4#noise_socket{header = <<"HA00">>},

            %% wait to receive response.
            {Response, State1} = receive_wait(State#state{noise_socket = NoiseSocket5}),
            {Response, State1};
        Error ->
            {Error, State}
    end.

