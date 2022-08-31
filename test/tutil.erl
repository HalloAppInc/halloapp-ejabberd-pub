%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, Halloapp Inc.
%%% @doc
%%% Helpers for running tests
%%% @end
%%%-------------------------------------------------------------------
-module(tutil).
-author("josh").

-include("ha_types.hrl").
-include("packets.hrl").
-include("tutil.hrl").

%% API
-export([
    %% test management
    setup/1,
    setup_once/2,
    setup_once/3,
    setup_once/4,
    setup_foreach/2,
    setup_foreach/3,
    setup_foreach/4,
    make_fixture/2,
    make_fixture/3,
    make_fixture/4,
    make_fixture/5,
    cleanup/1,
    combine_cleanup_info/1,
    %% helpers
    meck_init/2,
    meck_init/3,
    meck_finish/1,
    load_protobuf/0,
    cleardb/1,
    get_result_iq_sub_el/1,
    assert_empty_result_iq/1,
    get_error_iq_sub_el/1,
    gen_keyb64/1,
    gen_otkb64/2,
    gen_otk/2,
    gen_whisper_keys/2,
    while/2,
    perf/3,
    run_testsets/1
 ]).

%%====================================================================
%% Test management
%%====================================================================

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


%% Run setup fun for each test
-spec setup_foreach(setup_fun(), tests()) -> fixture().
setup_foreach(SetupFun, Tests) ->
    setup_foreach(SetupFun, fun cleanup/1, Tests).

-spec setup_foreach(setup_fun(), cleanup_fun(), tests()) -> fixture().
setup_foreach(SetupFun, CleanupFun, Tests) ->
    setup_foreach(SetupFun, CleanupFun, Tests, undefined).

-spec setup_foreach(setup_fun(), cleanup_fun(), tests(), control_type()) -> fixture().
setup_foreach(SetupFun, CleanupFun, Tests, Control) ->
    make_fixture(foreach, SetupFun, CleanupFun, Tests, Control).


%% Run setup fun once for all tests
-spec setup_once(setup_fun(), tests()) -> fixture().
setup_once(SetupFun, Tests) ->
    setup_once(SetupFun, fun cleanup/1, Tests).

-spec setup_once(setup_fun(), cleanup_fun(), tests()) -> fixture().
setup_once(SetupFun, CleanupFun, Tests) ->
    setup_once(SetupFun, CleanupFun, Tests, undefined).

-spec setup_once(setup_fun(), cleanup_fun(), tests(), control_type()) -> fixture().
setup_once(SetupFun, CleanupFun, Tests, Control) ->
    make_fixture(setup, SetupFun, CleanupFun, Tests, Control).


%% Recommended to use setup_once or setup_foreach instead of make_fixture
-spec make_fixture(fixture_type(), tests()) -> fixture().
make_fixture(Type, Tests) ->
    make_fixture(Type, fun setup/0, Tests).

-spec make_fixture(fixture_type(), setup_fun(), tests()) -> fixture().
make_fixture(Type, SetupFun, Tests) ->
    make_fixture(Type, SetupFun, fun cleanup/1, Tests).

-spec make_fixture(fixture_type(), setup_fun(), cleanup_fun(), tests()) -> fixture().
make_fixture(Type, SetupFun, CleanupFun, Tests) ->
    make_fixture(Type, SetupFun, CleanupFun, Tests, undefined).

-spec make_fixture(fixture_type(), setup_fun(), cleanup_fun(), tests(), maybe(control_type())) -> fixture().
make_fixture(setup, SetupFun, CleanupFun, Tests, Control) when is_list(Tests) ->
    {setup, SetupFun, CleanupFun,
        fun(CleanupInfo) ->
            control_wrapper(
                Control,
                lists:map(
                    fun(Test) ->
                        case is_function(Test) of
                            true -> {inorder, Test(CleanupInfo)};
                            false -> {inorder, Test}
                        end
                    end,
                    Tests))
        end};

make_fixture(setup, SetupFun, CleanupFun, Test, Control) ->
    {setup, SetupFun, CleanupFun, control_wrapper(Control, Test)};

make_fixture(foreach, SetupFun, CleanupFun, Tests, Control) ->
    {foreach, SetupFun, CleanupFun, control_wrapper(Control, Tests)}.


