-module(groups_tests).

-compile(export_all).
-include("suite.hrl").

groups_cases() ->
    {groups_something, [sequence], [
        groups_dummy_test
    ]}.

dummy_test(_Conf) ->
    ct:pal("Here"),
    ok.

