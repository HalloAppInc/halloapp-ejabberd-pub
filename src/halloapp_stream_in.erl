%%%-------------------------------------------------------------------
%%% File    : halloapp_stream_in.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% %%% TODO(murali@): revert logging of packets.
%%%-------------------------------------------------------------------

-module(halloapp_stream_in).
-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).
-author('yexin').
-author('murali').

-protocol({rfc, 6120}).
-protocol({xep, 114, '1.6'}).

%% gen_server callbacks
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).

%% API
-export([
    start/3,
    start_link/3,
    call/3,
    cast/2,
    reply/2,
    stop/1,
    accept/1,
    send/2,
    close/1,
    close/2,
    send_error/3,
    send_error/2,
    establish/1,
    get_transport/1,
    change_shaper/2,
    set_timeout/2,
    format_error/1
]).


%%-define(DBGFSM, true).
-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.


-include("logger.hrl").
-include("packets.hrl").
-include("ha_types.hrl").
-include("socket_state.hrl").
-type state() :: #{
    owner := pid(),
    mod := module(),
    socket := halloapp_socket:socket(),
    socket_mod => halloapp_socket:sockmod(),
    socket_opts => [proplists:property()],
    socket_monitor => reference(),
    stream_timeout := {integer(), integer()} | infinity,
    stream_state := stream_state(),
    stream_direction => in | out,
    stream_id => binary(),
    stream_version => {non_neg_integer(), non_neg_integer()},
    stream_authenticated => boolean(),
    crypto => tls | noise | none,
    ip => {inet:ip_address(), inet:port_number()},
    codec_options => [xmpp:decode_option()],
    xmlns => binary(),
    lang => binary(),
    user => binary(),
    server => binary(),
    resource => binary(),
    lserver => binary(),
    remote_server => binary(),
    mode => active | passive,
    _ => _
}.

-type stanza() :: pb_iq() | pb_msg() | pb_ack() | pb_presence() | pb_chat_state().
-type stream_state() :: accepting | wait_for_authentication | established | disconnected.
-type stop_reason() :: {stream, reset | {in | out, pb_ha_error()}} |
               {tls, inet:posix() | atom() | binary()} |
               {socket, inet:posix() | atom()} |
               internal_failure.
-type noreply() :: {noreply, state(), timeout()}.
-type next_state() :: noreply() | {stop, term(), state()}.

-export_type([state/0, stop_reason/0]).
-callback init(list()) -> {ok, state()} | {error, term()} | ignore.
-callback handle_cast(term(), state()) -> state().
-callback handle_call(term(), term(), state()) -> state().
-callback handle_info(term(), state()) -> state().
-callback terminate(term(), state()) -> any().
-callback code_change(term(), state(), term()) -> {ok, state()} | {error, term()}.
-callback handle_stream_established(state()) -> state().
-callback handle_stream_end(stop_reason(), state()) -> state().
-callback handle_authenticated_packet(stanza(), state()) -> state().
-callback handle_auth_result(
        maybe(uid()), true | {false, Reason :: binary()}, pb_auth_result(), state()) -> state().
-callback handle_send(binary(), pb_packet(), ok | {error, inet:posix()}, state()) -> state().
-callback handle_recv(binary(), pb_packet() | {error, term()}, state()) -> state().
-callback handle_timeout(state()) -> state().
-callback check_password_fun(xmpp_sasl:mechanism(), state()) -> fun().
-callback bind(binary(), state()) -> {ok, state()} | {error, any(), state()}.
-callback get_client_version_ttl(binary(), state()) -> integer().
-callback tls_options(state()) -> [proplists:property()].
-callback noise_options(state()) -> [proplists:property()].


%% Some callbacks are optional
-optional_callbacks([
    handle_stream_established/1,
    handle_stream_end/2,
    handle_send/4,
    handle_recv/3,
    handle_timeout/1
]).


%%%===================================================================
%%% API
%%%===================================================================


start(Mod, Args, Opts) ->
    ?GEN_SERVER:start(?MODULE, [Mod|Args], Opts ++ ?FSMOPTS).


