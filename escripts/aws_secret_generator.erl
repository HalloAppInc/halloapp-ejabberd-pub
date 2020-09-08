-module(aws_secret_generator).

%%! -pa deps/jsx/ebin -pa ebin


-export([main/1]).

-include_lib("../include/proto/cert.hrl").

%%% Usage:
%%% escript escripts/aws_secret_generator.erl ServerKeyFilename SignedMessageFileName SecretFileName
%%% 
%%% Example:
%%% escript escripts/aws_secret_generator.erl server.pem signed_message aws_secret
%%%
%%% NOTE: signed_message is in hex format
%%%

main([ServerKeyFileName, SignedMessageFileName, SecretFileName]) ->
    %% server's key
    {ok, ServerKey} = file:read_file(ServerKeyFileName),
    {ok, SignedMessageHex} = file:read_file(SignedMessageFileName),
    io:format("SignedMessageHex: ~p~n", [SignedMessageHex]),
    SignedMessage = hex:hexstr_to_bin(binary_to_list(SignedMessageHex)),
    Certificate = public_key:pem_encode([{'Certificate', SignedMessage, not_encrypted}]),
    io:format("ServerKey: ~p~nCertificate: ~p", [ServerKey, Certificate]),
    file:write_file(SecretFileName, jsx:encode([{<<"static_key">>, base64:encode(ServerKey)}, 
                                                {<<"server_certificate">>, base64:encode(Certificate)}])).


