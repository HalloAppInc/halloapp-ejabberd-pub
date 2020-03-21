%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(mod_ack_opt).

-export([max_ack_wait_items/1]).
-export([max_retry_count/1]).
-export([packet_timeout_sec/1]).

-spec max_ack_wait_items(gen_mod:opts() | global | binary()) -> 'infinity' | pos_integer().
max_ack_wait_items(Opts) when is_map(Opts) ->
    gen_mod:get_opt(max_ack_wait_items, Opts);
max_ack_wait_items(Host) ->
    gen_mod:get_module_opt(Host, mod_ack, max_ack_wait_items).

-spec max_retry_count(gen_mod:opts() | global | binary()) -> 'infinity' | pos_integer().
max_retry_count(Opts) when is_map(Opts) ->
    gen_mod:get_opt(max_retry_count, Opts);
max_retry_count(Host) ->
    gen_mod:get_module_opt(Host, mod_ack, max_retry_count).

-spec packet_timeout_sec(gen_mod:opts() | global | binary()) -> 'infinity' | pos_integer().
packet_timeout_sec(Opts) when is_map(Opts) ->
    gen_mod:get_opt(packet_timeout_sec, Opts);
packet_timeout_sec(Host) ->
    gen_mod:get_module_opt(Host, mod_ack, packet_timeout_sec).

