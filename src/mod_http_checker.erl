%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 30. Jul 2021 11:19 AM
%%%-------------------------------------------------------------------
-module(mod_http_checker).
-author("josh").

-include("logger.hrl").
-include("monitor.hrl").
-include("proc.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

%% API
-export([
    get_state_history/1,
    ping_ports/0
]).

%%====================================================================
%% API
%%====================================================================

-spec get_state_history(Url :: string()) -> list(proc_state()).
get_state_history(Url) ->
    util_monitor:get_state_history(?HTTP_TABLE, Url).


ping_ports() ->
    gen_server:cast(?PROC(), ping_ports).

%%====================================================================
%% gen_mod API
%%====================================================================

start(Host, Opts) ->
    case util:get_machine_name() of
        <<"s-test">> -> gen_mod:start_child(?MODULE, Host, Opts, ?PROC());
        _ -> ok
    end.

stop(_Host) ->
    case util:get_machine_name() of
        <<"s-test">> -> gen_mod:stop_child(?PROC());
        _ -> ok
    end.

depends(_Host, _Opts) -> [].

reload(_Host, _NewOpts, _OldOpts) -> ok.

mod_options(_Host) -> [].

%%====================================================================
%% gen_server API
%%====================================================================

init(_) ->
    ets:new(?HTTP_TABLE, [named_table, public]),
    {ok, TRef} = timer:apply_interval(?PING_INTERVAL_MS, ?MODULE, ping_ports, []),
    {ok, #{mrefs => #{}, tref => TRef}}.


terminate(_Reason, #{tref := TRef}) ->
    timer:cancel(TRef),
    ok.


handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast(ping_ports, State) ->
    NewState = check_states(State),
    NewState2 = send_http_requests(NewState),
    {noreply, NewState2};

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


%% handles return message from async httpc request
handle_info({http, {Ref, {{_, 200, "OK"}, _Hdrs, _Res}}}, #{mrefs := MRefs} = State) ->
    case maps:get(Ref, MRefs, undefined) of
        undefined -> ?ERROR("Monitor reference not in state");
        Ip -> record_state(Ip, ?ALIVE_STATE)
    end,
    NewMRefs = maps:remove(Ref, MRefs),
    {noreply, maps:put(mrefs, NewMRefs, State)};

handle_info({http, {Ref, {{_, Code, Msg}, _Hdrs, _Res}}}, #{mrefs := MRefs} = State) ->
    case maps:get(Ref, MRefs, undefined) of
        undefined -> ?ERROR("Monitor reference not in state");
        Ip ->
            ?WARNING("HTTP unexpected response, ip: ~p, Code: ~p ~p", [Ip, Code, Msg]),
            record_state(Ip, ?FAIL_STATE)
    end,
    NewMRefs = maps:remove(Ref, MRefs),
    {noreply, maps:put(mrefs, NewMRefs, State)};

handle_info({http, {Ref, {error, Reason}}}, #{mrefs := MRefs} = State) ->
    case maps:get(Ref, MRefs, undefined) of
        undefined -> ?ERROR("Monitor reference not in state");
        Ip ->
            ?ERROR("HTTP failure, ip: ~p, reason: ~p", [Ip, Reason]),
            record_state(Ip, ?FAIL_STATE)
    end,
    NewMRefs = maps:remove(Ref, MRefs),
    {noreply, maps:put(mrefs, NewMRefs, State)};

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

-spec record_state(Ip :: string(), State :: proc_state()) -> ok.
record_state(Ip, State) ->
    util_monitor:record_state(?HTTP_TABLE, Ip, State).


send_http_requests(#{mrefs := MRefs} = State) ->
    NewMRefs = lists:foldl(
        fun(Url, AccMap) ->
            Ip = get_ip_from_url(Url),
            {ok, Ref} = httpc:request(get, {Url, []}, [{timeout, ?PING_TIMEOUT_MS}], [{sync, false}]),
            maps:put(Ref, Ip, AccMap)
        end,
        MRefs,
        get_all_urls()),
    maps:put(mrefs, NewMRefs, State).


send_stats(Name, StateHistory) ->
    Window = ?MINUTES_MS div ?PING_INTERVAL_MS,
    SuccessRate = 1 - (util_monitor:get_num_fails(lists:sublist(StateHistory, Window)) / Window),
    stat:gauge(?NS, "port_uptime", round(SuccessRate * 100), [{ip, Name}]),
    ok.

%%====================================================================
%% Checker functions
%%====================================================================

-spec check_consecutive_fails({Name :: string(), Ip :: string()}, StateHistory :: [proc_state()]) -> boolean().
check_consecutive_fails({Name, Ip}, StateHistory) ->
    case util_monitor:check_consecutive_fails(StateHistory) of
        false -> false;
        true ->
            ?ERROR("Sending unreachable port alert for ~p (~p), url: ~p", [Name, Ip, get_url_from_ip(Ip)]),
            BinName = util:to_binary(Name),
            BinNumConsecFails = util:to_binary(?CONSECUTIVE_FAILURE_THRESHOLD),
            Msg = <<BinName/binary, "'s /api/_ok page has failed last ", BinNumConsecFails/binary, " pings">>,
            alerts:send_port_unreachable_alert(BinName, Msg),
            true
    end.


-spec check_slow({Name :: string(), Ip :: string()}, StateHistory :: [proc_state()]) -> boolean().
check_slow({Name, Ip}, StateHistory) ->
    case util_monitor:check_slow(StateHistory) of
        {false, _} -> false;
        {true, PercentFails} ->
            ?ERROR("Sending slow process alert for ~p (~p), url: ~p", [Name, Ip, get_url_from_ip(Ip)]),
            BinName = util:to_binary(Name),
            Msg = <<BinName/binary, " failing ", (util:to_binary(PercentFails))/binary," of pings to its /api/_ok page">>,
            alerts:send_port_slow_alert(BinName, Msg),
            true
    end.


check_states(State) ->
    %% Check state histories and maybe trigger an alert
    lists:foreach(
        fun({Name, Ip}) ->
            StateHistory = get_state_history(Ip),
            %% do checks until one returns true (meaning an alert has been sent)
            check_consecutive_fails({Name, Ip}, StateHistory)
                orelse check_slow({Name, Ip}, StateHistory),
            send_stats(Name, StateHistory)
        end,
        get_all_ips()),
    State.

%%====================================================================
%% Getter functions
%%====================================================================

get_static_urls() -> [
    {"load_balancer", "https://api.halloapp.net:443/api/_ok"}
].


get_all_ips() ->
    IpsFromUrl = lists:map(fun({Name, Url}) -> {Name, get_ip_from_url(Url)} end, get_static_urls()),
    IpsFromUrl ++ mod_aws:get_ejabberd_machines().


get_all_urls() ->
    UrlsFromIp = lists:map(fun({_Name, Ip}) -> get_url_from_ip(Ip) end, mod_aws:get_ejabberd_machines()),
    StaticUrls = lists:map(fun({_Name, Url}) -> Url end, get_static_urls()),
    lists:concat([UrlsFromIp, StaticUrls]).


get_ip_from_url(Url) ->
    [_Protocol, [], IpAndMaybePort | _Rest] = string:split(Url, "/", all),
    [Ip | _MaybePort] = string:split(IpAndMaybePort, ":"),
    Ip.


get_url_from_ip(Ip) ->
    lists:concat(["http://", Ip, ":5580/api/_ok"]).

