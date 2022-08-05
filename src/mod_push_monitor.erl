%%%-------------------------------------------------------------------------------------------
%%% File    : mod_push_monitor.erl
%%%
%%% Copyright (C) 2022 HalloApp inc.
%%%
%%% Alert system for if push notifications are working
%%%-------------------------------------------------------------------------------------------

-module(mod_push_monitor).
-author(michelle).

-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("proc.hrl").


%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

-export([log_push_status/2, log_push_wakeup/2]).

-ifdef(TEST).
-export([push_monitor/4, check_error_rate/2]).
-endif.

-define(MIN_SAMPLE, 20).
-define(ALERT_RATE, 50).
-define(ERROR_RATE, 25).
-define(WARNING_RATE, 15).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?PROC()),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================
-spec log_push_status(Status :: success | failure, Platform :: ios | android) -> ok.
log_push_status(Status, Platform) ->
    gen_server:cast(?PROC(), {push_status, Status, Platform}),
    ok.


-spec log_push_wakeup(Status :: success | failure, Platform :: ios | android) -> ok.
log_push_wakeup(Status, Platform) ->
    gen_server:cast(?PROC(), {push_wakeup, Status, Platform}),
    ok.


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Host|_]) ->
    State = #{ios_pushes => [], android_pushes => [], ios_wakeup => [], android_wakeup => []},
    {ok, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(_Request, _From, State) ->
    ?ERROR("invalid call request: ~p", [_Request]),
    {reply, {error, invalid_request}, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast({push_status, Status, Platform},
        #{android_pushes := AndroidPushes, ios_pushes := IosPushes} = State) ->
    {AndroidPushes1, IosPushes1} = push_monitor(Status, Platform, AndroidPushes, IosPushes),
    State1 = State#{android_pushes => AndroidPushes1, ios_pushes => IosPushes1},
    {noreply, State1};

handle_cast({push_wakeup, Status, Platform},
        #{android_wakeup := AndroidWakeups, ios_wakeup := IosWakeups} = State) ->
    {AndroidWakeups1, IosWakeups1} = push_monitor(Status, Platform, AndroidWakeups, IosWakeups),
    State1 = State#{android_wakeup => AndroidWakeups1, ios_wakeup => IosWakeups1},
    {noreply, State1};

handle_cast(_Request, State) ->
    ?DEBUG("Invalid request, ignoring it: ~p", [_Request]),
    {noreply, State}.

handle_info(Request, State) ->
    ?DEBUG("Unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

% Logic below (tracking status of last 100 pushes, msgs based on error rate) is used two cases:
% 1. tracking if a push is successfully sent (push_status)
% 2. tracking if a push caused the clients to log on (push_wakeup)
-spec push_monitor(Platform :: ios | android, Status :: success | failure, AndroidData :: [], IosData :: []) -> #{}.
push_monitor(Status, Platform, AndroidData, IosData) ->
    StatusCode = case Status of
        failure -> 0;
        success -> 1
    end,
    {AndroidData2, IosData2} = case {Platform, AndroidData, IosData} of
        {android, [], IosData} ->
            {[StatusCode], IosData};
        {ios, AndroidData, []} ->
            {AndroidData, [StatusCode]};
        % only track the 100 latest pushes
        {android, AndroidData, IosData} ->
            AndroidData1 = lists:sublist([StatusCode] ++ AndroidData, 100),
            check_error_rate(AndroidData1, android),
            {AndroidData1, IosData};
        {ios, AndroidData, IosData} ->
            IosData1 = lists:sublist([StatusCode] ++ IosData, 100),
            check_error_rate(IosData1, ios),
            {AndroidData, IosData1}
    end,
    {AndroidData2, IosData2}.


-spec check_error_rate(Data :: list(), Platform :: ios | android) -> float().
check_error_rate(Data, Platform) ->
    Success = lists:sum(Data),
    Length = length(Data),
    ErrorRate = util:to_float(io_lib:format("~.2f", [100 - (Success/Length * 100)])),
    % throw appropriate msg based on error rate and amount of sample pushes
    case ErrorRate of
        Rate when Rate >= ?ALERT_RATE andalso Length > ?MIN_SAMPLE ->
            Host = util:get_machine_name(),
            BinPercent = util:to_binary(ErrorRate),
            BinPlatform = util:to_binary(Platform),
            BinLength = util:to_binary(Length),
            Msg = <<Host/binary, ": ", BinPlatform/binary, " has error rate of ",
                        BinPercent/binary, "% from ", BinLength/binary, " total pushes">>,
            alerts:send_alert(<<Host/binary, " has high push error rate.">>, Host, <<"critical">>, Msg);
        Rate when Rate >= ?ERROR_RATE andalso Length > ?MIN_SAMPLE ->
            ?ERROR("~p has ~p% error rate from ~p total pushes", [Platform, ErrorRate, Length]);
        Rate when Rate >= ?WARNING_RATE andalso Length > ?MIN_SAMPLE ->
            ?WARNING("~p has ~p% error rate from ~p total pushes", [Platform, ErrorRate, Length]);
        _ ->
            ?INFO("~p has ~p% error rate from ~p total pushes", [Platform, ErrorRate, Length])
    end,
    ErrorRate.

