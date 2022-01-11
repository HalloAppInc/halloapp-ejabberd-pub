%%%-------------------------------------------------------------------
%%% ejabberd_cluster module provide API to interact with the cluster of
%%% erlang nodes that together form the ejabberd cluster.
%%%
%%% We use the erlang:nodes() api to represent the nodes that are currently
%%% in the cluster. We also use Redis Set to help new nodes join the cluster.
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

-include("time.hrl").
-include("logger.hrl").
-include("packets.hrl").

-type dst() :: pid() | atom() | {atom(), node()}.

-record(state, {}).

-define(CLUSTER_JOIN_RETRY_INTERVAL, 5 * ?SECONDS_MS).
-define(CLUSTER_JOIN_RETRY_DURATION, 60 * ?SECONDS_MS).

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
    UntilTsMs = util:now_ms() + ?CLUSTER_JOIN_RETRY_DURATION,
    join_until(UntilTsMs).


-spec join_until(UntilTsMs :: integer()) -> ok | {error, Reason :: term()}.
join_until(UntilTsMs) ->
    RedisNodes = model_cluster:get_nodes(),
    lists:foreach(
        fun(RNode) ->
            % we are not sure what is the difference between
            % net_kernel:connect_node and net_adm:ping
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
            ?ERROR("Failed to join the cluster, retrying in ~p seconds",
                [?CLUSTER_JOIN_RETRY_INTERVAL]),
            timer:sleep(?CLUSTER_JOIN_RETRY_INTERVAL),
            case util:now_ms() < UntilTsMs of
                true ->
                    join_until(UntilTsMs);
                false ->
                    ?ERROR("Final attempt to join the cluster failed"),

                    Msg = io_lib:format("Node ~s on ~s has failed to join the ejabberd cluster. "
                        "RedisNodes: ~p", [node(), util:get_machine_name(), RedisNodes]),
                    alerts:send_alert(<<"Ejabberd node has failed to join the cluster">>,
                        <<"Ejabberd">>, <<"critical">>, iolist_to_binary(Msg)),

                    {error, join_failed}
            end;
        _ -> ok
    end.


-spec leave(node()) -> ok | {error, any()}.
leave(Node) when Node == node() ->
    ?INFO("Our node ~p is leaving the ejabberd cluster ~p", [Node, get_nodes()]),
    leave_self();
leave(Node) ->
    case net_adm:ping(Node) of
        pong ->
            ?INFO("Asking node: ~p to leave", [Node]),
            Res = rpc:call(Node, ?MODULE, leave, [Node], 10000),
            ?INFO("node:~p leave rpc result: ~p", [Res]),
            Res;
        pang ->
            % In this case the node that is leaving is already dead.
            RemoveResult = model_cluster:remove_node(Node),
            ?INFO("Kicking node: ~p from the cluster ~p. RemoveResult ~p",
                [Node, get_nodes(), RemoveResult]),
            ok
    end.

leave_self() ->
    RemoveRes = model_cluster:remove_node(node()),
    ?INFO("This node ~p is leaving the ejabbed cluster. RemoveRes: ~p", [RemoveRes]),
    application:stop(ejabberd),
    application:stop(mnesia),
    % Using spawn to allow the leave ctl command to complete. Process exits later
    spawn(
        fun() ->
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
    do_send(Dst, encode_msg(Msg)).
    
do_send(_Dst, undefined) -> false; % failure to encode packet
do_send(Dst, Msg) ->
    case erlang:send(Dst, Msg, [nosuspend, noconnect]) of
        ok -> true;
        _ -> false
    end.


encode_msg(Msg) ->
    stat:count("HA/ejabberd", "send_packet", 1, [{result, ok}, {type, termlang}]),
    Msg.
%% encode_msg(Msg) ->
 %%    case Msg of
%%         {route, Packet} ->
%%             PbPacket = #pb_packet{stanza = Packet},
%%             case enif_protobuf:encode(PbPacket) of
%%                 {error, Reason} ->
%%                     ?ERROR("Error encoding packet: ~p, reason: ~p", [Packet, Reason]),
 %%                    stat:count("HA/ejabberd", "send_packet", 1, [{result, error}, {type, pb}]),
%%                     undefined;
%%                 PbBin ->
%%                     stat:count("HA/ejabberd", "send_packet", 1, [{result, ok}, {type, pb}]),
%%                     {route_pb, PbBin}
%%             end;
%%         _ ->
%%             Msg
%%    end.


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
    % our process wants to know when nodes in the erlang cluster go up or down.
    % we will get nodeup and nodedown messages
    ok = net_kernel:monitor_nodes(true, [{node_type, visible}, nodedown_reason]),
    set_ticktime(),
    % TODO: join should try for 1m and page if it fails,
    % but ejabberd start should resume
    join(),
    ejabberd_hooks:add(config_reloaded, ?MODULE, set_ticktime, 50),
    {ok, #state{}}.

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({nodeup, Node, InfoList}, State) ->
    ?INFO("Node ~ts has joined the cluster.", [Node]),
    ejabberd_hooks:run(node_up, [Node, InfoList]),
    {noreply, State};
handle_info({nodedown, Node, InfoList}, State) ->
    Reason = proplists:get_value(nodedown_reason, InfoList),
    ?INFO("Node ~ts has left the cluster. Reason:~p", [Node, Reason]),
    ejabberd_hooks:run(node_down, [Node, InfoList]),
    {noreply, State};
handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok = net_kernel:monitor_nodes(false, [{node_type, visible}, nodedown_reason]),
    ejabberd_hooks:delete(config_reloaded, ?MODULE, set_ticktime, 50).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================


rpc_timeout() ->
    ejabberd_option:rpc_timeout().

