-module(key_generator).

%%! -pa deps/enacl/ebin deps/enoise/ebin -pa deps/ha_enoise/ebin

-export([main/1]).

%%% Usage:
%%% escript escripts/key_generator.erl gen_keypair/gen_signing_keypair KeyPairFilename SecretKeyFilename PublicKeyFilename
%%% 
%%% Example:
%%% escript escripts/key_generator.erl gen_keypair server.pem server_secret.pem server_public.pem
%%% escript escripts/key_generator.erl gen_signing_keypair server_signing_keypair.pem signing_secret.pem signing_public.pem
%%%
%%% Example dh keypair:
%%% -----BEGIN PUBLIC KEY-----
%%% 63S0beeOG9TjQNG6OI1vqTObFY8H8KH1dXNGQVAwZgM=
%%% -----END PUBLIC KEY-----
%%% 
%%% -----BEGIN PRIVATE KEY-----
%%% cEBvrIO3lNAaGe1nHt6P3XAeh00bWIcnyWzZDOKt0XI=
%%% -----END PRIVATE KEY-----
%%%
%%% Example signing keypair:
%%% -----BEGIN PUBLIC KEY-----
%%% /+v625ZnF28VhN/2m6Q/k3IqeOiYoFH9O/9J77y8vME=
%%% -----END PUBLIC KEY-----
%%% 
%%% -----BEGIN PRIVATE KEY-----
%%% 6D1dI55EwE+B8GdoAJqBOT2taOIAsuajBtL5WOqpGNj/6/rblmcXbxWE3/abpD+T
%%% cip46JigUf07/0nvvLy8wQ==
%%% -----END PRIVATE KEY-----

 
main([Action, KeyPairFileName, SecretKeyFileName, PublicKeyFileName]) ->
    KeyPair1 = case list_to_atom(Action) of
        gen_keypair ->
            {kp, dh25519, SecretPart, PubPart} = ha_enoise:generate_keypair(),
            {SecretPart, PubPart};
        gen_signing_keypair ->
            KeyPair = ha_enoise:generate_signature_keypair(),
            {maps:get(secret, KeyPair), maps:get(public, KeyPair)}
    end,
    {SecretPart1, PubPart1} = KeyPair1,
    file:write_file(KeyPairFileName,
                    public_key:pem_encode([{'SubjectPublicKeyInfo', PubPart1, not_encrypted}, 
                                           {'PrivateKeyInfo', SecretPart1, not_encrypted}])),
    file:write_file(SecretKeyFileName,
                    public_key:pem_encode([{'PrivateKeyInfo', SecretPart1, not_encrypted}])),
    file:write_file(PublicKeyFileName,
                    public_key:pem_encode([{'SubjectPublicKeyInfo', PubPart1, not_encrypted}])).


