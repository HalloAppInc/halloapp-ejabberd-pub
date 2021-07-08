%%%----------------------------------------------------------------------
%%% File    : util_rpc.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%% This module handles all the utility functions related to rpc.
%%%----------------------------------------------------------------------

-module(util_rpc).
-author('murali').

%% TODO: add tests for these functions.
-export([
    pmap/3
]).


%% reference is here: https://github.com/erlang/otp/blob/OTP-23.2.7/lib/kernel/src/rpc.erl
%% Very similar to rpc:pmap except that the list of nodes to run on is shuffled everytime.
%% This way - load should be spread equally on all the nodes.
pmap({M,F}, As, List) ->
    check(parallel_eval(build_args(M,F,As, List, [])), []).


-spec parallel_eval(FuncCalls) -> ResL when
    FuncCalls :: [{Module, Function, Args}],
    Module :: module(), Function :: atom(), Args :: [term()],
    ResL :: [term()].
parallel_eval(ArgL) ->
    AllNodes = [node() | nodes()],
    ShuffleNodes = util:random_shuffle(AllNodes),
    Keys = map_nodes(ArgL,ShuffleNodes,ShuffleNodes),
    [rpc:yield(K) || K <- Keys].


%% Maps the work on the list of nodes given in a round-robin fashion.
map_nodes([],_,_) -> [];
map_nodes(ArgL,[],Original) ->
    map_nodes(ArgL,Original,Original);
map_nodes([{M,F,A}|Tail],[Node|MoreNodes], Original) ->
    [rpc:async_call(Node,M,F,A) | map_nodes(Tail,MoreNodes,Original)].


%% If one single call fails, we fail the whole computation
check([{badrpc, _}|_], _) -> error(badrpc);
check([X|T], Ack) -> check(T, [X|Ack]);
check([], Ack) -> Ack.


%% By using an accumulator twice we get the whole thing right
build_args(M,F, As, [Arg|Tail], Acc) ->
    build_args(M,F, As, Tail, [{M,F,[Arg|As]}|Acc]);
build_args(M,F, _, [], Acc) when is_atom(M), is_atom(F) -> Acc.

