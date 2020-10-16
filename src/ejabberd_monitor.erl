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
    send_alert/4,
    send_process_down_alert/2    %% Test
]).



start_link() ->
    ?INFO("Starting monitoring process: ~p", [?MODULE]),
    Result = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
    monitor_ejabberd_processes(),
    Result.


monitor_ejabberd_processes() ->
    lists:foreach(fun monitor/1, get_processes_to_monitor()),
    %% Monitor all our child gen_servers of ejabberd_gen_mod_sup.
    lists:foreach(
        fun ({ChildId, _, _, _}) ->
            monitor(ChildId)
        end, supervisor:which_children(ejabberd_gen_mod_sup)),
    ok.


monitor(Proc) ->
    gen_server:cast(?MODULE, {monitor, Proc}),
    ok.


stop() ->
    ejabberd_sup:stop_child(?MODULE).


send_alert(Alertname, Service, Severity, Message) ->
    gen_server:cast(?MODULE, {send_alert, Alertname, Service, Severity, Message}).


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

handle_cast({send_alert, Alertname, Service, Severity, Message}, #state{} = State) ->
    ?INFO("send_alert, alertname: ~p, service: ~p, severity: ~p", [Alertname, Service, Severity]),
    {_Response, NewState} = send_alert(Alertname, Service, Severity, Message, State),
    {noreply, NewState};

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info({'DOWN', Ref, process, Pid, Reason}, #state{monitors = Monitors} = State) ->
    ?ERROR("process down, pid: ~p, reason: ~p", [Pid, Reason]),
    Proc = maps:get(Ref, Monitors, undefined),
    case Proc of
        undefined ->
            ?ERROR("Monitor's reference missing: ~p", [Ref]),
            NewState = State;
        _ ->
            {Response, NewState} = send_process_down_alert(Proc, State),
            ?DEBUG("alerts response: ~p", [Response]),
            case Response of
                {ok, {{_, 200, _}, _ResHeaders, _ResBody}} ->
                    ?INFO("Sent an alert successfully.", []);
                _ ->
                    ?ERROR("Failed sending an alert: ~p", [Response])
            end
    end,
    NewMonitors = maps:remove(Ref, NewState#state.monitors),
    FinalState = NewState#state{monitors = NewMonitors},
    {noreply, FinalState};

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% TODO(murali@): add counters here.
send_process_down_alert(Proc, State) ->
    Alertname = <<"Process Down">>,
    Service = util:to_binary(Proc),
    Severity = <<"critical">>,
    Message = <<>>,
    send_alert(Alertname, Service, Severity, Message, State).


send_alert(Alertname, Service, Severity, Message, State) ->
    URL = ?ALERTS_MANAGER_URL,
    Headers = [],
    Type = "application/json",
    Body = compose_alerts_body(Alertname, Service, Severity, Message),
    HTTPOptions = [],
    Options = [],
    ?DEBUG("alerts_url : ~p", [URL]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    {Response, State}.


compose_alerts_body(Alertname, Service, Severity, Message) ->
    jiffy:encode([#{
        <<"status">> => <<"firing">>,
        <<"labels">> => #{
            <<"alertname">> => Alertname,
            <<"service">> => Service,
            <<"severity">> => Severity,
            <<"instance">> => util:to_binary(node()),
            <<"message">> => Message
        }
    }]).


get_processes_to_monitor() ->
    [
        ejabberd_auth,
        ejabberd_local,
        ejabberd_cluster,
        ejabberd_iq,
        ejabberd_hooks,
        ejabberd_listener,
        ejabberd_router,
        ejabberd_router_multicast,
        ejabberd_s2s,
        ejabberd_sm,
        ejabberd_gen_mod_sup
    ].

