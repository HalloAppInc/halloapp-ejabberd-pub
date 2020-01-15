%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_cron_opt).

-export([tasks/1]).

-spec tasks(gen_mod:opts() | global | binary()) -> any().
tasks(Opts) when is_map(Opts) ->
    gen_mod:get_opt(tasks, Opts);
tasks(Host) ->
    gen_mod:get_module_opt(Host, mod_cron, tasks).

