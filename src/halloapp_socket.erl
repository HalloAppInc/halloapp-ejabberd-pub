%%%-------------------------------------------------------------------
%%% File    : halloapp_socket.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% TODO(murali@): revert logging of packets.
%%%-------------------------------------------------------------------

-module(halloapp_socket).
-author('yexin').
-author('murali').
-dialyzer({no_match, [send/2, parse/2]}).

%% API
-export([
    new/3,
    connect/3,
    connect/4,
    connect/5,
    starttls/2,
    startnoise/2,
    noise_check_spub/2,
    reset_stream/1,
    send_element/2,
    send/2,
    recv/2,
    activate/1,
    change_shaper/2,
    monitor/1,
    get_sockmod/1,
    get_transport/1,
    get_peer_certificate/2,
    get_verify_result/1,
    close/1,
    pp/1,
    sockname/1,
    peername/1
]).

-include("xmpp.hrl").
-include("logger.hrl").
-include("packets.hrl").
-include_lib("public_key/include/public_key.hrl").

-type sockmod() :: gen_tcp | fast_tls | enoise | ext_mod().
-type socket() :: inet:socket() | fast_tls:tls_socket() | ha_enoise:noise_socket() | ext_socket().
-type ext_mod() :: module().
-type ext_socket() :: any().
-type endpoint() :: {inet:ip_address(), inet:port_number()}.
-type cert() :: #'Certificate'{} | #'OTPCertificate'{}.

-record(socket_state,
{
    sockmod :: sockmod(),
    socket :: socket(),
    max_stanza_size :: integer(),
    pb_stream :: undefined | binary(),
    shaper = none :: none | p1_shaper:state(),
    sock_peer_name = none :: none | {endpoint(), endpoint()}
}).

-type socket_state() :: #socket_state{}.

-export_type([socket/0, socket_state/0, sockmod/0]).

-callback get_owner(ext_socket()) -> pid().
-callback get_transport(ext_socket()) -> atom().
-callback change_shaper(ext_socket(), none | p1_shaper:state()) -> ok.
-callback controlling_process(ext_socket(), pid()) -> ok | {error, inet:posix()}.
-callback close(ext_socket()) -> ok | {error, inet:posix()}.
-callback sockname(ext_socket()) -> {ok, endpoint()} | {error, inet:posix()}.
-callback peername(ext_socket()) -> {ok, endpoint()} | {error, inet:posix()}.
-callback setopts(ext_socket(), [{active, once}]) -> ok | {error, inet:posix()}.
-callback get_peer_certificate(ext_socket(), plain|otp|der) -> {ok, cert() | binary()} | error.

-optional_callbacks([get_peer_certificate/2]).


%%====================================================================
%% API
%%====================================================================


-spec new(sockmod(), socket(), [proplists:property()]) -> socket_state().
new(SockMod, Socket, Opts) ->
    MaxStanzaSize = proplists:get_value(max_stanza_size, Opts, infinity),
    SockPeer =  proplists:get_value(sock_peer_name, Opts, none),
    PBStream = case get_owner(SockMod, Socket) of
        Pid when Pid == self() -> <<>>;
        _ -> undefined
    end,
    #socket_state{
        sockmod = SockMod,
        socket = Socket,
        pb_stream = PBStream,
        max_stanza_size = MaxStanzaSize,
        sock_peer_name = SockPeer
    }.

connect(Addr, Port, Opts) ->
    connect(Addr, Port, Opts, infinity, self()).


connect(Addr, Port, Opts, Timeout) ->
    connect(Addr, Port, Opts, Timeout, self()).


connect(Addr, Port, Opts, Timeout, Owner) ->
    case gen_tcp:connect(Addr, Port, Opts, Timeout) of
        {ok, Socket} ->
            SocketData = new(gen_tcp, Socket, []),
            case controlling_process(SocketData, Owner) of
                ok ->
                    activate_after(Socket, Owner, 0),
                    {ok, SocketData};
                {error, _Reason} = Error ->
                    gen_tcp:close(Socket),
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.


-spec starttls(socket_state(), [proplists:property()]) -> {ok, socket_state()} |
        {error, inet:posix() | atom() | binary()}.
