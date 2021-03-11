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
    start_link/2,
    start_link/0,
    stop/1,
    set_bots/2,
    set_conf/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    name :: term(),
    num_bots = 0 :: integer(),
    bots = [] :: list(),
    conf = #{} :: map()
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link(Name, NumBots) ->
    gen_server:start_link({global, Name}, ?MODULE, [Name, NumBots], []).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [?SERVER, 0], []).

stop(Pid) ->
    gen_server:stop(Pid, normal, 30000).

set_bots(Pid, NumBots) ->
    gen_server:call(Pid, {set_bots, NumBots}, 30000).

set_conf(Pid, Conf) ->
    gen_server:call(Pid, {set_conf, Conf}, 30000).

init([Name, NumBots]) ->
    ?INFO("Starting Farm: ~p NumBots: ~p", [Name, NumBots]),
    State = #state{
        name = Name
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

handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, State = #state{bots = Bots, name = Name}) ->
    ?INFO("terminating farm ~p", [Name]),
    % stop all the bots
    scale_bots(0, State),
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