start_link(Mod, Args, Opts) ->
    ?GEN_SERVER:start_link(?MODULE, [Mod|Args], Opts ++ ?FSMOPTS).


call(Ref, Msg, Timeout) ->
    ?GEN_SERVER:call(Ref, Msg, Timeout).


cast(Ref, Msg) ->
    ?GEN_SERVER:cast(Ref, Msg).


reply(Ref, Reply) ->
    ?GEN_SERVER:reply(Ref, Reply).


-spec stop(pid()) -> ok;
        (state()) -> no_return().
stop(Pid) when is_pid(Pid) ->
    cast(Pid, stop);
stop(#{owner := Owner} = State) when Owner == self() ->
    Reason = maps:get(stop_reason, State, normal),
    terminate(Reason, State),
    try erlang:nif_error(normal)
    catch _:_ -> exit(normal)
    end;
stop(_) ->
    erlang:error(badarg).


-spec accept(pid()) -> ok.
accept(Pid) ->
    cast(Pid, accept).


-spec send(pid(), stanza()) -> ok;
        (state(), stanza()) -> state().
send(Pid, Pkt) when is_pid(Pid) ->
    cast(Pid, {send, Pkt});
send(#{owner := Owner} = State, Pkt) when Owner == self() ->
    send_pkt(State, Pkt);
send(_, _) ->
    erlang:error(badarg).


-spec close(pid()) -> ok;
       (state()) -> state().
close(Pid) when is_pid(Pid) ->
    close(Pid, closed);
close(#{owner := Owner} = State) when Owner == self() ->
    close_socket(State);
close(_) ->
    erlang:error(badarg).


-spec close(pid(), atom()) -> ok.
close(Pid, Reason) ->
    cast(Pid, {close, Reason}).


-spec establish(state()) -> state().
establish(State) ->
    process_stream_established(State).


-spec set_timeout(state(), non_neg_integer() | infinity) -> state().
set_timeout(#{owner := Owner} = State, Timeout) when Owner == self() ->
    case Timeout of
        infinity -> State#{stream_timeout => infinity};
        _ ->
            Time = p1_time_compat:monotonic_time(milli_seconds),
            State#{stream_timeout => {Timeout, Time}}
    end;
set_timeout(_, _) ->
    erlang:error(badarg).


-spec get_transport(state()) -> atom().
get_transport(#{socket := Socket, owner := Owner})
  when Owner == self() ->
    halloapp_socket:get_transport(Socket);
get_transport(_) ->
    erlang:error(badarg).


-spec change_shaper(state(), none | p1_shaper:state()) -> state().
change_shaper(#{socket := Socket, owner := Owner} = State, Shaper)
  when Owner == self() ->
    Socket1 = halloapp_socket:change_shaper(Socket, Shaper),
    State#{socket => Socket1};
change_shaper(_, _) ->
    erlang:error(badarg).


-spec format_error(stop_reason()) ->  binary().
format_error({socket, Reason}) ->
    format("Connection failed: ~s", [format_inet_error(Reason)]);
format_error({stream, reset}) ->
    <<"Stream reset by peer">>;
format_error({tls, Reason}) ->
    format("TLS failed: ~s", [format_tls_error(Reason)]);
format_error(internal_failure) ->
    <<"Internal server error">>;
format_error(Err) ->
    format("Unrecognized error: ~w", [Err]).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Mod, {SockMod, Socket}, Opts]) ->
    Time = p1_time_compat:monotonic_time(milli_seconds),
    Timeout = timer:seconds(30),
    State = #{owner => self(),
            mod => Mod,
            socket => Socket,
            socket_mod => SockMod,
            socket_opts => Opts,
            stream_timeout => {Timeout, Time},
            stream_state => accepting
    },
    ?DEBUG("c2s_process state: ~p ~n", [State]),
    {ok, State, Timeout}.


-spec handle_cast(term(), state()) -> next_state().
handle_cast(accept, #{socket := Socket, socket_mod := SockMod, socket_opts := Opts} = State) ->
    PbSocket = halloapp_socket:new(SockMod, Socket, Opts),
    SocketMonitor = halloapp_socket:monitor(PbSocket),
    case halloapp_socket:peername(PbSocket) of
        {ok, IP} ->
            %% TODO(murali@): parse ip address properly.
            State1 = maps:remove(socket_mod, State),
            State2 = maps:remove(socket_opts, State1),
            State3 = State2#{socket => PbSocket, socket_monitor => SocketMonitor, ip => IP},
            State4 = init_state(State3, Opts),
            case is_disconnected(State4) of
                true -> noreply(State4);
                false -> handle_info({tcp, Socket, <<>>}, State4)
            end;
        {error, _} ->
            stop(State)
    end;

handle_cast({send, Pkt}, State) ->
    noreply(send_pkt(State, Pkt));

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast({close, Reason}, State) ->
    State1 = case Reason of
        shutdown -> send_error(State, Reason);
        _ -> close_socket(State)
    end,
    noreply(
        case is_disconnected(State) of
            true -> State1;
            false -> process_stream_end({socket, Reason}, State)
        end);

handle_cast(Cast, State) ->
    noreply(try callback(handle_cast, Cast, State)
          catch _:{?MODULE, undef} -> State
          end).


-spec handle_call(term(), term(), state()) -> next_state().
handle_call(Call, From, State) ->
    noreply(try callback(handle_call, Call, From, State)
        catch _:{?MODULE, undef} -> State
        end).


-spec handle_info(term(), state()) -> next_state().
handle_info({'$gen_event', closed}, State) ->
    noreply(process_stream_end({socket, closed}, State));

handle_info({'$gen_event', {protobuf, <<>>}}, _State) ->
    noreply(_State);

handle_info({'$gen_event', {protobuf, Bin}},
        #{stream_state := wait_for_authentication} = State) ->
    noreply(
        try enif_protobuf:decode(Bin, pb_auth_request) of
        #pb_auth_request{} = Pkt ->
            stat:count("HA/pb_packet", "decode_success", 1, [{socket_type, get_socket_type(State)}]),
            ?DEBUG("recv: protobuf: ~p", [Pkt]),

            State1 = try callback(handle_recv, Bin, Pkt, State)
               catch _:{?MODULE, undef} -> State
               end,
            case is_disconnected(State1) of
                true -> State1;
                false -> process_element(Pkt, State1)
            end
        catch _:_ ->
            stat:count("HA/pb_packet", "decode_failure", 1, [{socket_type, get_socket_type(State)}]),
            Why = <<"failed_codec">>,
            State2 = try callback(handle_recv, Bin, {error, Why}, State)
               catch _:{?MODULE, undef} -> State
               end,
            case is_disconnected(State2) of
                true -> State2;
                false -> send_error(State2, Bin, Why)
            end
        end);

handle_info({'$gen_event', {protobuf, Bin}},
        #{stream_state := established, socket := _Socket} = State) ->
    noreply(
        try enif_protobuf:decode(Bin, pb_packet) of
        #pb_packet{stanza = Pkt} ->
            stat:count("HA/pb_packet", "decode_success", 1, [{socket_type, get_socket_type(State)}]),
            ?DEBUG("recv: protobuf: ~p", [Pkt]),
            State1 = try callback(handle_recv, Bin, Pkt, State)
               catch _:{?MODULE, undef} -> State
               end,
            case is_disconnected(State1) of
                true -> State1;
                false -> process_element(Pkt, State1)
            end
        catch _:_ ->
            stat:count("HA/pb_packet", "decode_failure", 1, [{socket_type, get_socket_type(State)}]),
            Why = <<"failed_codec">>,
            State1 = try callback(handle_recv, Bin, {error, Why}, State)
               catch _:{?MODULE, undef} -> State
               end,
            case is_disconnected(State1) of
                true -> State1;
                false -> send_error(State1, Bin, Why)
            end
        end);

handle_info({'$gen_event', {stream_validation, Bin}}, #{socket := _Socket} = State) ->
    noreply(
        try enif_protobuf:decode(Bin, pb_auth_request) of
        #pb_auth_request{} = Pkt ->
            stat:count("HA/pb_packet", "decode_success", 1, [{socket_type, get_socket_type(State)}]),
            ?DEBUG("recv: protobuf: ~p", [Pkt]),
            %% Change stream state.
            State1 = process_stream_authentication(Pkt, State),
            State2 = try callback(handle_recv, Bin, Pkt, State1)
               catch _:{?MODULE, undef} -> State1
               end,
            case is_disconnected(State2) of
                true -> State2;
                false -> process_element(Pkt, State2)
            end
        catch _:_ ->
            stat:count("HA/pb_packet", "decode_failure", 1, [{socket_type, get_socket_type(State)}]),
            Why = <<"failed_codec">>,
            State1 = try callback(handle_recv, Bin, {error, Why}, State)
               catch _:{?MODULE, undef} -> State
               end,
            case is_disconnected(State1) of
                true -> State1;
                false -> send_error(State1, Bin, Why)
            end
        end);

handle_info(timeout, State) ->
    Disconnected = is_disconnected(State),
    noreply(try callback(handle_timeout, State)
        catch _:{?MODULE, undef} when not Disconnected ->
            process_stream_end(idle_connection, State);
          _:{?MODULE, undef} ->
            stop(State)
        end);

handle_info({'DOWN', MRef, _Type, _Object, _Info},
        #{socket_monitor := MRef} = State) ->
    noreply(process_stream_end({socket, closed}, State));

handle_info({tcp, _, Data}, #{socket := Socket, ip := IP} = State) ->
    noreply(
        case halloapp_socket:recv(Socket, Data) of
            {ok, NewSocket} ->
                State#{socket => NewSocket};
            {error, einval} ->
                process_stream_end({socket, einval}, State);
            {error, {spub_mismatch, NewSocket}} ->
                NewState = State#{socket => NewSocket},
                do_process_auth_request(NewState, undefined, false);
            {error, Reason} ->
                %% making these errors to be info - since we dont see any of our clients having issues.
                %% will keep monitoring these and update if necessary.
                ?INFO("noise error on read Reason: ~p Data(b64): ~p, IP: ~p",
                    [Reason, base64url:encode(Data), IP]),
                % TODO: I don't think we should send to the client those specific reasons
                send_error(State, noise_error)
        end);

handle_info({tcp_closed, _}, State) ->
    handle_info({'$gen_event', closed}, State);

handle_info({tcp_error, _, Reason}, State) ->
    noreply(process_stream_end({socket, Reason}, State));

handle_info({close, Reason}, State) ->
    %% TODO(murali@): same logic as handle_cast with close
    %% refactor to a simpler function call.
    State1 = close_socket(State),
    noreply(
        case is_disconnected(State) of
            true -> State1;
            false -> process_stream_end({socket, Reason}, State)
        end);

handle_info(Info, State) ->
    noreply(try callback(handle_info, Info, State)
        catch _:{?MODULE, undef} -> State
        end).


-spec terminate(term(), state()) -> state().
terminate(_, #{stream_state := accepting} = State) ->
    State;
terminate(Reason, State) ->
    case get(already_terminated) of
        true ->
            State;
        _ ->
            put(already_terminated, true),
            try callback(terminate, Reason, State)
            catch _:{?MODULE, undef} -> ok
            end,
            close_socket(State)
    end.


-spec code_change(term(), state(), term()) -> {ok, state()} | {error, term()}.
code_change(OldVsn, State, Extra) ->
    callback(code_change, OldVsn, State, Extra).


%%%===================================================================
%%% Internal functions
%%%===================================================================


-spec init_state(state(), [proplists:property()]) -> state().
init_state(#{socket := Socket, mod := Mod} = State, Opts) ->
    Crypto = proplists:get_value(crypto, Opts, tls),
    SocketType = Crypto,
    OfflineQueueParams = #{
            window => undefined,
            pending_acks => 0,
            last_msg_order_id => 0},
    State1 = State#{stream_direction => in,
            stream_id => xmpp_stream:new_id(),
            stream_state => wait_for_authentication,
            stream_version => {1,0},
            stream_authenticated => false,
            offline_queue_cleared => false,
            offline_queue_params => OfflineQueueParams,
            end_of_queue_msg_id => undefined,
            crypto => Crypto,
            codec_options => [ignore_els],
            lang => <<"">>,
            user => <<"">>,
            server => <<"">>,
            resource => <<"">>,
            lserver => <<"">>},
    case try Mod:init([State1, Opts])
    catch _:undef -> {ok, State1}
    end of
        {ok, State2} when Crypto =:= tls ->
            TLSOpts = try callback(tls_options, State2)
                catch _:{?MODULE, undef} -> []
                end,
            case halloapp_socket:starttls(Socket, TLSOpts) of
                {ok, TLSSocket} ->
                    State2#{socket => TLSSocket#socket_state{socket_type = SocketType},
                            tls_options => TLSOpts, socket_type => SocketType};
                {error, Reason} ->
                    process_stream_end({tls, Reason}, State2)
            end;
         {ok, State2} when Crypto =:= noise ->
            NoiseOpts = try callback(noise_options, State2)
                catch _:{?MODULE, undef} -> []
                end,
            ?DEBUG("NoiseOpts : ~p", [NoiseOpts]),
            case halloapp_socket:startnoise(Socket, NoiseOpts) of
                {ok, NoiseSocket} ->
                    State2#{socket => NoiseSocket#socket_state{socket_type = SocketType},
                            socket_type => SocketType};
                {error, Reason} ->
                    %% TODO(murali@): Need to send back an eror response to client in case of auth failures.
                    process_stream_end({noise, Reason}, State2)
            end;
        {ok, State2} when Crypto =:= none ->
            State2#{socket_type => SocketType};
        {error, Reason} ->
            process_stream_end(Reason, State1);
        ignore ->
            stop(State)
    end.


-spec noreply(state()) -> noreply().
noreply(#{stream_timeout := infinity} = State) ->
    {noreply, State, infinity};
noreply(#{stream_timeout := {MSecs, StartTime}} = State) ->
    CurrentTime = p1_time_compat:monotonic_time(milli_seconds),
    Timeout = max(0, MSecs - CurrentTime + StartTime),
    {noreply, State, Timeout}.


-spec is_disconnected(state()) -> boolean().
is_disconnected(#{stream_state := StreamState}) ->
    StreamState == disconnected.


-spec process_stream_end(stop_reason(), state()) -> state().
process_stream_end(_, #{stream_state := disconnected} = State) ->
    State;
process_stream_end(Reason, State) ->
    State1 = State#{stream_timeout => infinity, stream_state => disconnected},
    try callback(handle_stream_end, Reason, State1)
    catch _:{?MODULE, undef} ->
        stop(State1),
        State1
    end.


-spec process_element(stanza(), state()) -> state().
process_element(Pkt, #{stream_state := StateName} = State) ->
    FinalState = case Pkt of
        #pb_auth_request{} when StateName == wait_for_authentication ->
            process_auth_request(Pkt, State);
        #pb_ha_error{} ->
            ?ERROR("should-never-happen, error stanza from clients"),
            process_stream_end({stream, {in, Pkt}}, State);
        _ when StateName == wait_for_authentication ->
            process_stream_end(un_authenticated, State);
        _ when StateName == established ->
            process_authenticated_packet(Pkt, State)
    end,
    FinalState.


-spec process_authenticated_packet(stanza(), state()) -> state().
process_authenticated_packet(Pkt, State) ->
    case set_from_to(Pkt, State) of
        {ok, Pkt1} ->
            try callback(handle_authenticated_packet, Pkt1, State)
            catch _:{?MODULE, undef} ->
                process_stream_end(service_unavailable, State)
            end;
        {error, Err} ->
            process_stream_end(Err, State)
    end.


%% Noise based stream authentication - indicated by successful completion of the handshake.
-spec process_stream_authentication(pb_auth_request(), state()) -> state().
process_stream_authentication(#pb_auth_request{uid = Uid, client_mode = ClientMode,
        client_version = PbClientVersion, resource = Resource, device_info = DeviceInfo}, State) ->
    case DeviceInfo of
        undefined ->
            Device = undefined,
            OsVersion = undefined;
        #pb_device_info{} ->
            Device = DeviceInfo#pb_device_info.device,
            OsVersion = DeviceInfo#pb_device_info.os_version
    end,
    Mode = ClientMode#pb_client_mode.mode,
    ClientVersion = PbClientVersion#pb_client_version.version,
    State1 = State#{
        user => Uid,
        client_version => ClientVersion,
        resource => Resource,
        mode => Mode,
        device => Device,
        os_version => OsVersion
    },
    % if noise calls this we are authenticated
    do_process_auth_request(State1, Uid, true).


%% TODO(murali@:) cleanup this file to have only noise-auth login.
-spec process_auth_request(pb_auth_request(), state()) -> state().
process_auth_request(#pb_auth_request{uid = Uid, pwd = Pwd, client_mode = ClientMode,
        client_version = PbClientVersion, resource = Resource, device_info = DeviceInfo}, State) ->
    case DeviceInfo of
        undefined ->
            Device = undefined,
            OsVersion = undefined;
        #pb_device_info{} ->
            Device = DeviceInfo#pb_device_info.device,
            OsVersion = DeviceInfo#pb_device_info.os_version
    end,
    Mode = ClientMode#pb_client_mode.mode,
    ClientVersion = PbClientVersion#pb_client_version.version,
    State1 = State#{
        user => Uid,
        client_version => ClientVersion,
        resource => Resource,
        mode => Mode,
        device => Device,
        os_version => OsVersion
    },
    %% Check Uid and Password. TODO(murali@): simplify this even further!
    CheckPW = check_password_fun(<<>>, State1),
    PasswordResult = CheckPW(Uid, <<>>, Pwd),
    do_process_auth_request(State1, Uid, PasswordResult).

%%TODO: End of August 2021- cleanup the fields in auth_result function.
-spec do_process_auth_request(state(), uid(), boolean()) -> state().
do_process_auth_request(State1, Uid, AuthResult) ->
    ClientVersion = maps:get(client_version, State1, undefined),
    Resource = maps:get(resource, State1, undefined),
    {State3, Result, Reason, PropsHash, TimeLeftSec} = case AuthResult of
        false ->
            Reason1 = case Uid of
                undefined -> spub_mismatch;
                _ ->
                    case model_accounts:is_account_deleted(Uid) of
                        true -> account_deleted;
                        false -> invalid_uid_or_password
                    end
            end,
            {State1, failure, Reason1, undefined, 0};
        true ->
            %% Check client_version
            case mod_client_version:get_version_ttl(ClientVersion) of
                ExpiresInSec when ExpiresInSec =< 0 ->
                    {State1, failure, invalid_client_version, undefined, 0};
                ExpiresInSec ->
                    %% Bind resource callback
                    case callback(bind, Resource, State1) of
                        {ok, State2} ->
                            ServerPropHash = mod_props:get_hash(Uid, ClientVersion),
                            {State2,  success, ok, ServerPropHash, ExpiresInSec};
                        {error, _, State2} ->
                            {State2, failure, invalid_resource, undefined, ExpiresInSec}
                    end
            end
    end,
    AuthResultPkt = #pb_auth_result{
        result_string = util:to_binary(Result),
        reason_string = map_to_string_reason(Reason),
        props_hash = PropsHash,
        version_ttl = TimeLeftSec,
        result = Result,
        reason = Reason
    },
    CombinedResult = case Result of
        failure -> {false, Reason};
        success -> true
    end,
    State4 = callback(handle_auth_result, Uid, CombinedResult, AuthResultPkt, State3),
    case Result of
        failure ->
            State5 = check_authservice_and_send(State4, AuthResultPkt),
            stop(State5);
        success ->
            State5 = send_pkt(State4, AuthResultPkt),
            State5
    end.

-spec map_to_string_reason(Reason :: atom()) -> string().
map_to_string_reason(Reason) -> 
    case Reason of
        account_deleted -> "account deleted";
        invalid_uid_or_password -> "invalid uid or password";
        spub_mismatch -> "spub_mismatch";
        invalid_client_version -> "invalid client version";
        invalid_resource -> "invalid resource";
        ok -> "welcome to halloapp"
    end.

-spec check_authservice_and_send(State :: state(), AuthResultPkt :: pb_auth_result()) -> state().
check_authservice_and_send(State, AuthResultPkt) ->
    case mod_auth_monitor:is_auth_service_normal() of
        true -> send_pkt(State, AuthResultPkt);
        false -> State
    end.


-spec process_stream_established(state()) -> state().
process_stream_established(#{stream_state := StateName} = State)
  when StateName == disconnected; StateName == established ->
    State;
process_stream_established(State) ->
    State1 = State#{stream_authenticated => true,
            stream_state => established,
            stream_timeout => infinity},
    try callback(handle_stream_established, State1)
    catch _:{?MODULE, undef} -> State1
    end.


-spec check_password_fun(xmpp_sasl:mechanism(), state()) -> fun().
check_password_fun(Mech, State) ->
    try callback(check_password_fun, Mech, State)
    catch _:{?MODULE, undef} -> fun(_, _, _) -> {false, undefined} end
    end.


-spec set_from_to(stanza(), state()) -> {ok, stanza()}.
%% TODO(murali@): cleanup these functions.
set_from_to(Pkt, #{user := U} = _State) ->
    case pb:is_pb_packet(Pkt) of
        true ->
            {ok, pb:set_from(Pkt, U)};
        false ->
            {ok, Pkt}
    end.


-spec send_pkt(state(), stanza()) -> state().
send_pkt(State, PktToSend) ->
    Pkt = case PktToSend of
        #pb_auth_result{} -> PktToSend;
        _ -> #pb_packet{stanza = PktToSend}
    end,
    {BinPkt1, Result} = case encode_packet(State, Pkt) of
        {ok, BinPkt} ->
            {BinPkt, socket_send(State, BinPkt)};
        {error, _} = Err ->
            ?ERROR("failed to encode packet ~p, error ~p", [Pkt, Err]),
            {<<>>, Err}
    end,
    State1 = case Result of
        {ok, noise, SocketData} ->
            State#{socket => SocketData};
        {ok, fast_tls} ->
            State;
        {ok, gen_tcp} ->
            State;
        {error, _} ->
            State
    end,
    % TODO: nikola: add to this callback the BinPkt
    State2 = try callback(handle_send, BinPkt1, Pkt, Result, State1)
        catch _:{?MODULE, undef} -> State1
    end,
    case Result of
        _ when is_record(PktToSend, pb_ha_error) ->
            process_stream_end({stream, {out, Pkt}}, State2);
        ok ->
            State2;
        {ok, noise, _} ->
            State2;
        {ok, fast_tls} ->
            State2;
        {ok, none} ->
            State2;
        {error, _Why} ->
            % Queue process_stream_end instead of calling it directly,
            % so we have opportunity to process incoming queued messages before
            % terminating session.
            self() ! {'$gen_event', closed},
            State2
    end.


%% TODO(murali@): maybe switch error to be an atom!
-spec send_error(state(), stanza(), atom()) -> state().
send_error(State, _Pkt, Err) ->
    send_error(State, Err).


send_error(#{user := Uid} = State, Err) ->
    ErrBin = util:to_binary(Err),
    ErrStr = util:to_list(Err),
    IsDev = dev_users:is_dev_uid(Uid),
    stat:count("HA/connection", "errors", 1, [{"type", ErrStr}]),
    case Err of
        _ when Err =:= shutdown; Err =:= replaced ->
            ?INFO("Sending ~p and stoping", [Err]);
        _ when Err =:= session_kicked; Err =:= session_replaced ->
            NoiseCheckerUid = mod_noise_checker:get_uid(),
            case NoiseCheckerUid =:= Uid of
                true -> ok;  % don't log anything for noise checker uid
                false -> ?WARNING("Sending: ~p to Uid: ~p, IsDev: ~p and stopping", [Err, Uid, IsDev])
            end;
        noise_error ->
            %% noise_error is always from spam usually.
            ?INFO("Sending ~p and stoping", [Err]);
        _ ->
            ?ERROR("Sending ~p and stopping", [Err])
    end,
    ErrorStanza = #pb_ha_error{reason = ErrBin},
    ErrorPacket = #pb_packet{stanza = ErrorStanza},
    {ok, BinPkt} = encode_packet(State, ErrorPacket),
    socket_send(State, BinPkt),
    process_stream_end(Err, State).


-spec socket_send(state(), binary()) ->
        {ok, noise, halloapp_socket:socket()} | {ok, fast_tls} | {ok, gen_tcp} | {error, inet:posix()}.
socket_send(#{socket := Sock, stream_state := StateName}, BinPkt) ->
    case BinPkt of
        _ when StateName /= disconnected ->
            halloapp_socket:send(Sock, BinPkt);
        _ ->
            {error, closed}
    end;
socket_send(_, _) ->
    {error, closed}.


-spec encode_packet(SocketState :: socket_state(), Pkt :: pb_packet())
            -> {ok, binary()} | {error, pb_encode_error}.
encode_packet(#{socket := #socket_state{socket_type = SocketType, sockmod = _SockMod}}, Pkt) ->
    case enif_protobuf:encode(Pkt) of
        {error, Reason} ->
            stat:count("HA/pb_packet", "encode_failure", 1, [{socket_type, SocketType}]),
            ?ERROR("Error encoding packet: ~p, reason: ~p", [Pkt, Reason]),
            {error, pb_encode_error};
        FinalPkt ->
            stat:count("HA/pb_packet", "encode_success", 1, [{socket_type, SocketType}]),
            {ok, FinalPkt}
    end.


-spec close_socket(state()) -> state().
close_socket(#{socket := Socket} = State) ->
    halloapp_socket:close(Socket),
    State#{stream_timeout => infinity, stream_state => disconnected}.


-spec format_inet_error(atom()) -> string().
format_inet_error(closed) ->
    "connection closed";
format_inet_error(Reason) ->
    case inet:format_error(Reason) of
    "unknown POSIX error" -> atom_to_list(Reason);
    Txt -> Txt
    end.


-spec format_tls_error(atom() | binary()) -> list().
format_tls_error(Reason) when is_atom(Reason) ->
    format_inet_error(Reason);
format_tls_error(Reason) ->
    Reason.


-spec format(io:format(), list()) -> binary().
format(Fmt, Args) ->
    iolist_to_binary(io_lib:format(Fmt, Args)).


-spec get_socket_type(state()) -> maybe(socket_type()).
get_socket_type(#{socket := Socket}) ->
    SocketType = Socket#socket_state.socket_type,
    SocketType.


%%%===================================================================
%%% Callbacks
%%%===================================================================


callback(F, #{mod := Mod} = State) ->
    case erlang:function_exported(Mod, F, 1) of
        true -> Mod:F(State);
        false -> erlang:error({?MODULE, undef})
    end.


callback(F, Arg1, #{mod := Mod} = State) ->
    case erlang:function_exported(Mod, F, 2) of
        true -> Mod:F(Arg1, State);
        false -> erlang:error({?MODULE, undef})
    end.


callback(code_change, OldVsn, #{mod := Mod} = State, Extra) ->
    %% code_change/3 callback is a special snowflake
    case erlang:function_exported(Mod, code_change, 3) of
        true -> Mod:code_change(OldVsn, State, Extra);
        false -> {ok, State}
    end;


callback(F, Arg1, Arg2, #{mod := Mod} = State) ->
    case erlang:function_exported(Mod, F, 3) of
        true -> Mod:F(Arg1, Arg2, State);
        false -> erlang:error({?MODULE, undef})
    end.


callback(F, Arg1, Arg2, Arg3, #{mod := Mod} = State) ->
    case erlang:function_exported(Mod, F, 4) of
        true -> Mod:F(Arg1, Arg2, Arg3, State);
        false -> erlang:error({?MODULE, undef})
    end.

