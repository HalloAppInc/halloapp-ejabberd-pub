-ifndef(TUTIL_HRL).
-define(TUTIL_HRL, 1).

-include_lib("eunit/include/eunit.hrl").

% This directive is the magic that auto-exports and calls all functions ending in _testset
% See src/tutil_autoexport for more info
-compile({parse_transform, tutil_autoexport}).

%%====================================================================
%% Type definitions
%%====================================================================

%% Definitions for tests and different testing structures

-type test() :: fun().
-type test_set() :: [test_set() | test()] | control().
-type tests() :: [test_set() | instantiator()].
-type control_type() :: inorder | inparallel | trueparallel | spawn.
-type control() :: {control_type(), TS :: test_set()} |
    {timeout, Seconds :: number(), TS :: test_set()}.

-type setup_fun() :: fun(() -> cleanup_info()).
-type cleanup_fun() :: fun((cleanup_info()) -> any()).
-type instantiator() :: fun((cleanup_info()) -> test_set()).

-type fixture_type() :: foreach | setup.
-type fixture() :: {foreach, setup_fun(), cleanup_fun(), [test_set() | instantiator()]} |
                   {setup, setup_fun(), cleanup_fun(), test_set() | instantiator()}.

% a test generator name must end with "test_"
-type generator() :: fun(() -> [fixture() | test_set()] | fixture() | test_set() | control() | test()).

%% Definitions for function args/returns

-type meck_fun() :: {atom(), fun()}.

-type meck() :: {meck, module(), [meck_fun()]} | {meck, module(), atom(), fun()}.
-type proto() :: proto.
-type redis() :: {redis, atom() | [atom()]}.
-type start() :: {start, module() | [module()]}.

-type setup_option() :: meck() | proto() | redis() | start().
-type cleanup_info() :: #{meck => [module()]}.

%%====================================================================
%% Macros
%%====================================================================

-define(assertOk(Expr), ?assertEqual(ok, Expr)).
-define(_assertOk(Expr), ?_assertEqual(ok, Expr)).

%% These are also defined in src/tutil_autoexport.erl
-define(DEFAULT_TESTSET_SUFFIX, "_testset").
-define(DEFAULT_PARALLEL_TESTSET_SUFFIX, "_testparallel").
-define(DEFAULT_SETUP_FUN_NAME, "setup").

-endif.
