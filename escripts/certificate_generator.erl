-module(certificate_generator).

%%! -pa deps/enacl/ebin -pa ebin -pa deps/enif_protobuf/ebin/


-export([main/1]).

-include_lib("../include/proto/cert.hrl").

%%% Usage:
%%% escript escripts/certificate_generator.erl SigningKeyFilename ServerKeyFilename CertFilename
%%% 
%%% Example:
%%% escript escripts/certificate_generator.erl signing_secret.pem server_public.pem cert.pem
%%%
%%% Example certificate:
%%% -----BEGIN CERTIFICATE-----
%%% 8E4yYnSRtyly3n5HtoTcC7edrrcuTOBo7a0Wq80G1MQ75Nw+TtUaGn1BMGB2Uv6M
%%% q+3yJr2cnCE9PfqdDpVKD18/9+vTZK4hqr1c/qFvoBGFEsmYaGqhGxHKB9XrPn7D
%%% M65MLw==
%%% -----END CERTIFICATE-----

create_cert_bytes(ServerPublic) ->
    PbCert = #pb_cert_message{
        timestamp = erlang:system_time(second),
        server_key = ServerPublic
    },
    enif_protobuf:encode(PbCert).


main([SigningKeyFileName, ServerKeyFileName, OutFileName]) ->
    enif_protobuf:load_cache(cert:get_msg_defs()),
    %% signing key
    {ok, SignBin} = file:read_file(SigningKeyFileName),
    [{_, SignSecret, _}] = public_key:pem_decode(SignBin),

    %% server's key
    {ok, ServerBin} = file:read_file(ServerKeyFileName),
    [{_, ServerPublic, _}] = public_key:pem_decode(ServerBin),

    MessageToSign = create_cert_bytes(ServerPublic),

    Certificate = enacl:sign(MessageToSign, SignSecret),
    io:format("Cert: ~p, size: ~p~n", [base64:encode(Certificate), byte_size(Certificate)]),
    file:write_file(OutFileName,
                    public_key:pem_encode([{'Certificate', Certificate, not_encrypted}])).


