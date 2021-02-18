%%%----------------------------------------------------------------------
%%% File    : ejabberd_router.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Main router
%%% Created : 27 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
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
%%%----------------------------------------------------------------------

-module(ejabberd_router).

-author('alexey@process-one.net').

-ifndef(GEN_SERVER).
-define(GEN_SERVER, gen_server).
-endif.
-behaviour(?GEN_SERVER).

%% API
-export([
    route/1,
    route_multicast/3,
    route_error/2,
    route_iq/2,
    route_iq/3,
    route_iq/4,
    register_route/2,
    register_route/3,
    register_route/4,
    register_routes/1,
    host_of_route/1,
    process_iq/1,
    unregister_route/1,
    unregister_route/2,
    unregister_routes/1,
    get_all_routes/0,
    is_my_route/1,
    is_my_host/1,
    clean_cache/1,
    config_reloaded/0
]).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% This value is used in SIP and Megaco for a transaction lifetime.
-define(IQ_TIMEOUT, 32000).
-define(CALL_TIMEOUT, timer:minutes(10)).

-include("logger.hrl").
-include("ejabberd_router.hrl").
-include("xmpp.hrl").
-include("ejabberd_stacktrace.hrl").

-callback init() -> any().
-callback register_route(binary(), binary(), local_hint(),
        undefined | pos_integer(), pid()) -> ok | {error, term()}.
