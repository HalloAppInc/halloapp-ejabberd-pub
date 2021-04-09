%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% The ha_bot_farm starts and controlls N ha_bot gen_servers.
%%% @end
%%%-------------------------------------------------------------------
-module(ha_bot_farm).

-behaviour(gen_server).

-include("logger.hrl").

-export([
    start/3,
    start_link/0,
    stop/1,
    set_bots/2,
    set_conf/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).
-define(STATS_TIME, 1000). % stats inteval 1s

-record(state, {
    name :: term(),
    num_bots = 0 :: integer(),
    bots = [] :: list(),
    conf = #{} :: map(),
    stats = #{} :: map(),
    parent_pid :: pid(),
    tref_stats :: timer:tref()
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Name, NumBots, ParentPid) ->
    gen_server:start({global, Name}, ?MODULE, [Name, NumBots, ParentPid], []).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [?SERVER, 0, undefined], []).

stop(Pid) ->
    gen_server:stop(Pid, normal, 30000).

set_bots(Pid, NumBots) ->
    gen_server:call(Pid, {set_bots, NumBots}, 30000).

set_conf(Pid, Conf) ->
    gen_server:call(Pid, {set_conf, Conf}, 30000).

init([Name, NumBots, ParentPid]) ->
    ?INFO("Starting Farm: ~p NumBots: ~p ~p", [Name, NumBots, self()]),
    % TODO: it feels like this things should be in the ha_client. ha_client should make sure
    % the pb definitions are loaded and ssl started
    enif_protobuf:load_cache(server:get_msg_defs()),
    ssl:start(),
    {ok, TrefStats} = timer:send_interval(?STATS_TIME, self(), {send_stats}),
    State = #state{
        name = Name,
        parent_pid = ParentPid,
        tref_stats = TrefStats
    },
    State2 = start_bots_to(NumBots, State),
    {ok, State2}.

handle_call({set_bots, NumBots}, _From, State) ->
    ?INFO("set_bots ~p", [NumBots]),
    State2 = scale_bots(NumBots, State),
    {reply, ok, State2};
handle_call({set_conf, Conf}, _From, State = #state{bots = Bots}) ->
    lists:foreach(
        fun (Pid) ->
            ha_bot:set_conf(Pid, Conf)
        end,
        Bots),
    {reply, ok, State#state{conf = Conf}};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info({bot_stats, Stats}, State = #state{stats = AllStats}) ->
    AllStats2 = maps:fold(
        fun (K, V, Acc) ->
            maps:update_with(K, fun (V2) -> V2 + V end, V, Acc)
        end,
        AllStats,
        Stats
    ),
    {noreply, State#state{stats = AllStats2}};
handle_info({send_stats}, State = #state{stats = AllStats, parent_pid = ParentPid}) ->
    ParentPid ! {farm_stats, AllStats},
    {noreply, State#state{stats = #{}}};
handle_info(_Info, State = #state{}) ->
    ?INFO("stuff here ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, State = #state{bots = Bots, name = Name, tref_stats = Tref}) ->
    ?INFO("terminating farm ~p with ~p bots", [Name, length(Bots)]),
    % stop all the bots
    scale_bots(0, State),
    timer:cancel(Tref),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

scale_bots(N, #state{num_bots = OldNumBots} = State) when N >= OldNumBots ->
    start_bots_to(N, State);
scale_bots(N, #state{num_bots = OldNumBots} = State) when N < OldNumBots ->
    stop_bots_from(N, State).


% increase the number of bots to NumBots
start_bots_to(NumBots, #state{bots = Bots, name = FarmName, conf = Conf} = State) ->
    NewBots = lists:map(
        fun(Index) ->
            BotName = util:to_atom(util:to_list(FarmName) ++ "_" ++ util:to_list(Index)),
            % TODO: handle the error when the bot is already running
            {ok, Pid} = ha_bot:start_link(BotName),
            % give the new bots the conf
            ha_bot:set_conf(Pid, Conf),
            Pid
        end,
        lists:seq(length(Bots) + 1, NumBots)),
    Bots2 = Bots ++ NewBots,
    State#state{
        num_bots = NumBots,
        bots = Bots2
    }.

% stop bots with index higher then NumBots
stop_bots_from(NumBots, #state{bots = Bots} = State) ->
    BotsToStop = lists:sublist(Bots, NumBots + 1, length(Bots) - NumBots),
    BotsToKeep = lists:sublist(Bots, NumBots),
    % If you use the regular ha_bot:stop it times out when the bots are busy with actions
    % However this async_stop can cause bots to stay up for some time.
    lists:map(fun ha_bot:async_stop/1, BotsToStop),
    State#state{
        bots = BotsToKeep,
        num_bots = NumBots
    }.


