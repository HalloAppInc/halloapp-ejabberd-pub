-module(groups_tests).

-compile(export_all).
-include("suite.hrl").

group() ->
    {groups, [sequence], [
        groups_dummy_test
    ]}.

dummy_test(_Conf) ->
    ok.

