%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_whisper_opt).

-export([min_otp_key_count/1]).

-spec min_otp_key_count(gen_mod:opts() | global | binary()) -> 'infinity' | pos_integer().
min_otp_key_count(Opts) when is_map(Opts) ->
    gen_mod:get_opt(min_otp_key_count, Opts);
min_otp_key_count(Host) ->
    gen_mod:get_module_opt(Host, mod_whisper, min_otp_key_count).

