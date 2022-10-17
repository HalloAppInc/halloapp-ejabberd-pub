%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(ejabberd_monitor_tests).
-author("josh").

-include_lib("tutil.hrl").

get_list_of_stest_monitor_names_test() ->
    Nodes = ['ejabberd@s-test0', 'ejabberd@prod0', 'ejabberd@s-test1'],
    ExpectedResult = [
        {global, ejabberd_monitor:get_registered_name('ejabberd@s-test0')},
        {global, ejabberd_monitor:get_registered_name('ejabberd@s-test1')}
    ],
    ?assertEqual(ExpectedResult, ejabberd_monitor:get_list_of_stest_monitor_names(Nodes)).

