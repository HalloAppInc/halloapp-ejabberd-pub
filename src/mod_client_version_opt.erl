%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_client_version_opt).

-export([max_days/1]).

-spec max_days(gen_mod:opts() | global | binary()) -> 'infinity' | pos_integer().
max_days(Opts) when is_map(Opts) ->
    gen_mod:get_opt(max_days, Opts);
max_days(Host) ->
    gen_mod:get_module_opt(Host, mod_client_version, max_days).

