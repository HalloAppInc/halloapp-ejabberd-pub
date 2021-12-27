%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%% Test Utility module
%%% @end
%%% Created : 14. Aug 2020 3:17 PM
%%%-------------------------------------------------------------------
-module(tutil).
-author("nikola").

-include("xmpp.hrl").
-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([
    setup/0,
    load_protobuf/0,
    get_result_iq_sub_el/1,
    assert_empty_result_iq/1,
    get_error_iq_sub_el/1,
    cleardb/1,
    meck_init/3,
    meck_finish/1,
    gen_keyb64/1,
    gen_otkb64/2,
    gen_otk/2,
    gen_whisper_keys/2,
    while/2,
    perf/3
]).


setup() ->
    ?assert(config:is_testing_env()).


load_protobuf() ->
    case enif_protobuf:encode({pb_avatar, <<>>, <<>>}) of
        {error, _Reason} -> enif_protobuf:load_cache(server:get_msg_defs());
        Bin when is_binary(Bin) -> ok
    end.


get_result_iq_sub_el(#iq{} = IQ) ->
    ?assertEqual(result, IQ#iq.type),
    [Res] = IQ#iq.sub_els,
    Res;
get_result_iq_sub_el(#pb_iq{} = IQ) ->
    ?assertEqual(result, IQ#pb_iq.type),
    IQ#pb_iq.payload.


assert_empty_result_iq(#iq{} = IQ) ->
    ?assertEqual(result, IQ#iq.type),
    ?assertEqual([], IQ#iq.sub_els);
assert_empty_result_iq(#pb_iq{} = IQ) ->
    ?assertEqual(result, IQ#pb_iq.type),
    ?assertEqual(undefined, IQ#pb_iq.payload).


get_error_iq_sub_el(#iq{} = IQ) ->
    ?assertEqual(error, IQ#iq.type),
    [Res] = IQ#iq.sub_els,
    Res;
get_error_iq_sub_el(#pb_iq{} = IQ) ->
    ?assertEqual(error, IQ#pb_iq.type),
    IQ#pb_iq.payload.


%% clears a given redis db - for instance, redis_contacts
cleardb(DBName) ->
    true = config:is_testing_env(),
    {_, "127.0.0.1", 30001} = config:get_service(DBName),
    RedisClient = list_to_atom("ec" ++ atom_to_list(DBName)),
    Result = ecredis:qa(RedisClient, ["DBSIZE"]),
    [{ok, BinSize} | _]  = Result,
    DbSize = binary_to_integer(BinSize),
    ?assert(DbSize < 100),

    %% TODO: figure out way to ensure flushdb is only available
    %% during tests. This is simple enough with eunit, as the TEST
    %% flag is set during compilation. But this is not the case with CT tests.

    ok = ecredis:flushdb(RedisClient).


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod, [passthrough]),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).


gen_otkb64(N, Bytes) ->
    [gen_keyb64(Bytes) || _X <- lists:seq(1, N)].

gen_otk(N, Bytes) ->
    [gen_key(Bytes) || _X <- lists:seq(1, N)].

gen_keyb64(Bytes) ->
    base64:encode(gen_key(round(math:ceil(Bytes * 3 / 4)))).

gen_key(Bytes) ->
    crypto:strong_rand_bytes(Bytes).

gen_whisper_keys(N, Bytes) ->
    PbIK = #pb_identity_key{
        public_key = gen_key(round(math:ceil(Bytes * 3 / 4)))
    },
    {base64:encode(enif_protobuf:encode(PbIK)), gen_keyb64(Bytes), gen_otkb64(N, Bytes)}.


while(0, _F) -> ok;
while(N, F) ->
    erlang:apply(F, []),
    while(N -1, F).


perf(N, SetupFun, F) ->
    SetupFun,
    StartTime = util:now_ms(),
    tutil:while(N, F),
    EndTime = util:now_ms(),
    T = EndTime - StartTime,
    % ?debugFmt("~w operations took ~w ms => ~f ops ", [N, T, N / (T / 1000)]),
    {ok, T}.

