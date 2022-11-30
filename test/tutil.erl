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
    %% setup/0 is implicitly exported – you can use it
    setup/1,
    setup_once/2,
    setup_once/3,
    setup_once/4,
    setup_foreach/2,
    setup_foreach/3,
    setup_foreach/4,
    in_parallel/1,
    in_parallel/2,
    in_parallel/3,
    true_parallel/1,
    true_parallel/2,
    true_parallel/3,
    cleanup/1,
    combine_cleanup_info/1,
    %% helpers
    meck_init/2,
    meck_init/3,
    meck_finish/1,
    load_protobuf/0,
    cleardb/1,
    generate_uid/0,
    generate_uid/1,
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
    setup_foreach(SetupFun, fun cleanup/1, Tests, inorder).

-spec setup_foreach(setup_fun(), cleanup_fun(), tests()) -> fixture().
setup_foreach(SetupFun, CleanupFun, Tests) ->
    setup_foreach(SetupFun, CleanupFun, Tests, inorder).

-spec setup_foreach(setup_fun(), cleanup_fun(), tests(), control_type()) -> fixture().
setup_foreach(SetupFun, CleanupFun, Tests, Control) when is_list(Tests) ->
    {foreach, SetupFun, CleanupFun, wrap_foreach(Control, Tests)}.


%% Run setup fun once for all tests
-spec setup_once(setup_fun(), tests()) -> fixture().
setup_once(SetupFun, Tests) ->
    setup_once(SetupFun, fun cleanup/1, Tests, inorder).

-spec setup_once(setup_fun(), cleanup_fun(), tests()) -> fixture().
setup_once(SetupFun, CleanupFun, Tests) ->
    setup_once(SetupFun, CleanupFun, Tests, inorder).

-spec setup_once(setup_fun(), cleanup_fun(), tests(), control_type()) -> fixture().
setup_once(SetupFun, CleanupFun, Tests, Control) when is_list(Tests) ->
    Instantiator = case Control of 
        trueparallel -> control_wrapper(inparallel, inparallel, Tests);
        _ -> control_wrapper(Control, inorder, Tests)
    end,
    {setup, SetupFun, CleanupFun, Instantiator};

setup_once(SetupFun, CleanupFun, Test, Control) ->
    setup_once(SetupFun, CleanupFun, [Test], Control).


% Runs the specified tests in parallel, while preserving order within each testset
% i.e. if _test_ returns [?_assert1, ?_assert2], ?_assert1 will always finish before ?_assert2 starts
-spec in_parallel(tests()) -> fixture().
in_parallel(Tests) ->
    setup_once(fun setup/0, fun cleanup/1, Tests, inparallel).

-spec in_parallel(setup_fun(), tests()) -> fixture().
in_parallel(SetupFun, Tests) ->
    setup_once(SetupFun, fun cleanup/1, Tests, inparallel).

-spec in_parallel(setup_fun(), cleanup_fun(), tests()) -> fixture().
in_parallel(SetupFun, CleanupFun, Tests) ->
    setup_once(SetupFun, CleanupFun, Tests, inparallel).


-spec true_parallel(tests()) -> fixture().
true_parallel(Tests) ->
    setup_once(fun setup/0, fun cleanup/1, Tests, trueparallel).

-spec true_parallel(setup_fun(), tests()) -> fixture().
true_parallel(SetupFun, Tests) ->
    setup_once(SetupFun, fun cleanup/1, Tests, trueparallel).

-spec true_parallel(setup_fun(), cleanup_fun(), tests()) -> fixture().
true_parallel(SetupFun, CleanupFun, Tests) ->
    setup_once(SetupFun, CleanupFun, Tests, trueparallel).

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
    try
        case enif_protobuf:encode({pb_avatar, <<>>, <<>>}) of
            {error, _Reason} -> enif_protobuf:load_cache(server:get_msg_defs());
            Bin when is_binary(Bin) -> ok
        end
    catch
        _:_ ->
            enif_protobuf:load_cache(server:get_msg_defs())
    end,
    ok.


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


-spec wrap_foreach(control_type(), list(instantiator())) -> list(instantiator()).
wrap_foreach(Control, Instantiators) ->
    lists:map(
        fun (I) ->
            % add an anonymous func for each instantiator that wraps its results with Control
            % if they aren't controlled already
            fun (CleanupInfo) ->
                control_wrapper(Control, I(CleanupInfo))
            end
        end,
        Instantiators).


-spec control_wrapper(control_type(), test_set()) -> control().
control_wrapper(Control, Tests) ->
    case is_list(Tests) of
        true -> {Control, Tests};
        false -> Tests
    end.

-spec control_wrapper(control_type(), control_type(), list(instantiator())) -> instantiator().
control_wrapper(OuterControl, InnerControl, Instantiators) ->
    fun (CleanupInfo) ->
        {OuterControl, lists:map(
            fun (I) -> 
                control_wrapper(InnerControl, I(CleanupInfo))
            end,
            Instantiators)}
    end.


%%====================================================================
%% Common test helpers
%%====================================================================

generate_uid() ->
    generate_uid(?HALLOAPP).

generate_uid(AppType) ->
    {ok, Uid} = case AppType of
        ?KATCHUP -> util_uid:generate_uid("Katchup");
        _ -> util_uid:generate_uid("HalloApp")
    end,
    Uid.


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
    OrderedPattern = ?DEFAULT_TESTSET_SUFFIX,
    ParallelPattern = ?DEFAULT_PARALLEL_TESTSET_SUFFIX,

    PatternList = [OrderedPattern, ParallelPattern],

    % Get all functions ending in "_testset"
    {OrderedTestFuns, ParallelTestFuns} = lists:foldl( 
        fun ({Name, Arity} = Fun, {OrdFuns, ParFuns} = Acc) when Arity =< 1 -> % allow for arity 0 or 1
                NameStr = atom_to_list(Name),
                case lists:map(fun (Pat) -> lists:suffix(Pat, NameStr) end, PatternList) of 
                    [true, false] -> {[Fun | OrdFuns], ParFuns};
                    [false, true] -> {OrdFuns, [Fun | ParFuns]};
                    _ -> Acc
                end;
            ({_, _}, Acc) -> Acc
        end,
        {[],[]},
        Functions),

    SetupFun = case lists:member({setup, 0}, Functions) of % Use the module's setup, if one is exported
        true -> fun Module:setup/0;
        false -> fun tutil:setup/0
    end,

    % Wrap the testset functions in a fixture, and return it!
    OrderedFixture = setup_foreach(
        SetupFun,
        fun tutil:cleanup/1,
        lists:map(
            fun ({Name, 0}) ->
                    fun (_Arg) ->
                        Module:Name()
                    end;
                ({Name, 1}) ->
                    fun Module:Name/1
            end,
            OrderedTestFuns),
        inorder),
        
    ParallelFixture = setup_once(
        SetupFun,
        fun tutil:cleanup/1,
        lists:map(
            fun ({Name, 0}) ->
                    fun (_Arg) ->
                        Module:Name()
                    end;
                ({Name, 1}) ->
                    fun Module:Name/1
            end,
            ParallelTestFuns),
        inparallel),

    [OrderedFixture, ParallelFixture].
