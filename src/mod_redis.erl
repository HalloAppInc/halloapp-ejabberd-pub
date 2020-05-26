%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 25. Mar 2020 1:57 PM
%%%-------------------------------------------------------------------
-module(mod_redis).
-author("nikola").
-behaviour(gen_mod).

-include("logger.hrl").
-include("eredis_cluster.hrl").

-define(REVERSE_REDIS_SLOT_MAP_FILE, "reverse_redis_slot_map.data").
%% ets table slot -> key
-define(SLOT_TO_KEY, slot_to_key).

%% gen_mod API callbacks
-export([
    start/2,
    stop/1,
    depends/2,
    mod_options/1,
    get_slot_key/1
]).

start(_Host, _Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    load_reverse_redis_hash(),
    redis_sup:start_link(),
    ok.

stop(_Host) ->
  ?INFO_MSG("stop ~w", [?MODULE]),
  ok.

depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [].


-spec get_slot_key(Slot :: non_neg_integer()) -> binary().
get_slot_key(Slot) when is_integer(Slot) andalso Slot >= 0 andalso Slot =< ?REDIS_CLUSTER_HASH_SLOTS ->
    Value = ets:lookup_element(?SLOT_TO_KEY, Slot, 2),
    Value.


-spec get_file_path() -> file:filename_all().
get_file_path() ->
    FileName = filename:join(misc:data_dir(), ?REVERSE_REDIS_SLOT_MAP_FILE),
    case config:is_testing_env() of
        true ->
            % unit tests run in .eunit folder
            filename:join("../", FileName);
        false ->
            FileName
    end.


-spec create_slot_to_key_table() -> ok.
create_slot_to_key_table() ->
    case ets:info(?SLOT_TO_KEY) of
        undefined ->
            ets:new(?SLOT_TO_KEY, [
                named_table,
                {read_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end.


-spec load_reverse_redis_hash() -> ok.
load_reverse_redis_hash() ->
    FileName = get_file_path(),
    {ok, Bin} = file:read_file(FileName),
    SlotToKeyMap = binary_to_term(Bin),
    create_slot_to_key_table(),
    maps:fold(
        fun (Slot, Key, _AccIn) ->
            ets:insert(?SLOT_TO_KEY, {Slot, integer_to_binary(Key)})
        end,
        true,
        SlotToKeyMap),
    Info = ets:info(?SLOT_TO_KEY),
    Memory = lists:keyfind(memory, 1, Info),
    Size = lists:keyfind(size, 1, Info),
    ?INFO_MSG("finished building slot_to_key map ~p ~p", [Memory, Size]).

