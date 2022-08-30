%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 06. Aug 2021
%%%-------------------------------------------------------------------
-module(redis_patterns).
-author("michelle").

-include("logger.hrl").

-define(MAX_KEY_COUNT, 2000).

%% API
-export([
    process_keys/2,
    process_scan/1
]).


% Updates key counter map for respective key pattern (complete list in redis_keys)
-spec process_keys(Key :: binary(), State :: map()) -> {ok | stop, map()}.
process_keys(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    NumProcessedKeys = maps:get(num_processed_keys, State, 0),
    RedisService = maps:get(service, State),
    Client = ha_redis:get_client(RedisService),
    {ok, MemUsage} = ecredis:q(Client, ["MEMORY", "USAGE", Key]),
    State1 = case MemUsage of
        undefined ->
            ?ERROR("Key: ~p with invalid memory usage: ~p", [Key, MemUsage]),
            State;
        _ ->
            ?INFO("Key: ~p with valid memory usage: ~p", [Key, MemUsage]),
            [KeyPrefix | _T] = string:split(Key, ":"),
            Increment = fun(X) ->
                [NumCount, MemCount] = X,
                [NumCount + 1, MemCount + util:to_integer(MemUsage)]
            end,
            Map = maps:get(counters, State, #{}),
            NewMap = maps:update_with(KeyPrefix, Increment, [1, util:to_integer(MemUsage)], Map),
            State#{
                counters => NewMap
            }
    end,
    FinalNumProcessedKeys = NumProcessedKeys + 1,
    State2 = State1#{num_processed_keys => FinalNumProcessedKeys},
    case FinalNumProcessedKeys > ?MAX_KEY_COUNT of
        true -> {stop, State2};
        false -> {ok, State2}
    end.


% Displays key count stats by number, memory (bytes), and percentage
-spec process_scan(Map :: map()) -> ok.
process_scan(Map) ->
    [TotalKeys, TotalMem] = maps:fold(
        fun(_Key, Value, Sum) ->
            [Num, Mem] = Value,
            [NumCount, MemCount] = Sum,
            [Num + NumCount, Mem + MemCount]
        end, [0, 0], Map),
    case TotalKeys of
        0 -> 
            ok;
        _ ->
            Heading = "\nKey  ||  #  ||    # %   ||     Mem     ||  Mem %  \n",
            Stats = maps:fold(
                fun(Key, Value, Acc) ->
                    [Num, Mem] = Value,
                    NumPercent = io_lib:format("~*.*.0f%",[5, 2, (Num/TotalKeys) * 100]),
                    NumStat = [util:to_list(Num), NumPercent],
                    MemPercent = io_lib:format("~*.*.0f%",[5, 2, (Mem/TotalMem) * 100]),
                    MemStat = [util:to_list(Mem) ++ " bytes", MemPercent],
                    CurrStat = string:join([util:to_list(Key)] ++ NumStat ++ MemStat, "  ||  "),
                    Acc ++ CurrStat ++ "\n"
                end, Heading, Map),
            NumSummary = "Keys Processed: " ++ util:to_list(TotalKeys),
            MemSummary = "\nMem (in bytes): " ++ util:to_list(TotalMem),
            ?INFO("~s~s~s", [Stats, NumSummary, MemSummary]),
            ok
    end.

