%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_push_notifications_opt).

-export([apns/1]).
-export([fcm/1]).

-spec apns(gen_mod:opts() | global | binary()) -> [{atom(),binary() | integer()}].
apns(Opts) when is_map(Opts) ->
    gen_mod:get_opt(apns, Opts);
apns(Host) ->
    gen_mod:get_module_opt(Host, mod_push_notifications, apns).

-spec fcm(gen_mod:opts() | global | binary()) -> [{atom(),binary() | integer()}].
fcm(Opts) when is_map(Opts) ->
    gen_mod:get_opt(fcm, Opts);
fcm(Host) ->
    gen_mod:get_module_opt(Host, mod_push_notifications, fcm).

