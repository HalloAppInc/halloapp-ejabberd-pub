%%%-------------------------------------------------------------------
%%% File    : halloapp_register.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-------------------------------------------------------------------

-module(halloapp_register).
-author('murali').
-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).
-behaviour(ejabberd_listener).


%% ejabberd_listener callbacks
-export([start/3, start_link/3, accept/1, listen_opt_type/1, listen_options/0]).

%% p1_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("time.hrl").
-include("packets.hrl").
-include("logger.hrl").
-include("ha_types.hrl").
-include("socket_state.hrl").

-type stanza() :: term().
-type stop_reason() :: atom().
-type noreply() :: {noreply, state(), timeout()}.
-type next_state() :: noreply() | {stop, term(), state()}.
-type state() :: #{}.
-export_type([state/0]).

%% If the client is idle for longer than 2 minutes: we terminate the connection.
-define(STREAM_TIMEOUT_MS, 2 * ?MINUTES_MS).

%% API
-export([
    close/1,
    close/2,
    stop/1,
    send/2
]).



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%                       ejabberd_listener callbacks                            %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(SockMod, Socket, Opts) ->
    ?GEN_SERVER:start(?MODULE, [?MODULE, {SockMod, Socket}, Opts], Opts).

start_link(SockMod, Socket, Opts) ->
    ?GEN_SERVER:start_link(?MODULE, [?MODULE, {SockMod, Socket}, Opts], Opts).

accept(Pid) when is_pid(Pid) ->
    cast(Pid, accept).

listen_opt_type(crypto) ->
    econf:enum([noise]).

listen_options() ->
    %% default options.
    [
        {access, all},
        {shaper, none},
        {max_stanza_size, infinity},
        {crypto, noise}
    ].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%                           halloapp_register api                              %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec close(pid()) -> ok;
        (state()) -> state().
