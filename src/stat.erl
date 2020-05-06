%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%  Monitoring and API for events.
%%% Data is send to AWS CloudWatch custom metrics.
%%% @end
%%% Created : 04. May 2020 4:42 PM
%%%-------------------------------------------------------------------
-module(stat).
-author("nikola").
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).


%% API
-export([
    count/2,
    count/3
]).


start_link() ->
    gen_server:start_link({local, get_proc()}, ?MODULE, [], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()),
    ok.

stop(Host) ->
    ?INFO_MSG("stop ~w", [?MODULE]),
    gen_mod:stop_child(get_proc()),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).


-spec count(Namespace :: string(), Metric :: string()) -> ok.
count(Namespace, Metric) ->
    count(Namespace, Metric, 1),
    ok.

-spec count(Namespace :: string(), Metric :: string(), Value :: integer()) -> ok.
count(Namespace, Metric, Value) ->
    gen_server:cast(get_proc(), {count, Namespace, Metric, Value}).


init(_Stuff) ->
    process_flag(trap_exit, true),
    % TODO: The initial configuration of erlcloud should probably move
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),
    % TODO: use the state to do 1min aggregation here
    {ok, #{}}.


handle_call(_Message, _From, State) ->
    ?ERROR_MSG("unexpected call ~p from ", _Message),
    {reply, ok, State}.


handle_cast({count, Namespace, Metric, Value}, State) ->
    erlcloud_mon:put_metric_data(Namespace, Metric, integer_to_list(Value), "Count", ""),
    {noreply, State};

handle_cast(_Message, State) -> {noreply, State}.


handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.
