%%%------------------------------------------------------------------------------------
%%% File: model_cluster.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model implements redis operation for storing and manipulating the
%%% list of nodes that are in the ejabberd cluster.
%%%
%%%------------------------------------------------------------------------------------
-module(model_cluster).
-author("nikola").
-behavior(gen_mod).

-include("logger.hrl").
-include("ha_types.hrl").
-include("redis_keys.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).


%% API
-export([
    get_nodes/0,
    add_node/1,
    remove_node/1
]).


%% Export all functions for unit tests
-ifdef(TEST).
-export([
    cluster_key/0
]).
-endif.


%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================

-spec get_nodes() -> [node()].
get_nodes() ->
    {ok, Nodes} = q(["SMEMBERS", cluster_key()]),
    lists:map(fun util:to_atom/1, Nodes).

-spec add_node(Node :: node()) -> boolean().
add_node(Node) ->
    {ok, Res} = q(["SADD", cluster_key(), atom_to_list(Node)]),
    Res =:= <<"1">>.

-spec remove_node(Node :: node()) -> boolean().
remove_node(Node) ->
    {ok, Res} = q(["SREM", cluster_key(), atom_to_list(Node)]),
    Res =:= <<"1">>.


q(Command) -> ecredis:q(ecredis_sessions, Command).


-spec cluster_key() -> binary().
cluster_key() ->
    ?CLUSTER_KEY.
