%%%-------------------------------------------------------------------
%%% File    : ejabberd_monitor.erl
%%%
%%% copyright (C) 2020, HalloApp, Inc
%%%
%% This is a worker process under the main root supervisor of the application.
%% Currently, this monitors only child processes of ejabberd_gen_mod_sup.
%% TODO(murali@): Extend this to monitor siblings and other processes as well.
%%%-------------------------------------------------------------------

-module(ejabberd_monitor).
-author('murali').

-behaviour(gen_server).

-include("logger.hrl").

-define(ALERTS_MANAGER_URL, "http://monitor.halloapp.net:9093/api/v1/alerts").
-record(state,
{
    monitors :: maps:map()
}).


-export([start_link/0]).
%% gen_server callbacks
-export([
    init/1,
    stop/0,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export([
    monitor/1,
    send_alert/1    %% Test
]).



start_link() ->
    ?INFO("Starting monitoring process: ~p", [?MODULE]),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


monitor(Proc) ->
    gen_server:cast(?MODULE, {monitor, Proc}),
    ok.


stop() ->
    ejabberd_sup:stop_child(?MODULE).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                     gen_server callbacks                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% TODO(murali@): we must consider moving the state to redis.
%% Since, if this process crashes: restarting this process will lose all our monitor references.
init([]) ->
    ?INFO("Start: ~p", [?MODULE]),
    process_flag(trap_exit, true),
    {ok, #state{monitors = #{}}}.


terminate(_Reason, _State) ->
    ?INFO("Terminate: ~p", [?MODULE]),
    ok.


handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast({monitor, Proc}, #state{monitors = Monitors} = State) ->
    Pid = whereis(Proc),
    ?INFO("Monitoring process name: ~p, pid: ~p", [Proc, Pid]),
    Ref = erlang:monitor(process, Proc),
    NewState = State#state{monitors = Monitors#{Ref => Proc}},
    {noreply, NewState};

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info({'DOWN', Ref, process, Pid, Reason}, #state{monitors = Monitors} = State) ->
    ?ERROR("process down, pid: ~p, reason: ~p", [Pid, Reason]),
    Proc = maps:get(Ref, Monitors, undefined),
    case Proc of
        undefined ->
            ?ERROR("Monitor's reference missing: ~p", [Ref]);
        _ ->
            Response = send_alert(Proc),
            ?DEBUG("alerts response: ~p", [Response]),
            case Response of
                {ok, {{_, 200, _}, _ResHeaders, _ResBody}} ->
                    ?INFO("Sent an alert successfully.", []);
                _ ->
                    ?ERROR("Failed sending an alert: ~p", [Response])
            end
    end,
    NewMonitors = maps:remove(Ref, State#state.monitors),
    NewState = State#state{monitors = NewMonitors},
    {noreply, NewState};

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% TODO(murali@): add counters here.
send_alert(Proc) ->
    URL = ?ALERTS_MANAGER_URL,
    Headers = [],
    Type = "application/json",
    Body = compose_alerts_body(Proc),
    HTTPOptions = [],
    Options = [],
    ?DEBUG("alerts_url : ~p", [URL]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    Response.


compose_alerts_body(Proc) ->
    jiffy:encode([#{
        <<"status">> => <<"firing">>,
        <<"labels">> => #{
            <<"alertname">> => <<"Process Down">>,
            <<"service">> => util:to_binary(Proc),
            <<"severity">> => <<"critical">>,
            <<"instance">> => util:to_binary(node())
        }
    }]).


