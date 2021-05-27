%%%-------------------------------------------------------------------
%%% File: noise_handshake_util
%%%
%%% copyright (C) 2021, HalloApp Inc.
%%%
%%% this file includes some handshake util functions for a noise client.
%%% TODO(murali@): it would be nice if we could move this to ha_enoise
%%% and provide api to initialize a client.
%%%-------------------------------------------------------------------
-module(noise_handshake_util).
-author('murali').

-include_lib("stdlib/include/assert.hrl").
-include("logger.hrl").
-include("ha_types.hrl").
-include("packets.hrl").
-include("ha_enoise.hrl").

-export([
    send_data/3,
    recv_loop/1,
    read_data/2
]).


-spec send_data(NoiseSocket :: noise_socket(),
        Data :: binary(), MsgType :: atom()) -> {ok, noise_socket()} | {error, any()}.
send_data(#noise_socket{crypto = Crypto} = NoiseSocket, Data, MsgType) ->
    case enoise_hs_state:write_message(Crypto, Data) of
        {ok, Crypto1, Msg} ->
            NoiseSocket1 = NoiseSocket#noise_socket{crypto = Crypto1},
            NoiseMsg = #pb_noise_message{message_type = MsgType, content = Msg},
            NoiseData = enif_protobuf:encode(NoiseMsg),
            ?DEBUG("Sending NoiseData: ~p, size: ~p, MsgType: ~p",
                [base64:encode(NoiseData), byte_size(NoiseData), MsgType]),
            {ok, NoiseSocket2} = ha_enoise:send_with_size(NoiseSocket1, NoiseData),
            case ha_enoise:next_message(NoiseSocket2) of
                in -> {ok, NoiseSocket2};
                done -> ha_enoise:finish_hs(NoiseSocket2);
                out -> {error, handshake_step_mismatch}
            end;
        {error, _} = Err ->
            Err
    end.



-spec recv_loop(NoiseSocket :: noise_socket()) -> {ok, binary(), noise_socket()}.
recv_loop(#noise_socket{tcpsock = TcpSock, buf = Buf} = NoiseSocket) ->
    receive
        {tcp, TcpSock, Data} ->
            case ha_enoise:debuffer(Data, Buf) of
                {partial, Buf1} ->
                    ?DEBUG("partial recv"),
                    NoiseSocket1 = NoiseSocket#noise_socket{buf = Buf1},
                    recv_loop(NoiseSocket1);
                {full, Data1, Buf1} ->
                    ?DEBUG("full recv"),
                    NoiseSocket1 = NoiseSocket#noise_socket{buf = Buf1},
                    {ok, Data1, NoiseSocket1};
                {error, _} = Err ->
                    ?ERROR("error while recv"),
                    Err
             end
    end.
    

-spec read_data(NoiseSocket :: noise_socket(), Data :: binary()) -> {ok, noise_socket()}.
read_data(#noise_socket{pattern = Pattern, crypto = Crypto} = NoiseSocket, Data) ->
    try enif_protobuf:decode(Data, pb_noise_message) of
        Pkt ->
            MsgType = Pkt#pb_noise_message.message_type,
            ?DEBUG("Received MsgType: ~p, Pattern: ~p", [MsgType, Pattern]),
            ?assert(MsgType =:= xx_b),
            %% read handshake message and update state.
            case enoise_hs_state:read_message(Crypto, Pkt#pb_noise_message.content) of
                {ok, Crypto1, _Cert} ->
                    %% TODO: verify the server's certificate
                    NoiseSocket1 = NoiseSocket#noise_socket{crypto = Crypto1},
                    case ha_enoise:next_message(NoiseSocket1) of
                        out -> {ok, NoiseSocket1};
                        done -> ha_enoise:finish_hs(NoiseSocket1);
                        in -> {error, handshake_step_mismatch}
                    end;
                {error, _} = Err ->
                    ?ERROR("Error while reading"),
                    Err
            end
    catch _:_ -> {error, "failed_to_decode"}
    end.

