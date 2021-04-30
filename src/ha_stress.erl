%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% This module is used to generate stress tests for the HalloApp backend.
%%% This control module can start N ha_bots split over M ha_bot_farms running
%%% on a set of erlang nodes in a cluster.
%%% @end
%%% Created : 15. Mar 2021 4:52 PM
%%%-------------------------------------------------------------------
-module(ha_stress).
-author("nikola").

-behaviour(gen_server).

-include("logger.hrl").

%% API
-export([
    start_link/0,
    start_bots/3,
    set_bots/1,
    set_conf/1,
    stop/0,
    get_conf/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).
-define(STATS_TIME, 10000). % stats inteval 10s

-record(state, {
    num_bots = 0 :: integer(),
    num_farms = 0 :: integer(),
    farms = [] :: list(pid()),
    conf = #{} :: map(),
    stats = #{} :: map(),
    tref_stats :: timer:tref()
}).

% TODO: load the conf from files. Have different conf files
-define(CONF, #{
%%    http_host => "127.0.0.1",
%%    http_port => "5580",
    % TODO: make something so that we don't have to change those all the time
    http_host => "tf-lb-stress-http-1307834085.us-east-2.elb.amazonaws.com",
    http_port => "80",
    app_host => "tf-lb-stress-app-bba78369e1c20a78.elb.us-east-2.amazonaws.com",
    app_port => 5210,
    % action_NAME => {Frequency, ActionArguments}
%%    action_register => {0.2, {}},
    % TODO: add more actions here
%%    action_register_and_phonebook => {0.1, {100}},
%%    action_phonebook_full_sync => {0.001, {100}},
%%    action_send_im => {0.5, {100}},
%%    action_recv_im => {0.2, {}},
    action_post => {0.1, {100, 20}},
    phonebook_size => 300,
    phone_pattern => "12..555...." % dots get replaced with random digits
}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec start_bots(NumBots :: integer(), NumFarms :: integer(), Nodes :: [node()]) -> ok.
start_bots(NumBots, NumFarms, Nodes) ->
    gen_server:call(?SERVER, {start_bots, NumBots, NumFarms, Nodes}).

-spec set_bots(NumBots :: integer()) -> ok.
set_bots(NumBots) ->
    gen_server:call(?SERVER, {set_bots, NumBots}, 30000).

-spec set_conf(map()) -> ok | {error, term()}.
set_conf(Conf) ->
    gen_server:call(?SERVER, {set_conf, Conf}, 30000).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?SERVER, normal, 30000).

-spec get_conf() -> map().
get_conf() ->
    ?CONF.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    {ok, Tref} = timer:send_interval(?STATS_TIME, self(), {report_stats}),
    {ok, #state{tref_stats = Tref}}.

%% @private
%% @doc Handling call messages
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
        State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call({start_bots, NumBots, NumFarms, Nodes}, _From, State = #state{}) ->
    ?INFO("Starting ~p bots on ~p farms, nodes: ~p", [NumBots, NumFarms, Nodes]),
    BotsPerFarm = NumBots div NumFarms,

    Farms = start_farms(NumFarms, BotsPerFarm, Nodes),
    State2 = State#state{
        num_bots = NumBots,
        num_farms = NumFarms,
        farms = Farms
    },
    {reply, ok, State2};
handle_call({set_bots, NumBots}, _From,
        #state{num_farms = NumFarms, farms = Farms} = State) ->
    BotsPerFarm = NumBots div NumFarms,
    [ha_bot_farm:set_bots(Farm, BotsPerFarm) || Farm <- Farms],
    State2 = State#state{num_bots = NumBots},
    {reply, ok, State2};
handle_call({set_conf, Conf}, _From, #state{farms = Farms} = State) ->
    lists:foreach(
        fun (Pid) ->
            ha_bot_farm:set_conf(Pid, Conf)
        end,
        Farms),
    {reply, ok, State#state{conf = Conf}};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info({farm_stats, Stats}, State = #state{stats = AllStats}) ->
    AllStats2 = maps:fold(
        fun (K, V, Acc) ->
            maps:update_with(K, fun (V2) -> V2 + V end, V, Acc)
        end,
        AllStats,
        Stats
    ),
    {noreply, State#state{stats = AllStats2}};
handle_info({report_stats}, State = #state{stats = AllStats}) ->
    ?INFO("TOTAL stats: ~p", [AllStats]),
    {noreply, State#state{stats = #{}}};
handle_info(_Info, State = #state{}) ->
    {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
        State :: #state{}) -> term()).

terminate(Reason, _State = #state{farms = Farms, tref_stats = Tref}) ->
    ?INFO("terminating ~p", [Reason]),
    lists:map(
        fun(Pid) ->
            ?INFO("Stoping farm ~p", [Pid]),
            ha_bot_farm:stop(Pid)
        end,
        Farms),
    timer:cancel(Tref),
    ok.

%% @private
%% @doc Convert process state when code is changed
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
        Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

% make sure the List is at least size N otherwise extends the list with itself
extend(List, N) when length(List) >= N ->
    List;
extend(List, N) ->
    extend(List ++ List, N).


start_farms(NumFarms, BotsPerFarm, Nodes) ->
    % make sure we have more nodes then NumFarms
    Nodes2 = extend(Nodes, NumFarms),
    IndexedNodes = lists:zip(lists:seq(1, NumFarms), lists:sublist(Nodes2, NumFarms)),
    lists:map(
        fun({Index, Node}) ->
            Name = list_to_atom("ha_bot_farm_" ++ integer_to_list(Index)),
            ?INFO("Starting farm ~p on node ~p", [Name, Node]),
            % TODO: use async_call for faster startup
            {ok, Pid} = rpc:call(Node, ha_bot_farm, start, [Name, BotsPerFarm, self()]),
            % TODO: we should erlang:monitor the farms,
            ?INFO("Farm ~p started ~p", [Name, Pid]),
            Pid
        end,
        IndexedNodes).


