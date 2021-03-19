%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 24. Feb 2021 1:29 PM
%%%-------------------------------------------------------------------
-module(ha_redis).
-author("nikola").

%% API
-export([
    start/0,
    get_slot_key/1,
    get_client/1
]).

-include("logger.hrl").
-include("crc16_redis.hrl").

-define(REVERSE_REDIS_SLOT_MAP_FILE, "reverse_redis_slot_map.data").
%% ets table slot -> key
-define(SLOT_TO_KEY, slot_to_key).

start() ->
    ?INFO("start"),
    load_reverse_redis_hash(),
    %% start supervisor for redis.
    redis_sup:start_link(),
    ?INFO("start done"),
    ok.

-spec get_slot_key(Slot :: non_neg_integer()) -> binary().
get_slot_key(Slot) when is_integer(Slot) andalso Slot >= 0 andalso Slot =< ?REDIS_CLUSTER_HASH_SLOTS ->
    Value = ets:lookup_element(?SLOT_TO_KEY, Slot, 2),
    Value.

%% used only in migration modules
%% example of a service is redis_accounts, corresponding client
%% would be ecredis_accounts
get_client(Service) ->
    list_to_atom("ec" ++ atom_to_list(Service)).



-spec get_file_path() -> file:filename_all().
get_file_path() ->
    filename:join(misc:data_dir(), ?REVERSE_REDIS_SLOT_MAP_FILE).


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
    ?INFO("finished building slot_to_key map ~p ~p", [Memory, Size]).

