%%%----------------------------------------------------------------------
%%% Records for whisper_keys and whisper_otp_keys.
%%%
%%%----------------------------------------------------------------------

-record(user_whisper_key_set, {
    uid :: binary(),
    identity_key :: binary(),
    signed_key :: binary(),
    one_time_key :: binary()
}).

-type user_whisper_key_set() :: #user_whisper_key_set{}.

