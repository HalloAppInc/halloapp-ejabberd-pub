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

-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([
    %% test management
    setup/0,
    setup/1,
    cleanup/1,
    combine_cleanup_info/1,
    get_result_iq_sub_el/1,
    assert_empty_result_iq/1,
    get_error_iq_sub_el/1,

    %% helpers
    gen_keyb64/1,
    gen_otkb64/2,
    gen_otk/2,
    gen_whisper_keys/2,
    while/2,
    perf/3,

    %% TODO: remove below API in favor of using setup/1
    load_protobuf/0,
    cleardb/1,
    meck_init/2,
    meck_init/3,
    meck_finish/1
]).

-type meck_fun() :: {atom(), function()}.

-type meck() :: {meck, module(), [meck_fun()]} | {meck, module(), atom(), function()}.
-type proto() :: proto.
-type redis() :: {redis, atom() | [atom()]}.
-type start() :: {start, module() | [module()]}.

-type setup_option() :: meck() | proto() | redis() | start().
-type cleanup_info() :: #{meck => [module()]}.


setup() ->
    ?assert(config:is_testing_env()),
    #{}.


-spec setup(Options :: [setup_option()]) -> cleanup_info().
setup(Options) ->
    setup(),
    setup(Options, #{}).


setup([Opt | Rest], CleanupInfo) ->
    NewCleanupInfo = case Opt of
        {meck, Mod, FunName, Fun} ->
            CleanupInfo#{meck => [meck_init(Mod, FunName, Fun) | maps:get(meck, CleanupInfo, [])]};
        {meck, Mod, MeckedFuns} ->
            CleanupInfo#{meck => [meck_init(Mod, MeckedFuns) | maps:get(meck, CleanupInfo, [])]};
        proto ->
            load_protobuf(),
            CleanupInfo;
        {redis, Redis} ->
            init_redis(Redis),
            CleanupInfo;
        {start, Module} ->
            init_module(Module),
            CleanupInfo
    end,
    setup(Rest, NewCleanupInfo);

setup([], CleanupInfo) ->
    CleanupInfo.


cleanup(CleanupInfo) ->
    lists:foreach(
        fun(Mod) -> meck_finish(Mod) end,
        maps:get(meck, CleanupInfo, [])).


%% use this function if you have multiple setup calls
-spec combine_cleanup_info(CleanupInfoList :: [cleanup_info()]) -> cleanup_info().
combine_cleanup_info(CleanupInfoList) ->
    lists:foldl(
        fun(NewCleanupInfo, OldCleanupInfo) ->
            %% combine meck modules to unload
            OldCleanupInfo#{meck =>
                maps:get(meck, NewCleanupInfo, []) ++ maps:get(meck, OldCleanupInfo, [])}
        end,
        #{},
        CleanupInfoList).


-spec meck_init(Module :: module(), FunName ::atom(), Fun :: function()) -> Module :: module().
meck_init(Module, FunName, Fun) ->
    meck_init(Module, [{FunName, Fun}]).

-spec meck_init(Module :: module(), MockedAndReplacementFuns :: [meck_fun()]) -> Module :: module().
meck_init(Module, MockedAndReplacementFuns) ->
    %% the passthrough option allows all non-mocked functions in the module to be preserved
    meck:new(Module, [passthrough]),
    lists:foreach(
        fun({MockedFun, ReplacementFun}) ->
            meck:expect(Module, MockedFun, ReplacementFun)
        end,
        MockedAndReplacementFuns),
    Module.


-spec meck_finish(Module :: module()) -> ok.
meck_finish(Module) ->
    %% this assertion will fail if:
    %%  - the function is called with the wrong arg types (function_clause)
    %%  - an exception is thrown inside the function (and meck:exception was not used)
    ?assert(meck:validate(Module)),
    meck:unload(Module).


load_protobuf() ->
    case enif_protobuf:encode({pb_avatar, <<>>, <<>>}) of
        {error, _Reason} -> enif_protobuf:load_cache(server:get_msg_defs());
        Bin when is_binary(Bin) -> ok
    end.


-spec init_redis(RedisClient :: atom() | [atom()]) -> ok.
init_redis(RedisClient) when not is_list(RedisClient) ->
    init_redis([RedisClient]);

init_redis(RedisClients) ->
    ha_redis:start(),
    lists:foreach(fun cleardb/1, RedisClients).


-spec init_module(Module :: module() | [module()]) -> ok.
init_module(Module) when not is_list(Module) ->
    init_module([Module]);

init_module(Modules) ->
    lists:foreach(
        fun(Module) ->
            {ok, _StartedMods} = application:ensure_all_started(Module)
        end,
        Modules).


get_result_iq_sub_el(#pb_iq{} = IQ) ->
    ?assertEqual(result, IQ#pb_iq.type),
    IQ#pb_iq.payload.



assert_empty_result_iq(#pb_iq{} = IQ) ->
    ?assertEqual(result, IQ#pb_iq.type),
    ?assertEqual(undefined, IQ#pb_iq.payload).


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
    ?assert(DbSize < 500),

    %% TODO: figure out way to ensure flushdb is only available
    %% during tests. This is simple enough with eunit, as the TEST
    %% flag is set during compilation. But this is not the case with CT tests.

    ok = ecredis:flushdb(RedisClient).


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

