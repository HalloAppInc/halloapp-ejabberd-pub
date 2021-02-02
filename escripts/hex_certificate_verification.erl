-module(hex_certificate_verification).

%%! -pa deps/enacl/ebin -pa ebin -pa deps/enif_protobuf/ebin/

-export([main/1]).

-include_lib("../include/proto/server.hrl").

%%% Usage:
%%% escript escripts/hex_certificate_verification.erl CertFileName ServerKeyFileName
%%% 
%%% Example:
%%% escript escripts/hex_certificate_verification.erl prod_message.txt.signed root.pub
%%%


main([CertFileName, ServerKeyFileName]) ->
    enif_protobuf:load_cache(server:get_msg_defs()),
    %% signing key
    {ok, CertBin} = file:read_file(CertFileName),
    Cert = hex:hexstr_to_bin(binary_to_list(CertBin)),
    io:format("Cert: ~p\n", [Cert]),

    %% server's key
    {ok, SigningBin} = file:read_file(ServerKeyFileName),
    SigningPublic = hex:hexstr_to_bin(binary_to_list(SigningBin)),
    io:format("Signing: ~p\n", [SigningPublic]),

    SignOpenResult = enacl:sign_open(Cert, SigningPublic),
    {ok, SignedMessage} = enacl:sign_open(Cert, SigningPublic),
    io:format("Signed: ~p\n", [SignOpenResult]),
    PbCert = enif_protobuf:decode(SignedMessage, pb_cert_message),
    io:format("Timestamp: ~p, ServerPublicKey: ~p~n", 
              [PbCert#pb_cert_message.timestamp, base64:encode(PbCert#pb_cert_message.server_key)]).


