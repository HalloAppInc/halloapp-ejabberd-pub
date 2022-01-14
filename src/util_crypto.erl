%%%----------------------------------------------------------------------
%%% File    : util_crypto.erl
%%%
%%% Copyright (C) 2022 halloappinc.
%%%
%%% Implements util functions for Crypto related operations.
%%%----------------------------------------------------------------------

-module(util_crypto).
-author('vipin').

-include("logger.hrl").
-include("time.hrl").
-include("util_crypto.hrl").

-export([
    decrypt_blob/3,
    encrypt_blob/3
]).

%% pkcs padding expected in the encrypted blob.
-spec decrypt_blob(EncBlob :: binary(), Key :: binary(), HkdfInfo :: binary())
        -> {ok, binary()} | {error, any()}.
decrypt_blob(EncBlobWithMac, _Key, _HkdfInfo) when byte_size(EncBlobWithMac) < ?HMAC_LENGTH_BYTES ->
    {error, invalid_blob_size};
decrypt_blob(EncBlobWithMac, Key, HkdfInfo) ->
    try
        Secret = hkdf:derive_secrets(sha256, Key, HkdfInfo, ?HKDF_SECRET_SIZE),
        <<IV:?IV_LENGTH_BYTES/binary, AESKey:?AESKEY_LENGTH_BYTES/binary,
            HMACKey:?HMACKEY_LENGTH_BYTES/binary>> = Secret,
        EncBlobSize = byte_size(EncBlobWithMac) - ?HMAC_LENGTH_BYTES,
        <<EncBlob:EncBlobSize/binary, Mac/binary>> = EncBlobWithMac,
        Blob = crypto:crypto_one_time(aes_256_cbc, AESKey, IV, EncBlob,
                [{encrypt, false}, {padding, pkcs_padding}]),
        ComputedMac = crypto:mac(hmac, sha256, HMACKey, EncBlob),
        case Mac =:= ComputedMac of
            true -> {ok, Blob};
            false -> {error, mac_mismatch}
        end
    catch
        error : Reason : Stacktrace ->
            ?INFO("error: Stacktrace: ~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            {error, Reason}
    end.

%% pkcs padding done in the sent in plain text.
-spec encrypt_blob(PlainText :: binary(), KeySize :: integer(), HkdfInfo :: binary())
        -> {ok, binary(), binary()} | {error, any()}.
encrypt_blob(_PlainText, KeySize, _HkdfInfo) when KeySize =< 0 ->
    {error, invalid_key_size};
encrypt_blob(PlainText, KeySize, HkdfInfo) ->
    try
        Key = crypto:strong_rand_bytes(KeySize),
        <<IV:?IV_LENGTH_BYTES/binary, AESKey:?AESKEY_LENGTH_BYTES/binary,
        HMACKey:?HMACKEY_LENGTH_BYTES/binary>> =
            hkdf:derive_secrets(sha256, Key, HkdfInfo, ?HKDF_SECRET_SIZE),
        CipherText = crypto:crypto_one_time(aes_256_cbc, AESKey, IV, PlainText,
                [{encrypt, true}, {padding, pkcs_padding}]),
        Mac = crypto:mac(hmac, sha256, HMACKey, CipherText),
        EncBlob = <<CipherText/binary, Mac/binary>>,
        {ok, Key, EncBlob}
    catch
        error : Reason : Stacktrace ->
            ?INFO("error: Stacktrace: ~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            {error, Reason}
    end.

