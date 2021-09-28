%%%-------------------------------------------------------------------
%%% File: mod_retention_tests.erl
%%% Copyright (C) 2021, HalloApp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_retention_tests).
-author("vipin").

-include("time.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, mod_retention).
%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%

schedule_test() ->
    Tue = {2021, 3, 23},    % Mar 22, 2021 is a Monday
    TaskTime1 = {21, 59, 59},    % 10pm
    TaskTime2 = {22, 59, 59},    % 11pm
    Self = self(),
    Timeout = 1500,
    meck:expect(?MOD, dump_accounts, fun() -> Self ! ack end),
    meck:expect(?MOD, compute_retention, fun() -> Self ! ack2 end),
    setup_erlcron(),

    mod_retention:schedule(),
    erlcron:set_datetime({Tue, TaskTime1}),
    erlcron:set_datetime({Tue, TaskTime2}),
    ?assertEqual(1, collect(ack, Timeout, 1)),
    ?assertEqual(1, collect(ack2, Timeout, 1)),
    mod_retention:unschedule(),
    cleanup_erlcron().

%% -------------------------------------------- %%
%% Internal functions
%% -------------------------------------------- %%

setup_erlcron() ->
    application:start(erlcron),
    ok.

cleanup_erlcron() ->
    %% prevents INFO REPORT generation
    error_logger:tty(false),
    application:stop(erlcron),
    error_logger:tty(true),
    ok.

collect(Msg, Timeout, Count) ->
    collect(Msg, Timeout, 0, Count).
collect(_Msg, _Timeout, Count, Count) ->
    Count;
collect(Msg, Timeout, I, Count) ->
    receive
        Msg -> collect(Msg, Timeout, I+1, Count)
    after
        Timeout -> I
    end.

