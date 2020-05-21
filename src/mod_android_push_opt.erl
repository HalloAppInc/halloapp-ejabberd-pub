%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_android_push_opt).

-export([fcm/1]).

-spec fcm(gen_mod:opts() | global | binary()) -> [{atom(),binary() | integer()}].
fcm(Opts) when is_map(Opts) ->
    gen_mod:get_opt(fcm, Opts);
fcm(Host) ->
    gen_mod:get_module_opt(Host, mod_android_push, fcm).

