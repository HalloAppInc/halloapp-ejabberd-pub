%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 28. May 2020 4:01 PM
%%%-------------------------------------------------------------------
-module(crc16_test).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").

simple_test() ->
    ?assert(true).

crc16_redis_test() ->
    ?assertEqual(12739, crc16_redis:crc16("123456789")).

crc16_test() ->
    ?assertEqual(47933, crc16:crc16("123456789")),
    ?assertEqual(12739, ecredis_crc16:crc16("123456789")).

ecredis_crc16_test() ->
    while(254, 0, 
        fun(X) ->
            Random = binary_to_list(util:random_str(X)),
            ?assertEqual(crc16_redis:crc16(Random), ecredis_crc16:crc16(Random))
        end).

while(N, N, _F) -> ok;
while(N, M, F) ->
    erlang:apply(F, [N]),
    while(N -1, M, F).

while(0, _F) -> ok;
while(N, F) ->
    erlang:apply(F, [N]),
    while(N -1, F).

% Here is what we got.
% crc16 200000 operations took 144 ms => 1388888 ops
% crc16_redis: 200000 operations took 891 ms => 224466 ops
crc16_perf_test() ->
    % StartTime = util:now_ms(),
    N = 2000,
    while(N,
        fun (X) ->
            crc16:crc16(integer_to_list(X) ++ integer_to_list(X))
        end),
    % EndTime = util:now_ms(),
    % T = EndTime - StartTime,
    %% ?debugFmt("crc16 ~w operations took ~w ms => ~f ops ",
    %%    [N, T, N / ((T + 1) / 1000)]),
    ok.


crc16_redis_perf_test() ->
    % StartTime = util:now_ms(),
    N = 2000,
    while(N,
        fun (X) ->
            crc16_redis:crc16(integer_to_list(X) ++ integer_to_list(X))
        end),
    % EndTime = util:now_ms(),
    % T = EndTime - StartTime,
    %% ?debugFmt("crc16_redis: ~w operations took ~w ms => ~f ops ",
    %%    [N, T, N / ((T + 1) / 1000)]),
    ok.

