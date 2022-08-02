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

-export([log_push_status/2]).

-ifdef(TEST).
-export([push_status/3, check_error_rate/2]).
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


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Host|_]) ->
    State = #{ios_pushes => [], android_pushes => []},
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

handle_cast({push_status, Status, Platform}, State) ->
    State1 = push_status(Status, Platform, State),
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

-spec push_status(Platform :: ios | android, Status :: success | failure, State :: #{}) -> #{}.
push_status(Status, Platform, #{ios_pushes := IosPushes, android_pushes := AndroidPushes} = State) ->
    StatusCode = case Status of
        failure -> 0;
        success -> 1
    end,
    {AndroidPushes2, IosPushes2} = case {Platform, AndroidPushes, IosPushes} of
        {android, [], IosPushes} ->
            {[StatusCode], IosPushes};
        {ios, AndroidPushes, []} ->
            {AndroidPushes, [StatusCode]};
        % only track the 100 latest pushes
        {android, AndroidPushes, IosPushes} ->
            AndroidPushes1 = lists:sublist([StatusCode] ++ AndroidPushes, 100),
            check_error_rate(AndroidPushes1, android),
            {AndroidPushes1, IosPushes};
        {ios, AndroidPushes, IosPushes} ->
            IosPushes1 = lists:sublist([StatusCode] ++ IosPushes, 100),
            check_error_rate(IosPushes1, ios),
            {AndroidPushes, IosPushes1}
    end,
    State#{ios_pushes => IosPushes2, android_pushes => AndroidPushes2}.


-spec check_error_rate(Pushes :: list(), Platform :: ios | android) -> float().
check_error_rate(Pushes, Platform) ->
    Success = lists:sum(Pushes),
    Length = length(Pushes),
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