%% This function usually does not need to be explicitly called
-spec cleanup(cleanup_info()) -> any().
cleanup(CleanupInfo) ->
    lists:foreach(
        fun(Mod) -> meck_finish(Mod) end,
        maps:get(meck, CleanupInfo, [])).


%% Use this function if you have multiple setup calls
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

%%====================================================================
%% Internal functions
%%====================================================================
%% TODO: phase out use of these functions outside this module
%% only test management functions above should call these

-spec meck_init(module(), atom(), fun()) -> module().
meck_init(Module, FunName, Fun) ->
    meck_init(Module, [{FunName, Fun}]).

-spec meck_init(module(), [meck_fun()]) -> module().
meck_init(Module, MockedAndReplacementFuns) ->
    %% the passthrough option allows all non-mocked functions in the module to be preserved
    meck:new(Module, [passthrough]),
    lists:foreach(
        fun({MockedFun, ReplacementFun}) ->
            meck:expect(Module, MockedFun, ReplacementFun)
        end,
        MockedAndReplacementFuns),
    Module.


-spec meck_finish(module()) -> ok.
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


-spec init_redis(atom() | [atom()]) -> ok.
init_redis(RedisClient) when not is_list(RedisClient) ->
    init_redis([RedisClient]);

init_redis(RedisClients) ->
    ha_redis:start(),
    lists:foreach(fun cleardb/1, RedisClients).


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


-spec init_module(module() | [module()]) -> ok.
init_module(Module) when not is_list(Module) ->
    init_module([Module]);

init_module(Modules) ->
    lists:foreach(
        fun(Module) ->
            {ok, _StartedMods} = application:ensure_all_started(Module)
        end,
        Modules).


-spec control_wrapper(Control :: control_type(), Tests :: test_set()) -> fun((test_set()) -> test_set()).
control_wrapper(Control, Tests) ->
    case Control of
        undefined -> Tests;
        inparallel -> {inparallel, lists:map(fun(T) -> {inorder, T} end, Tests)};
        _ -> {Control, Tests}
    end.

%%====================================================================
%% Common test helpers
%%====================================================================

get_result_iq_sub_el(#pb_iq{} = IQ) ->
    ?assertEqual(result, IQ#pb_iq.type),
    IQ#pb_iq.payload.


assert_empty_result_iq(#pb_iq{} = IQ) ->
    ?assertEqual(result, IQ#pb_iq.type),
    ?assertEqual(undefined, IQ#pb_iq.payload).


get_error_iq_sub_el(#pb_iq{} = IQ) ->
    ?assertEqual(error, IQ#pb_iq.type),
    IQ#pb_iq.payload.


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

%%====================================================================
%% Magic (automatic generation of test fixtures)
%%====================================================================

% This function is called by auto_test_/0, which is a generator function that is automatically 
% inserted into any modules that include tutil.hrl (which contains a compiler directive to apply the
% tutil_autoexport parse_transform. It creates a fixture that calls all functions ending in _testset
% in Module, and runs the returned test sets in order. 
% 
% This allows for test modules to write test generators that will be automatically setup and torn 
% down using the module's defined setup/0 function, or tutil's setup/0 if none is found.
run_testsets(Module) ->
    % Get a list of all functions in the specified module
    Functions = Module:module_info(functions),
    Pattern = ?DEFAULT_TESTSET_SUFFIX,
    % Get all functions ending in "_testset"
    TestFuns = lists:filter( 
        fun ({Name, Arity}) when Arity =< 1 -> % allow for arity 0 or 1
                NameStr = atom_to_list(Name),
                lists:suffix(Pattern, NameStr);
            ({_, _}) -> false
        end,
        Functions),
    Setup = case lists:member({setup, 0}, Functions) of % Use the module's setup, if one is exported
        true -> fun Module:setup/0;
        false -> fun tutil:setup/0
    end,

    % Wrap the testset functions in a fixture, and return it!
    make_fixture(foreach, Setup, lists:map(
        fun ({Name, 0}) ->
                fun (_Arg) ->
                    {inorder, Module:Name()}
                end;
            ({Name, 1}) ->
                fun (Arg) ->
                    {inorder, Module:Name(Arg)}
                end
        end,
        TestFuns)).
