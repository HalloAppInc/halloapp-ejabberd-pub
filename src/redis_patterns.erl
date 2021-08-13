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


%% API
-export([
    process_keys/2,
    process_scan/1
]).


% Updates key counter map for respective key pattern (complete list in redis_keys)
-spec process_keys(Key :: binary(), State :: map()) -> map().
process_keys(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    RedisService = maps:get(service, State),
    Client = ha_redis:get_client(RedisService),
    {ok, MemUsage} = ecredis:q(Client, ["MEMORY", "USAGE", Key]),
    case MemUsage of
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
            Map = maps:get(counters_map, State, #{}),
            NewMap = maps:update_with(KeyPrefix, Increment, [1, util:to_integer(MemUsage)], Map),
            State1 = State#{
                counters_map => NewMap
            },
            State1
    end.


% Displays key count stats by number, memory (bytes), and percentage
-spec process_scan(State :: map()) -> ok.
process_scan(State) ->
    Map = maps:get(counters_map, State, #{}),
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

