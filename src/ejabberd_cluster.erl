%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created :  5 Jul 2017 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------
-module(ejabberd_cluster).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    call/4,
    call/5,
    multicall/3,
    multicall/4,
    multicall/5,
    abcast/2,
    eval_everywhere/3,
    eval_everywhere/4
]).
%% Backend dependent API
-export([
    get_nodes/0,
    get_known_nodes/0,
    join/0,
    leave/1,
    send/2
]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% hooks
-export([set_ticktime/0]).

-include("logger.hrl").

-type dst() :: pid() | atom() | {atom(), node()}.

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    ?INFO("start ~w", [?MODULE]),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


-spec call(node(), module(), atom(), [any()]) -> any().
call(Node, Module, Function, Args) ->
    call(Node, Module, Function, Args, rpc_timeout()).


-spec call(node(), module(), atom(), [any()], timeout()) -> any().
call(Node, Module, Function, Args, Timeout) ->
    rpc:call(Node, Module, Function, Args, Timeout).


-spec multicall(module(), atom(), [any()]) -> {list(), [node()]}.
multicall(Module, Function, Args) ->
    multicall(get_nodes(), Module, Function, Args).


-spec multicall([node()], module(), atom(), list()) -> {list(), [node()]}.
multicall(Nodes, Module, Function, Args) ->
    multicall(Nodes, Module, Function, Args, rpc_timeout()).


-spec multicall([node()], module(), atom(), list(), timeout()) -> {list(), [node()]}.
multicall(Nodes, Module, Function, Args, Timeout) ->
    rpc:multicall(Nodes, Module, Function, Args, Timeout).


-spec abcast(atom(), term()) -> abcast.
abcast(Name, Request) ->
    gen_server:abcast(get_nodes(), Name, Request).


-spec eval_everywhere(module(), atom(), [any()]) -> ok.
eval_everywhere(Module, Function, Args) ->
    eval_everywhere(get_nodes(), Module, Function, Args),
    ok.


-spec eval_everywhere([node()], module(), atom(), [any()]) -> ok.
eval_everywhere(Nodes, Module, Function, Args) ->
    rpc:eval_everywhere(Nodes, Module, Function, Args),
    ok.


%%%===================================================================
%%% Backend dependent API
%%%===================================================================

-spec get_nodes() -> [node()].
get_nodes() ->
    [node() | erlang:nodes()].


-spec get_known_nodes() -> [node()].
get_known_nodes() ->
    model_cluster:get_nodes().


-spec join() -> ok | {error, any()}.
join() ->
    AddRes = model_cluster:add_node(node()),
    ?INFO("This node: ~p is joining the cluster. new: ~p", [node(), AddRes]),
    RedisNodes = model_cluster:get_nodes(),
    lists:foreach(
        fun(RNode) ->
            case net_adm:ping(RNode) of
                pong ->
                    ?INFO("Successful connected to node ~p", [RNode]);
                pang ->
                    ?WARNING("Failed to ping node ~p", [RNode])
            end
        end,
        RedisNodes),
    Nodes = get_nodes(),
    ?INFO("Nodes: ~p RedisNodes: ~p", [Nodes, RedisNodes]),
    case Nodes of
        [] ->
            % TODO: keep trying for up to 1m to ping nodes
            ?ERROR("Failed to join the cluster"),
            {error, join_failed};
        _ -> ok
    end.


-spec leave(node()) -> ok | {error, any()}.
leave(Node) when Node == node() ->
    Cluster = get_nodes()--[Node],
    leave_self(Cluster);
leave(Node) ->
    case net_adm:ping(Node) of
        pong ->
            ?INFO("Asking node: ~p to leave", [Node]),
            Res = rpc:call(Node, ?MODULE, leave, [Node], 10000),
            ?INFO("node:~p leave rpc result: ~p", [Res]),
            Res;
        pang ->
            RemoveResult = model_cluster:remove_node(Node),
            ?INFO("Kicking node: ~p from the cluster. RemoveResult ~p",
                [Node, RemoveResult]),
            % TODO: delete this code after this change is deployed.
            case mnesia:del_table_copy(schema, Node) of
                {atomic, ok} -> ok;
                {aborted, Reason} -> {error, Reason}
            end
    end.

leave_self([]) ->
    {error, {no_cluster, node()}};
leave_self([Master | _]) ->
    RemoveRes = model_cluster:remove_node(node()),
    ?INFO("This node ~p is leaving the ejabbed cluster. RemoveRes: ~p", [RemoveRes]),
    application:stop(ejabberd),
    application:stop(mnesia),
    % TODO: why the spawn? maybe we want the leave command to complete and
    % return result on the terminal?
    spawn(
        fun() ->
            % TODO: delete this mnesia code, after this change gets deployed
            rpc:call(Master, mnesia, del_table_copy, [schema, node()]),
            mnesia:delete_schema([node()]),
            erlang:halt(0)
        end),
    ok.

%% Note that false positive returns are possible, while false negatives are not.
%% In other words: positive return value (i.e. 'true') doesn't guarantee
%% successful delivery, while negative return value ('false') means
%% the delivery has definitely failed.
-spec send(dst(), term()) -> boolean().
send({Name, Node}, Msg) when Node == node() ->
    send(Name, Msg);
send(undefined, _Msg) ->
    false;
send(Name, Msg) when is_atom(Name) ->
    send(whereis(Name), Msg);
send(Pid, Msg) when is_pid(Pid) andalso node(Pid) == node() ->
    case erlang:is_process_alive(Pid) of
        true ->
            erlang:send(Pid, Msg),
            true;
        false ->
            false
    end;
send(Dst, Msg) ->
    case erlang:send(Dst, Msg, [nosuspend, noconnect]) of
        ok -> true;
        _ -> false
    end.


%%%===================================================================
%%% Hooks
%%%===================================================================

set_ticktime() ->
    Ticktime = ejabberd_option:net_ticktime() div 1000,
    case net_kernel:set_net_ticktime(Ticktime) of
        {ongoing_change_to, Time} when Time /= Ticktime ->
            ?ERROR("Failed to set new net_ticktime because "
                   "the net kernel is busy changing it to the "
                   "previously configured value. Please wait for "
                   "~B seconds and retry", [Time]);
        _ ->
            ok
    end.

%%%===================================================================
%%% gen_server API
%%%===================================================================

init([]) ->
    set_ticktime(),
    % TODO: Delete this codepath for connecting to nodes based on config list
    Nodes = ejabberd_option:cluster_nodes(),
    lists:foreach(
        fun(Node) ->
            % we are not sure what is the difference between connect_node and ping
            net_kernel:connect_node(Node)
        end, Nodes),
    % TODO: join should try for 1m and page if it fails,
    % but ejabberd start should resume
    join(),
    ejabberd_hooks:add(config_reloaded, ?MODULE, set_ticktime, 50),
    {ok, #state{}}.

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

% TODO: (nikola) Can not find who sends those?
handle_info({node_up, Node}, State) ->
    ?INFO("Node ~ts has joined", [Node]),
    {noreply, State};
handle_info({node_down, Node}, State) ->
    ?INFO("Node ~ts has left", [Node]),
    {noreply, State};
handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ejabberd_hooks:delete(config_reloaded, ?MODULE, set_ticktime, 50).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================


rpc_timeout() ->
    ejabberd_option:rpc_timeout().