close(#{owner := Owner} = State) when Owner =:= self() ->
    close_socket(State);
close(Pid)  when is_pid(Pid) ->
    close(Pid, closed).


-spec close(pid(), atom()) -> ok;
        (state(), atom()) -> state().
close(Pid, Reason) when is_pid(Pid) ->
    cast(Pid, {close, Reason});
close(#{owner := Owner} = State, Reason) when Owner =:= self() ->
    process_stream_end(Reason, State);
close(_, _) ->
    erlang:error(badarg).


-spec stop(pid()) -> ok;
        (state()) -> state().
stop(Pid) when is_pid(Pid) ->
    cast(Pid, stop);
stop(#{owner := Owner} = State) when Owner =:= self() ->
    handle_cast(stop, State);
stop(_) ->
    erlang:error(badarg).


-spec send(pid(), stanza()) -> ok;
        (state(), stanza()) -> state().
% send(Pid, Pkt) when is_pid(Pid) ->
%     cast(Pid, {send, Pkt});
send(#{owner := Owner} = State, Pkt) when Owner =:= self() ->
    send_pkt(State, Pkt);
send(_, _) ->
    erlang:error(badarg).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%                            p1_server callbacks                               %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([Mod, {SockMod, Socket}, Opts]) ->
    Access = proplists:get_value(access, Opts, all),
    Shaper = proplists:get_value(shaper, Opts, none),
    Crypto = proplists:get_value(crypto, Opts, noise),
    TimeoutMs = ?STREAM_TIMEOUT_MS,
    State1 = #{
        owner => self(),
        mod => Mod,
        socket => Socket,
        sockmod => SockMod,
        socket_opts => Opts,
        stream_state => accepting,
        access => Access,
        shaper => Shaper,
        crypto => Crypto,
        socket_type => Crypto,
        server => util:get_host(),
        stream_timeout_ms => TimeoutMs
    },
    State2 = case Crypto of
        noise ->
            {ServerKeypair, Certificate} = util:get_noise_key_material(),
            NoiseOpts = [{noise_static_key, ServerKeypair}, {noise_server_certificate, Certificate}],
            State1#{noise_options => NoiseOpts};
        _ ->
            {stop, invalid_crypto}
    end,
    ?DEBUG("halloapp_register state: ~p", [State2]),
    {ok, State2, TimeoutMs}.


-spec handle_cast(term(), state()) -> next_state().
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast({close, Reason}, State) ->
    noreply(process_stream_end(Reason, State));
handle_cast({send, Pkt}, State) ->
    noreply(send_pkt(State, Pkt));
handle_cast(accept, #{socket := Socket, sockmod := SockMod,
        socket_opts := Opts, noise_options := NoiseOpts} = State) ->
    TcpSocket = halloapp_socket:new(SockMod, Socket, Opts),
    SocketMonitor = halloapp_socket:monitor(TcpSocket),
    case halloapp_socket:peername(TcpSocket) of
        {ok, {IpAddress, _Port} = _IP} ->
            State1 = maps:remove(sockmod, State),
            ?DEBUG("NoiseOpts : ~p", [NoiseOpts]),
            ClientIP = inet:ntoa(IpAddress),
            State2 = State1#{socket => TcpSocket, socket_monitor => SocketMonitor, ip => ClientIP},
            %% Note that the verifyFun is empty in this case.
            State3 = case halloapp_socket:startnoise(TcpSocket, NoiseOpts, fun (_, _) -> ok end) of
                {ok, NoiseSocket} ->
                    State2#{socket => NoiseSocket};
                {error, Reason} ->
                    ?ERROR("Failed to start noise: ~p", [Reason]),
                    process_stream_end(noise_error, State2)
            end,
            case is_disconnected(State3) of
                true -> noreply(State3);
                false -> handle_info({tcp, Socket, <<>>}, State3)
            end;
        {error, _} ->
            stop(State)
    end;
handle_cast(Cast, State) ->
    ?ERROR("unexpected cast: ~p, state: ~p", [Cast, State]),
    noreply(State).


-spec handle_call(term(), term(), state()) -> next_state().
handle_call(Call, From, State) ->
    ?ERROR("unexpected call: ~p, from: ~p, state: ~p", [Call, From, State]),
    noreply(State).


-spec code_change(term(), state(), term()) -> {ok, state()} | {error, term()}.
code_change(_OldVsn, State, _Extra) ->
    ?ERROR("unexpected code_change"),
    {ok, State}.


-spec handle_info(term(), state()) -> next_state().
handle_info({'$gen_event', closed}, State) ->
    noreply(process_stream_end(socket_closed, State));
handle_info({'$gen_event', {protobuf, <<>>}}, _State) ->
    noreply(_State);
handle_info(timeout, State) ->
    noreply(process_stream_end(idle_connection, State));
handle_info({'DOWN', MRef, _Type, _Object, Info}, #{socket_monitor := MRef} = State) ->
    ?ERROR("socket_closed: ~p", [Info]),
    noreply(process_stream_end(socket_closed, State));
handle_info({tcp_closed, _}, State) ->
    handle_info({'$gen_event', closed}, State);
handle_info({tcp_error, _, Reason}, State) ->
    ?ERROR("tcp_error: ~p", [Reason]),
    noreply(process_stream_end(socket_error, State));
handle_info({close, Reason}, State) ->
    noreply(process_stream_end(Reason, State));
handle_info({tcp, _, Data}, #{socket := Socket, ip := IP} = State) ->
    noreply(
        case halloapp_socket:recv(Socket, Data) of
            {ok, NewSocket} ->
                State#{socket => NewSocket};
            {error, einval} ->
                ?ERROR("invalid_arg Reason: ~p Data(b64): ~p, IP: ~p",
                    [einval, base64url:encode(Data), IP]),
                process_stream_end(socket_einval, State);
            {error, Reason} ->
                ?ERROR("noise_error Reason: ~p Data(b64): ~p, IP: ~p",
                    [Reason, base64url:encode(Data), IP]),
                process_stream_end(noise_error, State)
        end);
handle_info({'$gen_event', {HeaderElement, Bin}},
        #{socket := _Socket, stream_state := StreamState, socket_type := SocketType} = State) ->
    %% First packet as part of payload or any subsequent packet.
    case (HeaderElement =:= stream_validation andalso StreamState =:= accepting) orelse
        (HeaderElement =:= protobuf andalso StreamState =:= established) of
            true ->
                noreply(
                    case enif_protobuf:decode(Bin, pb_register_request) of
                        #pb_register_request{} = Pkt ->
                            stat:count("HA/pb_packet", "decode_success", 1, [{socket_type, SocketType}]),
                            ?DEBUG("recv: protobuf: ~p", [Pkt]),
                            %% Change stream state to be established for both the above cases.
                            State1 = State#{stream_state => established},
                            process_element(Pkt, State1);
                        {error, _} ->
                            ?ERROR("Failed to decode packet: ~p", [Bin]),
                            stat:count("HA/pb_packet", "decode_failure", 1, [{socket_type, SocketType}]),
                            process_stream_end(decode_error, State)
                    end);
            false ->
                noreply(State)
    end;
handle_info(Info, State) ->
    ?ERROR("unexpected info: ~p, state: ~p", [Info, State]),
    noreply(State).


-spec terminate(term(), state()) -> state().
terminate(Reason, State) ->
    ?ERROR("terminating, reason: ~p, state: ~p", [Reason, State]),
    process_stream_end(Reason, State).


%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec process_element(stanza(), state()) -> state().
process_element(#pb_register_request{request = #pb_otp_request{} = OtpRequest},
        #{ip := ClientIP} = State) ->
    stat:count("HA/registration", "request_otp_request", 1, [{protocol, "noise"}]),
    RawPhone = OtpRequest#pb_otp_request.phone,
    MethodBin = util:to_binary(OtpRequest#pb_otp_request.method),
    LangId = OtpRequest#pb_otp_request.lang_id,
    GroupInviteToken = OtpRequest#pb_otp_request.group_invite_token,
    UserAgent = OtpRequest#pb_otp_request.user_agent,
    RequestData = #{raw_phone => RawPhone, lang_id => LangId, ua => UserAgent, method => MethodBin,
        ip => ClientIP, group_invite_token => GroupInviteToken, raw_data => OtpRequest
    },
    OtpResponse = case mod_halloapp_http_api:process_otp_request(RequestData) of
        {ok, Phone, RetryAfterSecs} ->
            #pb_otp_response{
                phone = Phone,
                result = success,
                retry_after_secs = RetryAfterSecs
            };
        {error, retried_too_soon, Phone, RetryAfterSecs} ->
            #pb_otp_response{
                phone = Phone,
                result = failure,
                reason = retried_too_soon,
                retry_after_secs = RetryAfterSecs
            };
        {error, internal_server_error} ->
            #pb_otp_response{
                result = failure,
                reason = internal_server_error
            };
        {error, ip_blocked} ->
            #pb_otp_response{
                result = failure,
                reason = bad_request
            };
        {error, bad_user_agent} ->
            #pb_otp_response{
                result = failure,
                reason = bad_request
            };
        {error, Reason} ->
            #pb_otp_response{
                result = failure,
                reason = Reason
            }
    end,
    send(State, #pb_register_response{response = OtpResponse});
process_element(#pb_register_request{request = #pb_verify_otp_request{} = VerifyOtpRequest},
        #{ip := ClientIP} = State) ->
    stat:count("HA/registration", "verify_otp_request", 1, [{protocol, "noise"}]),
    RawPhone = VerifyOtpRequest#pb_verify_otp_request.phone,
    Name = VerifyOtpRequest#pb_verify_otp_request.name,
    Code = VerifyOtpRequest#pb_verify_otp_request.code,
    SEdPubB64 = base64:encode(VerifyOtpRequest#pb_verify_otp_request.static_key),
    SignedPhraseB64 = base64:encode(VerifyOtpRequest#pb_verify_otp_request.signed_phrase),
    IdentityKeyB64 = base64:encode(VerifyOtpRequest#pb_verify_otp_request.identity_key),
    SignedKeyB64 = base64:encode(VerifyOtpRequest#pb_verify_otp_request.signed_key),
    OneTimeKeysB64 = lists:map(fun base64:encode/1, VerifyOtpRequest#pb_verify_otp_request.one_time_keys),
    PushPayload = case VerifyOtpRequest#pb_verify_otp_request.push_register of
        undefined -> #{};
        #pb_push_register{push_token = #pb_push_token{} = PbPushToken, lang_id = LangId} ->
            #{
                <<"lang_id">> => LangId,
                <<"push_token">> => PbPushToken#pb_push_token.token,
                <<"push_os">> => PbPushToken#pb_push_token.os
            }
    end,
    GroupInviteToken = VerifyOtpRequest#pb_verify_otp_request.group_invite_token,
    UserAgent = VerifyOtpRequest#pb_verify_otp_request.user_agent,
    RequestData = #{
        raw_phone => RawPhone, name => Name, ua => UserAgent, code => Code,
        ip => ClientIP, group_invite_token => GroupInviteToken, s_ed_pub => SEdPubB64,
        signed_phrase => SignedPhraseB64, id_key => IdentityKeyB64, sd_key => SignedKeyB64,
        otp_keys => OneTimeKeysB64, push_payload => PushPayload, raw_data => VerifyOtpRequest
    },
    VerifyOtpResponse = case mod_halloapp_http_api:process_register_request(RequestData) of
        {ok, Result} ->
            #pb_verify_otp_response{
                uid = maps:get(uid, Result),
                phone = maps:get(phone, Result),
                name = maps:get(name, Result),
                result = success,
                group_invite_result = util:to_binary(maps:get(group_invite_result, Result, ''))
            };
        {error, internal_server_error} ->
            #pb_verify_otp_response{
                result = failure,
                reason = internal_server_error
            };
        {error, bad_user_agent} ->
            #pb_verify_otp_response{
                result = failure,
                reason = bad_request
            };
        {error, Reason} ->
            #pb_verify_otp_response{
                result = failure,
                reason = Reason
            }
    end,
    send(State, #pb_register_response{response = VerifyOtpResponse});
process_element(Pkt, State) ->
    ?ERROR("Invalid packet received: ~p", [Pkt]),
    process_stream_end(invalid_packet, State).


%% This ensures the connection is not idle for longer than TimeoutMs milliseconds.
-spec noreply(state()) -> noreply().
noreply(#{stream_timeout_ms := infinity} = State) ->
    {noreply, State, infinity};
noreply(#{stream_timeout_ms := TimeoutMs} = State) ->
    TimeoutMs2 = max(0, TimeoutMs),
    {noreply, State, TimeoutMs2}.


-spec is_disconnected(state()) -> boolean().
is_disconnected(#{stream_state := StreamState}) ->
    StreamState =:= disconnected.


-spec process_stream_end(stop_reason(), state()) -> state().
process_stream_end(Reason, #{stream_state := disconnected} = State) ->
    ?ERROR("stream already disconnected, State: ~p", [Reason, State]),
    State;
process_stream_end(Reason, State) ->
    ?INFO("closing stream, reason: ~p", [Reason]),
    State1 = close_socket(State),
    stop(State1),
    State1.


-spec close_socket(state()) -> state().
close_socket(#{socket := Socket} = State) ->
    halloapp_socket:close(Socket),
    State#{stream_state => disconnected}.


-spec send_pkt(state(), stanza()) -> state().
send_pkt(#{socket := #socket_state{socket_type = SocketType} = Socket} = State, PktToSend) ->
    case enif_protobuf:encode(PktToSend) of
        BinPkt when is_binary(BinPkt) ->
            stat:count("HA/pb_packet", "encode_success", 1, [{socket_type, SocketType}]),
            case halloapp_socket:send(Socket, BinPkt) of
                {ok, noise, SocketData} ->
                    State#{socket => SocketData};
                {error, _} = Err ->
                    ?ERROR("failed to send packet ~p, error ~p", [PktToSend, Err]),
                    process_stream_end(noise_error, State)
            end;
        {error, _} = Err ->
            stat:count("HA/pb_packet", "encode_failure", 1, [{socket_type, SocketType}]),
            ?ERROR("failed to encode packet ~p, error ~p", [PktToSend, Err]),
            process_stream_end(encode_packet_error, State)
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%                       helper functions for callbacks                         %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

cast(Pid, Msg) ->
    ?GEN_SERVER:cast(Pid, Msg).

