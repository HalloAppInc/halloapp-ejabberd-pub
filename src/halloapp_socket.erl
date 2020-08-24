%%%-------------------------------------------------------------------
%%% File    : halloapp_socket.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
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

-type sockmod() :: gen_tcp | fast_tls | ext_mod().
-type socket() :: inet:socket() | fast_tls:tls_socket() | ext_socket().
-type ext_mod() :: module().
-type ext_socket() :: any().
-type endpoint() :: {inet:ip_address(), inet:port_number()}.
-type cert() :: #'Certificate'{} | #'OTPCertificate'{}.
-type pb_packet() :: #pb_packet{}.

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


-spec send_element(SocketData :: socket_state(), Pkt :: pb_packet()) -> ok | {error, inet:posix()}.
send_element(SocketData, Pkt) ->
    ?DEBUG("send: xmpp: ~p", [Pkt]),
    FinalPkt = enif_protobuf:encode(Pkt),
    stat:count("HA/pb_packet", "encode_success"),
    ?DEBUG("send: protobuf: ~p", [FinalPkt]),
    PktSize = byte_size(FinalPkt),
    %% TODO(murali@): remove this code after noise integration.
    FinalData = <<PktSize:32/integer, FinalPkt/binary>>,
    ?DEBUG("send: protobuf with size: ~p", [FinalData]),
    send(SocketData, FinalData).


-spec send(socket_state(), iodata()) -> ok | {error, closed | inet:posix()}.
send(#socket_state{sockmod = SockMod, socket = Socket} = SocketData, Data) ->
    ?DEBUG("(~s) Sending pb bytes on stream = ~p", [pp(SocketData), Data]),
    try SockMod:send(Socket, Data) of
        {error, einval} -> {error, closed};
        Result -> Result
    catch _:badarg ->
        %% Some modules throw badarg exceptions on closed sockets
        %% TODO: their code should be improved
        {error, closed}
    end.


recv(#socket_state{sockmod = SockMod, socket = Socket} = SocketData, Data) ->
    case SockMod of
        fast_tls ->
            case fast_tls:recv_data(Socket, Data) of
            {ok, TLSData} ->
                parse(SocketData, TLSData);
            {error, _} = Err ->
                Err
            end;
        _ ->
            parse(SocketData, Data)
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
        _ -> SockMod:get_transport(Socket)
    end.


get_owner(SockMod, _) when SockMod == gen_tcp orelse SockMod == fast_tls ->
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

parse(#socket_state{pb_stream = PBStream, socket = _Socket,
        shaper = _ShaperState} = SocketData, Data) when is_binary(Data) ->
    %% TODO(murali@): add shaper rules here.
    ?DEBUG("(~s) Received pb bytes on stream = ~p", [pp(SocketData), Data]),
    %% TODO(murali@): remove this code after noise integration.
    FinalData = <<PBStream/binary, Data/binary>>,
    case byte_size(FinalData) > 4 of
        true ->
            <<_ControlByte:8, PacketSize:24, Rest/binary>> = FinalData,
            case byte_size(Rest) >= PacketSize of
                true ->
                    <<Packet:PacketSize/binary, Rem/binary>> = Rest,
                    self() ! {'$gen_event', {protobuf, Packet}},
                    parse(SocketData#socket_state{pb_stream = Rem}, <<>>);
                false ->
                    {ok, SocketData#socket_state{pb_stream = FinalData}}
            end;
        false ->
            {ok, SocketData#socket_state{pb_stream = FinalData}}
    end.


shaper_update(none, _) ->
    {none, 0};
shaper_update(Shaper, Size) ->
    p1_shaper:update(Shaper, Size).

