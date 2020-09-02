-module(escript_certificate_verification).

%%! -pa deps/enacl/ebin -pa ebin -pa deps/enif_protobuf/ebin/

-export([main/1]).

-include_lib("../include/proto/cert.hrl").

%%% Usage:
%%% escript escripts/escript_certificate_verification.erl CertFileName ServerKeyFileName
%%% 
%%% Example:
%%% escript escripts/escript_certificate_verification.erl cert.pem signing_public.pem
%%%


main([CertFileName, ServerKeyFileName]) ->
    enif_protobuf:load_cache(cert:get_msg_defs()),
    %% signing key
    {ok, CertBin} = file:read_file(CertFileName),
    [{_, Cert, _}] = public_key:pem_decode(CertBin),

    %% server's key
    {ok, SigningBin} = file:read_file(ServerKeyFileName),
    [{_, SigningPublic, _}] = public_key:pem_decode(SigningBin),

    {ok, SignedMessage} = enacl:sign_open(Cert, SigningPublic),
    PbCert = enif_protobuf:decode(SignedMessage, pb_cert_message),
    io:format("Timestamp: ~p, ServerPublicKey: ~p~n", 
              [PbCert#pb_cert_message.timestamp, base64:encode(PbCert#pb_cert_message.server_key)]).


