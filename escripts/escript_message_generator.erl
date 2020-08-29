-module(escript_message_generator).

%%! -pa deps/enacl/ebin -pa ebin -pa deps/enif_protobuf/ebin/


-export([main/1]).

-include_lib("../include/proto/cert.hrl").

%%% Usage:
%%% escript escripts/escript_message_generator.erl ServerKeyFilename MessageFilename
%%% 
%%% Example:
%%% escript escripts/escript_message_generator.erl server_public.pem message
%%%
%%% Example message in hex format with 40 bytes (32 bytes for public key, 8 bytes for timestamp)
%%% 08B5BCA6FA051A20DDA895955992738B9532F5E81940501DBAC9DA1A86EF725DFEEF49E41358E650

create_cert_bytes(ServerPublic) ->
    PbCert = #pb_cert_message{
        ts = erlang:system_time(second),
        server_key = ServerPublic
    },
    enif_protobuf:encode(PbCert).

main([ServerKeyFileName, OutFileName]) ->
    enif_protobuf:load_cache(cert:get_msg_defs()),
    %% server's key
    {ok, ServerBin} = file:read_file(ServerKeyFileName),
    [{_, ServerPublic, _}] = public_key:pem_decode(ServerBin),

    MessageToSign = create_cert_bytes(ServerPublic),
    HexMessage = hex:bin_to_hexstr(MessageToSign),
    io:format("Message: ~p, size: ~p~n", [HexMessage, byte_size(MessageToSign)]),
    file:write_file(OutFileName, HexMessage).