starttls(#socket_state{sockmod = gen_tcp, socket = Socket} = SocketData, TLSOpts) ->
    case fast_tls:tcp_to_tls(Socket, TLSOpts) of
        {ok, TLSSocket} ->
            SocketData1 = SocketData#socket_state{socket = TLSSocket, sockmod = fast_tls},
            SocketData2 = reset_stream(SocketData1),
            case fast_tls:recv_data(TLSSocket, <<>>) of
                {ok, TLSData} ->
                    parse(SocketData2, TLSData);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end;
starttls(_, _) ->
    erlang:error(badarg).


-spec noise_check_spub(binary(), binary()) -> ok | {error, binary()}.
noise_check_spub(SPub, Auth) ->
    try enif_protobuf:decode(Auth, pb_auth_request) of
        Pkt ->
            stat:count("HA/pb_packet", "decode_success"),
            ?DEBUG("recv: protobuf: ~p", [Pkt]),
            case ejabberd_auth:check_spub(
                    integer_to_binary(Pkt#pb_auth_request.uid), base64:encode(SPub)) of
                true ->
                    stat:count("HA/check_spub", "match"),
                    ok;
                false ->
                    stat:count("HA/check_spub", "mismatch"),
                    {error, <<"spub_mismatch">>}
            end
    catch _:_ ->
        stat:count("HA/pb_packet", "decode_failure"),
        {error, "failed_coded"}
    end.


-spec startnoise(socket_state(), [proplists:property()]) -> {ok, socket_state()} |
        {error, inet:posix() | atom() | binary()}.
startnoise(#socket_state{sockmod = gen_tcp, socket = Socket} = SocketData, NoiseOpts) ->
    {StaticKey, Certificate} = extract_noise_keys(NoiseOpts),
    case ha_enoise:tcp_to_noise(Socket, StaticKey, Certificate, fun noise_check_spub/2) of
        {ok, NoiseSocket} ->
            SocketData1 = SocketData#socket_state{socket = NoiseSocket, sockmod = ha_enoise},
            SocketData2 = reset_stream(SocketData1),
            {ok, SocketData2};
        {error, _} = Err ->
            ?ERROR("Failed to start noise, key: ~p, cert: ~p", [StaticKey, Certificate]),
            Err
    end;
startnoise(_, _) ->
    erlang:error(badarg).


extract_noise_keys(NoiseOpts) ->
    ServerStaticKey = proplists:get_value(noise_static_key, NoiseOpts, <<>>),
    ServerCertificate = proplists:get_value(noise_server_certificate, NoiseOpts, <<>>),
    {ServerStaticKey, ServerCertificate}.


reset_stream(#socket_state{pb_stream = PBStream, sockmod = SockMod,
        socket = Socket, max_stanza_size = _MaxStanzaSize} = SocketData) ->
    if
        PBStream /= undefined ->
            NewPBStream = <<>>,
            SocketData#socket_state{pb_stream = NewPBStream};
        true ->
            Socket1 = SockMod:reset_stream(Socket),
            SocketData#socket_state{socket = Socket1}
    end.


%% TODO(murali@): Update the log levels when printing the packet to be debug eventually.
-spec send_element(SocketData :: socket_state(), Pkt :: pb_packet()) -> 
    {ok, fast_tls} | {ok, noise, #socket_state{}} | ok | {error, inet:posix()}.
send_element(#socket_state{sockmod = SockMod} = SocketData, Pkt) ->
    ?INFO("send: xmpp: ~p", [Pkt]),
    case enif_protobuf:encode(Pkt) of
        {error, Reason} ->
            stat:count("HA/pb_packet", "encode_failure"),
            ?ERROR("Error encoding packet: ~p, reason: ~p", [Pkt, Reason]),
            %% protocol error.
            {error, eproto};
        FinalPkt ->
            stat:count("HA/pb_packet", "encode_success"),
            ?DEBUG("send: protobuf: ~p", [FinalPkt]),
            FinalData1 = case SockMod of
                fast_tls ->
                    PktSize = byte_size(FinalPkt),
                    FinalData = <<PktSize:32/big, FinalPkt/binary>>,
                    ?INFO("send: protobuf with size: ~p, via tls", [FinalData]),
                    FinalData;
                ha_enoise ->
                    ?INFO("send: protobuf: ~p, via noise (size will be added by ha_enoise)", [FinalPkt]),
                    FinalPkt
            end,
            send(SocketData, FinalData1)
    end.


-spec send(socket_state(), iodata()) -> {ok, fast_tls} | {ok, noise, #socket_state{}} |
                                        {error, closed | inet:posix()}.
send(#socket_state{sockmod = SockMod, socket = Socket} = SocketData, Data) ->
    ?DEBUG("(~s) Sending pb bytes on stream = ~p", [pp(SocketData), Data]),
    case SockMod of
        ha_enoise ->
            case ha_enoise:send(Socket, Data) of
                {ok, NoiseSocket} ->
                    {ok, noise, SocketData#socket_state{socket = NoiseSocket}};
                {error, _} = Err ->
                    Err
            end;
         fast_tls ->
            case fast_tls:send(Socket, Data) of
                ok -> {ok, fast_tls};
                {error, _} = Err -> Err
            end
    end.


recv(#socket_state{sockmod = SockMod, socket = Socket} = SocketData, Data) ->
    case SockMod of
        fast_tls ->
            case fast_tls:recv_data(Socket, Data) of
                {ok, TLSData} -> parse(SocketData, TLSData);
                {error, _} = Err -> Err
            end;
         ha_enoise ->
            case ha_enoise_recv_data(Socket, Data) of
                {ok, NoiseSocket, NoiseData, Payload} ->
                    SocketData1 = SocketData#socket_state{socket = NoiseSocket},
                    noise_parse(SocketData1, NoiseData, Payload);
                {error, {spub_mismatch, NoiseSocket}} = Err ->
                    {error, {spub_mismatch, SocketData#socket_state{socket = NoiseSocket}}};
                {error, _} = Err -> Err
            end
    end.

%% NoiseSocket returns a list of messages.
noise_parse(SocketData, Data, Payload)  when Data == <<>>; Data == [] ->
    {ok, SocketData1} = parse(SocketData, Data),
    case Payload of
        <<>> -> {ok, SocketData1};
        _ -> process_stream_validation(SocketData1, Payload)
    end;

noise_parse(SocketData1, [DecryptedMsg | Msgs], _Payload) ->
    {ok, SocketData2} = parse_message(SocketData1, DecryptedMsg),
    noise_parse(SocketData2, Msgs, <<>>).

process_stream_validation(SocketData, Bin) ->
    ?DEBUG("(~s) Received pb payload during noise handshake:  ~p", [pp(SocketData), Bin]),
    self() ! {'$gen_event', {stream_validation, Bin}},
    {ok, SocketData}.

ha_enoise_recv_data(Socket, Data) ->
    ?DEBUG("Received (to be received by noise) data:  ~p", [Data]),
    case Data of
        <<>> -> {ok, Socket, Data, <<>>};
        _ -> ha_enoise:recv_data(Socket, Data)
    end.


-spec change_shaper(socket_state(), none | p1_shaper:state()) -> socket_state().
change_shaper(#socket_state{pb_stream = PBStream,
                sockmod = SockMod,
                socket = Socket} = SocketData, Shaper) ->
    if
        PBStream /= undefined ->
            SocketData#socket_state{shaper = Shaper};
        true ->
            SockMod:change_shaper(Socket, Shaper),
            SocketData
    end.


monitor(#socket_state{pb_stream = undefined, sockmod = SockMod, socket = Socket}) ->
    erlang:monitor(process, SockMod:get_owner(Socket));
monitor(_) ->
    make_ref().


controlling_process(#socket_state{sockmod = SockMod, socket = Socket}, Pid) ->
    SockMod:controlling_process(Socket, Pid).


get_sockmod(SocketData) ->
    SocketData#socket_state.sockmod.


get_transport(#socket_state{sockmod = SockMod, socket = Socket}) ->
    case SockMod of
        gen_tcp -> tcp;
        fast_tls -> tls;
        ha_enoise -> noise;
        _ -> SockMod:get_transport(Socket)
    end.


get_owner(SockMod, _) when SockMod == gen_tcp orelse SockMod == fast_tls
                           orelse SockMod == ha_enoise ->
    self();
get_owner(SockMod, Socket) ->
    SockMod:get_owner(Socket).


-spec get_peer_certificate(socket_state(), plain|otp) -> {ok, cert()} | error;
        (socket_state(), der) -> {ok, binary()} | error.
get_peer_certificate(#socket_state{sockmod = SockMod, socket = Socket}, Type) ->
    case erlang:function_exported(SockMod, get_peer_certificate, 2) of
        true -> SockMod:get_peer_certificate(Socket, Type);
        false -> error
    end.


get_verify_result(SocketData) ->
    fast_tls:get_verify_result(SocketData#socket_state.socket).


close(#socket_state{sockmod = SockMod, socket = Socket}) ->
    SockMod:close(Socket).


-spec sockname(socket_state()) -> {ok, endpoint()} | {error, inet:posix()}.
sockname(#socket_state{sockmod = SockMod, socket = Socket, sock_peer_name = SockPeer}) ->
    case SockPeer of
        none ->
            case SockMod of
                gen_tcp -> inet:sockname(Socket);
                _ -> SockMod:sockname(Socket)
            end;
        {SN, _} ->
            {ok, SN}
    end.


-spec peername(socket_state()) -> {ok, endpoint()} | {error, inet:posix()}.
peername(#socket_state{sockmod = SockMod, socket = Socket, sock_peer_name = SockPeer}) ->
    case SockPeer of
        none ->
            case SockMod of
                gen_tcp -> inet:peername(Socket);
                _ -> SockMod:peername(Socket)
            end;
        {_, PN} ->
            {ok, PN}
    end.


activate(#socket_state{sockmod = SockMod, socket = Socket}) ->
    case SockMod of
        gen_tcp -> inet:setopts(Socket, [{active, once}]);
        _ -> SockMod:setopts(Socket, [{active, once}])
    end.


activate_after(Socket, Pid, Pause) ->
    if
        Pause > 0 ->
            erlang:send_after(Pause, Pid, {tcp, Socket, <<>>});
        true ->
            Pid ! {tcp, Socket, <<>>}
    end,
    ok.


pp(#socket_state{sockmod = SockMod, socket = Socket} = State) ->
    Transport = get_transport(State),
    Receiver = get_owner(SockMod, Socket),
    io_lib:format("~s|~w", [Transport, Receiver]).


parse(SocketData, Data) when Data == <<>>; Data == [] ->
    case activate(SocketData) of
        ok ->
            {ok, SocketData};
        {error, _} = Err ->
            Err
    end;

parse(#socket_state{socket = Socket} = SocketData, Data) when is_binary(Data) ->
    ?DEBUG("(~s) Received pb bytes on stream = ~p", [pp(SocketData), Data]),
    {ok, SocketData1} = parse_pb_data(SocketData, Data),
    ShaperState1 = SocketData1#socket_state.shaper,
    {ShaperState2, Pause} = shaper_update(ShaperState1, byte_size(Data)),
    SocketData2 = SocketData1#socket_state{shaper = ShaperState2},
    Result = case Pause > 0 of
        true ->
            %% TODO(murali@): add counters if necessary.
            ?WARNING("Shaper warning, pausing for ~p seconds", [Pause]),
            activate_after(Socket, self(), Pause);
        false ->
            activate(SocketData)
    end,
    case Result of
        ok ->
            {ok, SocketData2};
        {error, _} = Err ->
            ?ERROR("Error activating the socket: ~p", [SocketData]),
            Err
    end.


parse_pb_data(#socket_state{pb_stream = PBStream, socket = _Socket,
        shaper = _ShaperState} = SocketData, Data) when is_binary(Data) ->
    FinalData = <<PBStream/binary, Data/binary>>,
    ?INFO("(~s) Parsing data = ~p", [pp(SocketData), FinalData]),
    {ok, FinalSocketData} = case byte_size(FinalData) > 4 of
        true ->
            <<_ControlByte:8, PacketSize:24, Rest/binary>> = FinalData,
            case byte_size(Rest) >= PacketSize of
                true ->
                    <<Packet:PacketSize/binary, Rem/binary>> = Rest,
                    self() ! {'$gen_event', {protobuf, Packet}},
                    parse_pb_data(SocketData#socket_state{pb_stream = Rem}, <<>>);
                false ->
                    {ok, SocketData#socket_state{pb_stream = FinalData}}
            end;
        false ->
            {ok, SocketData#socket_state{pb_stream = FinalData}}
    end,
    {ok, FinalSocketData}.

parse_message(SocketData, Data) when is_binary(Data) ->
    %% TODO(murali@): add shaper rules here.
    ?DEBUG("(~s) Received pb bytes on noise stream = ~p", [pp(SocketData), Data]),
    self() ! {'$gen_event', {protobuf, Data}},
    {ok, SocketData}.

shaper_update(none, _) ->
    {none, 0};
shaper_update(Shaper, Size) ->
    p1_shaper:update(Shaper, Size).

