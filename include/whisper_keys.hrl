%% -*- coding: utf-8 -*-
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.13.0

-ifndef(whisper_keys).
-define(whisper_keys, true).

-define(whisper_keys_gpb_version, "4.13.0").

-ifndef('PB_WHISPER_KEYS_PB_H').
-define('PB_WHISPER_KEYS_PB_H', true).
-record(pb_whisper_keys,
        {uid = 0                :: integer() | undefined, % = 1, 64 bits
         action = normal        :: normal | add | count | get | set | update | integer() | undefined, % = 2, enum pb_whisper_keys.Action
         identity_key = <<>>    :: iodata() | undefined, % = 3
         signed_key = <<>>      :: iodata() | undefined, % = 4
         otp_key_count = 0      :: integer() | undefined, % = 5, 32 bits
         one_time_keys = []     :: [iodata()] | undefined % = 6
        }).
-endif.

-endif.
