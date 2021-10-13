%%%----------------------------------------------------------------------
%%% Records for whisper_keys and whisper_otp_keys.
%%%
%%%----------------------------------------------------------------------
-ifndef(WHISPER_HRL).
-define(WHISPER_HRL, 1).

-define(MAX_KEY_SIZE, 512).
-define(MIN_KEY_SIZE, 32).
-define(MAX_OTK_LENGTH, 256).
-define(MIN_OTK_LENGTH, 10).

-define(TRUNC_IKEY_LENGTH, 4).

-record(user_whisper_key_set, {
    uid :: binary(),
    identity_key :: binary(),
    signed_key :: binary(),
    one_time_key :: binary()
}).

-type user_whisper_key_set() :: #user_whisper_key_set{}.

-endif.