-callback unregister_route(binary(), undefined | pos_integer(), pid()) -> ok | {error, term()}.
-callback find_routes(binary()) -> {ok, [#route{}]} | {error, any()}.
-callback get_all_routes() -> {ok, [binary()]} | {error, any()}.

-record(state, {route_monitors = #{} :: #{{binary(), pid()} => reference()}}).


%%====================================================================
%% API
%%====================================================================

start_link() ->
    ?INFO("start ~w", [?MODULE]),
    ?GEN_SERVER:start_link({local, ?MODULE}, ?MODULE, [], []).


-spec route(stanza()) -> ok.
route(Packet) ->
    try do_route(Packet)
    catch ?EX_RULE(Class, Reason, St) ->
        StackTrace = ?EX_STACK(St),
        ?ERROR("Failed to route packet:~n~ts~n** ~ts",
               [xmpp:pp(Packet),
            misc:format_exception(2, Class, Reason, StackTrace)])
    end,
    ok.


-spec route_multicast(jid(), [jid()], stanza()) -> ok.
route_multicast(_From, [], _Packet) ->
    ok;
route_multicast(From, Destinations, Packet) ->
    Id = xmpp:get_id(Packet),
    Packet1 = xmpp:set_from(Packet, From),
    lists:foldl(
        fun(To, Acc) ->
            AccBin = integer_to_binary(Acc),
            NewId = <<Id/binary, "-", AccBin/binary>>,
            Packet2 = xmpp:set_id(xmpp:set_to(Packet1, To), NewId),
            route(Packet2),
            Acc+1
        end, 0, Destinations),
    ok.


-spec route_error(stanza(), stanza_error()) -> ok.
route_error(Packet, Err) ->
    Type = xmpp:get_type(Packet),
    if
        Type == error; Type == result ->
            ok;
        true ->
            route(xmpp:make_error(Packet, Err))
    end.


-spec route_iq(iq(), fun((iq() | timeout) -> any())) -> ok.
route_iq(IQ, Fun) ->
    route_iq(IQ, Fun, undefined, ?IQ_TIMEOUT).


-spec route_iq(iq(), term(), pid() | atom()) -> ok.
route_iq(IQ, State, Proc) ->
    route_iq(IQ, State, Proc, ?IQ_TIMEOUT).


-spec route_iq(iq(), term(), pid() | atom(), undefined | non_neg_integer()) -> ok.
route_iq(IQ, State, Proc, undefined) ->
    route_iq(IQ, State, Proc, ?IQ_TIMEOUT);
route_iq(IQ, State, Proc, Timeout) ->
    ejabberd_iq:route(IQ, Proc, State, Timeout).


-spec register_route(binary(), binary()) -> ok.
register_route(Domain, ServerHost) ->
    register_route(Domain, ServerHost, undefined).


-spec register_route(binary(), binary(), local_hint() | undefined) -> ok.
register_route(Domain, ServerHost, LocalHint) ->
    register_route(Domain, ServerHost, LocalHint, self()).


-spec register_route(binary(), binary(), local_hint() | undefined, pid()) -> ok.
register_route(Domain, ServerHost, LocalHint, Pid) ->
    case {jid:nameprep(Domain), jid:nameprep(ServerHost)} of
        {error, _} ->
            erlang:error({invalid_domain, Domain});
        {_, error} ->
            erlang:error({invalid_domain, ServerHost});
        {LDomain, LServerHost} ->
            case ejabberd_router_mnesia:register_route(LDomain, LServerHost, LocalHint, undefined, Pid) of
                ok ->
                    ?INFO("Route registered: ~ts", [LDomain]),
                    monitor_route(LDomain, Pid),
                    ejabberd_hooks:run(route_registered, [LDomain]),
                    delete_cache(LDomain);
                {error, Err} ->
                    ?ERROR("Failed to register route ~ts: ~p", [LDomain, Err])
            end
    end.


-spec register_routes([{binary(), binary()}]) -> ok.
register_routes(Domains) ->
    lists:foreach(
        fun ({Domain, ServerHost}) ->
            register_route(Domain, ServerHost)
        end,
        Domains).


-spec unregister_route(binary()) -> ok.
unregister_route(Domain) ->
    unregister_route(Domain, self()).


-spec unregister_route(binary(), pid()) -> ok.
unregister_route(Domain, Pid) ->
    case jid:nameprep(Domain) of
        error ->
            erlang:error({invalid_domain, Domain});
        LDomain ->
            case ejabberd_router_mnesia:unregister_route(LDomain, undefined, Pid) of
                ok ->
                    ?INFO("Route unregistered: ~ts", [LDomain]),
                    demonitor_route(LDomain, Pid),
                    ejabberd_hooks:run(route_unregistered, [LDomain]),
                    delete_cache(LDomain);
                {error, Err} ->
                    ?ERROR("Failed to unregister route ~ts: ~p", [LDomain, Err])
            end
    end.


-spec unregister_routes([binary()]) -> ok.
unregister_routes(Domains) ->
    lists:foreach(
        fun (Domain) ->
            unregister_route(Domain)
        end,
        Domains).


-spec find_routes(binary()) -> [#route{}].
find_routes(Domain) ->
    case use_cache() of
        true ->
            case ets_cache:lookup(?ROUTES_CACHE, {route, Domain},
                    fun() ->
                        case ejabberd_router_mnesia:find_routes(Domain) of
                            {ok, Rs} when Rs /= [] ->
                               {ok, Rs};
                            _ ->
                                error
                        end
                    end) of
                {ok, Rs} -> Rs;
                error -> []
            end;
        false ->
            case ejabberd_router_mnesia:find_routes(Domain) of
                {ok, Rs} -> Rs;
                _ -> []
            end
    end.


-spec get_all_routes() -> [binary()].
get_all_routes() ->
    case use_cache() of
        true ->
            case ets_cache:lookup(?ROUTES_CACHE, routes,
                    fun() ->
                        case ejabberd_router_mnesia:get_all_routes() of
                            {ok, Rs} when Rs /= [] ->
                                {ok, Rs};
                            _ ->
                                error
                        end
                    end) of
               {ok, Rs} -> Rs;
               error -> []
            end;
        false ->
            case ejabberd_router_mnesia:get_all_routes() of
                {ok, Rs} -> Rs;
                _ -> []
            end
    end.


-spec host_of_route(binary()) -> binary().
host_of_route(Domain) ->
    case jid:nameprep(Domain) of
        error ->
            erlang:error({invalid_domain, Domain});
        LDomain ->
            case find_routes(LDomain) of
                [#route{server_host = ServerHost}|_] ->
                    ServerHost;
                _ ->
                    erlang:error({unregistered_route, Domain})
            end
    end.


-spec is_my_route(binary()) -> boolean().
is_my_route(Domain) ->
    case jid:nameprep(Domain) of
        error ->
            erlang:error({invalid_domain, Domain});
        LDomain ->
            find_routes(LDomain) /= []
    end.


-spec is_my_host(binary()) -> boolean().
is_my_host(Domain) ->
    case jid:nameprep(Domain) of
        error ->
            erlang:error({invalid_domain, Domain});
        LDomain ->
            case find_routes(LDomain) of
                [#route{server_host = LDomain}|_] -> true;
                _ -> false
            end
    end.


-spec process_iq(iq()) -> any().
process_iq(IQ) ->
    gen_iq_handler:handle(IQ).


-spec config_reloaded() -> ok.
config_reloaded() ->
    init_cache().


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ejabberd_hooks:add(config_reloaded, ?MODULE, config_reloaded, 50),
    init_cache(),
    ejabberd_router_mnesia:init(),
    clean_cache(),
    {ok, #state{}}.


handle_call({monitor, Domain, Pid}, _From, State) ->
    MRefs = State#state.route_monitors,
    MRefs1 = case maps:is_key({Domain, Pid}, MRefs) of
        true -> MRefs;
        false ->
            MRef = erlang:monitor(process, Pid),
            MRefs#{{Domain, Pid} => MRef}
    end,
    {reply, ok, State#state{route_monitors = MRefs1}};

handle_call({demonitor, Domain, Pid}, _From, State) ->
    MRefs = State#state.route_monitors,
    MRefs1 = case maps:find({Domain, Pid}, MRefs) of
        {ok, MRef} ->
            erlang:demonitor(MRef, [flush]),
            maps:remove({Domain, Pid}, MRefs);
        error ->
            MRefs
    end,
    {reply, ok, State#state{route_monitors = MRefs1}};

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info({route, Packet}, State) ->
    route(Packet),
    {noreply, State};

handle_info({'DOWN', MRef, _, Pid, Info}, State) ->
    MRefs = maps:filter(
        fun({Domain, P}, M) when P == Pid, M == MRef ->
            ?INFO("Pid ~p with route : ~p is down, reason: ~p", [P, Domain, Info]),
            try
                unregister_route(Domain, Pid)
            catch _:_ -> ok
            end,
            false;
        (_, _) ->
            true
        end,
        State#state.route_monitors),
    {noreply, State#state{route_monitors = MRefs}};
handle_info(Info, State) ->
    ?ERROR("Unexpected info: ~p", [Info]),
    {noreply, State}.


terminate(_Reason, _State) ->
    ejabberd_hooks:delete(config_reloaded, ?MODULE, config_reloaded, 50).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-spec do_route(stanza()) -> ok.
do_route(OrigPacket) ->
    ?DEBUG("Route:~n~ts", [xmpp:pp(OrigPacket)]),
    case ejabberd_hooks:run_fold(filter_packet, OrigPacket, []) of
        drop ->
            ok;
        Packet ->
            case ejabberd_iq:dispatch(Packet) of
                true ->
                    ok;
                false ->
                    %% We dont need to check the routing processes until after we store the message.
                    %% After storing the message - we directly route it to the user's c2s process.
                    ejabberd_local:route(Packet)
            end
    end.


-spec monitor_route(binary(), pid()) -> ok.
monitor_route(Domain, Pid) ->
    ?GEN_SERVER:call(?MODULE, {monitor, Domain, Pid}, ?CALL_TIMEOUT).


-spec demonitor_route(binary(), pid()) -> ok.
demonitor_route(Domain, Pid) ->
    case whereis(?MODULE) == self() of
        true ->
            ok;
        false ->
            ?GEN_SERVER:call(?MODULE, {demonitor, Domain, Pid}, ?CALL_TIMEOUT)
    end.


-spec cache_nodes() -> [node()].
cache_nodes() ->
    case erlang:function_exported(ejabberd_router_mnesia, cache_nodes, 0) of
        true -> ejabberd_router_mnesia:cache_nodes();
        false -> ejabberd_cluster:get_nodes()
    end.


%% TODO(murali@): we are not using any cache right now - we could remove this code too.
-spec use_cache() -> boolean().
use_cache() ->
    case erlang:function_exported(ejabberd_router_mnesia, use_cache, 0) of
        true -> ejabberd_router_mnesia:use_cache();
        false -> ejabberd_option:router_use_cache()
    end.


-spec delete_cache(binary()) -> ok.
delete_cache(Domain) ->
    case use_cache() of
        true ->
            ets_cache:delete(?ROUTES_CACHE, {route, Domain}, cache_nodes()),
            ets_cache:delete(?ROUTES_CACHE, routes, cache_nodes());
        false ->
            ok
    end.


-spec init_cache() -> ok.
init_cache() ->
    case use_cache() of
        true ->
            ets_cache:new(?ROUTES_CACHE, cache_opts());
        false ->
            ets_cache:delete(?ROUTES_CACHE)
    end.


-spec cache_opts() -> [proplists:property()].
cache_opts() ->
    MaxSize = ejabberd_option:router_cache_size(),
    CacheMissed = ejabberd_option:router_cache_missed(),
    LifeTime = ejabberd_option:router_cache_life_time(),
    [{max_size, MaxSize}, {cache_missed, CacheMissed}, {life_time, LifeTime}].


-spec clean_cache(node()) -> non_neg_integer().
clean_cache(Node) ->
    ets_cache:filter(
        ?ROUTES_CACHE,
        fun(_, error) ->
            false;
        (routes, _) ->
            false;
        ({route, _}, {ok, Rs}) ->
            not lists:any(fun(#route{pid = Pid}) -> node(Pid) == Node end, Rs)
        end).


-spec clean_cache() -> ok.
clean_cache() ->
    ejabberd_cluster:eval_everywhere(?MODULE, clean_cache, [node()]).

