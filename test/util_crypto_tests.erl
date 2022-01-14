%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, Halloapp Inc.
%%%-------------------------------------------------------------------
-module(util_crypto_tests).
-author("vipin").

-include_lib("eunit/include/eunit.hrl").
-include("util_crypto.hrl").

-define(KEY_SIZE, 40).
-define(PLAINTEXT_SIZE, 100).
-define(HKDF_INFO_SIZE, 100).

decrypt_blob_test() ->
    Key = crypto:strong_rand_bytes(random:uniform(?KEY_SIZE)),
    PlainText = crypto:strong_rand_bytes(random:uniform(?PLAINTEXT_SIZE)),
    HkdfInfo = crypto:strong_rand_bytes(random:uniform(?HKDF_INFO_SIZE)),
    <<IV:?IV_LENGTH_BYTES/binary, AESKey:?AESKEY_LENGTH_BYTES/binary,
        HMACKey:?HMACKEY_LENGTH_BYTES/binary>> =
            hkdf:derive_secrets(sha256, Key, HkdfInfo, ?HKDF_SECRET_SIZE),
    CipherText = crypto:crypto_one_time(aes_256_cbc, AESKey, IV, PlainText,
              [{encrypt, true}, {padding, pkcs_padding}]),
    Mac = crypto:mac(hmac, sha256, HMACKey, CipherText),
    EncBlob = <<CipherText/binary, Mac/binary>>,
    {ok, PlainText} = util_crypto:decrypt_blob(EncBlob, Key, HkdfInfo),
    MacSizeBits = byte_size(Mac) * 8,
    <<MacInt:MacSizeBits>> = Mac,
    BadMacInt = MacInt bxor 1,
    <<BadMac/binary>> = <<BadMacInt:MacSizeBits>>,
    BadMacBlob = <<CipherText/binary, BadMac/binary>>,
    {error, mac_mismatch} = util_crypto:decrypt_blob(BadMacBlob, Key, HkdfInfo). 

encrypt_blob_test() ->
    HkdfInfo = crypto:strong_rand_bytes(random:uniform(?HKDF_INFO_SIZE)),
    KeySize = random:uniform(?KEY_SIZE),
    PlainText = crypto:strong_rand_bytes(random:uniform(?PLAINTEXT_SIZE)),
    {error, invalid_key_size} = util_crypto:encrypt_blob(PlainText, 0, HkdfInfo),
    {ok, Key, EncBlob} = util_crypto:encrypt_blob(PlainText, KeySize, HkdfInfo),
    %% Assuming decrypt_blob is working correctly as a result of the above unit test.
    {ok, PlainText} = util_crypto:decrypt_blob(EncBlob, Key, HkdfInfo).

