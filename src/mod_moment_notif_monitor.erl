%%%-------------------------------------------------------------------------------------------
%%% File    : mod_moment_notif_monitor.erl
%%%
%%% Copyright (C) 2023 HalloApp inc.
%%%
%%% Alert system for if daily moment notifications are working
%%%-------------------------------------------------------------------------------------------

-module(mod_moment_notif_monitor).
-author(murali).

-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("feed.hrl").
-include("proc.hrl").
-include("time.hrl").
-include("ha_types.hrl").


%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

-export([
    reassign_jobs/0,
    unschedule/0,
    check_and_schedule/0,
    schedule/0,
    monitor_all_regions/0,

    check_and_send_moment_notifications/9,
    start_timer_moment_notification/9,
    send_moment_notification/8,

    monitor_all_regions/1,
    moment_notif_timer_alert/4,
    moment_notif_timer_started/2,
    count_send_moment_notifs/5,
    sent_moment_notification/4,
    uid_count_timer_alert/5
]).

-define(ALLOWED_DIFFERENCE_RATE, 2.0).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ejabberd_hooks:add(reassign_jobs, ?MODULE, reassign_jobs, 10),
    ejabberd_hooks:add(check_and_send_moment_notifications, katchup, ?MODULE, check_and_send_moment_notifications, 50),
    ejabberd_hooks:add(start_timer_moment_notification, katchup, ?MODULE, start_timer_moment_notification, 50),
    ejabberd_hooks:add(send_moment_notification, katchup, ?MODULE, send_moment_notification, 50),
    check_and_schedule(),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ejabberd_hooks:delete(reassign_jobs, ?MODULE, reassign_jobs, 10),
    ejabberd_hooks:delete(check_and_send_moment_notifications, katchup, ?MODULE, check_and_send_moment_notifications, 50),
    ejabberd_hooks:delete(start_timer_moment_notification, katchup, ?MODULE, start_timer_moment_notification, 50),
    ejabberd_hooks:delete(send_moment_notification, katchup, ?MODULE, send_moment_notification, 50),
    gen_mod:stop_child(?PROC()),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


check_and_schedule() ->
    case util:is_main_stest() of
        true ->
            schedule(),
            monitor_all_regions();
        false -> ok
    end,
    ok.


schedule() ->
    erlcron:cron(monitor_all_regions, {
        {daily, {every, {1, hr}}},
        {?MODULE, monitor_all_regions, []}
    }),
    ok.


unschedule() ->
    erlcron:cancel(monitor_all_regions),
    ok.

%%====================================================================
%% Hooks and API
%%====================================================================

reassign_jobs() ->
    unschedule(),
    check_and_schedule(),
    ok.


start_timer_moment_notification(Region, MinsUntilSend, OffsetHr, _Date, DayOfMonth, NotifId, _NotifType, _PromptRecord, _Reminder) ->
    gen_server:cast(?PROC(), {timer_started, Region, MinsUntilSend, OffsetHr, DayOfMonth, NotifId}),
    ok.


check_and_send_moment_notifications(Region, NumUids, OffsetHr, _Date, DayOfMonth, NotifId, _NotifType, _PromptRecord, _Reminder) ->
    gen_server:cast(?PROC(), {check_and_send_moment_notifs, Region, NumUids, OffsetHr, DayOfMonth, NotifId}),
    ok.


send_moment_notification(Uid, Region, NotificationId, _NotificationTime, _NotificationType, _Prompt, _HideBanner, _Reminder) ->
    gen_server:cast(?PROC(), {send_moment_notification, Uid, Region, NotificationId}),
    ok.


monitor_all_regions() ->
    gen_server:cast(?PROC(), {monitor_all_regions}),
    ok.


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([_Host|_]) ->
    State = #{moment_timers => #{}, uid_count_timers => #{}},
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

handle_cast({timer_started, Region, _MinsUntilSend, _OffsetHr, _Day, _NotifId}, State) ->
    State1 = moment_notif_timer_started(Region, State),
    {noreply, State1};

handle_cast({check_and_send_moment_notifs, Region, NumUids, _OffsetHr, Day, NotifId}, State) ->
    State1 = count_send_moment_notifs(Region, NumUids, Day, NotifId, State),
    {noreply, State1};

handle_cast({send_moment_notification, Uid, Region, NotificationId}, State) ->
    State1 = sent_moment_notification(Uid, Region, NotificationId, State),
    {noreply, State1};

handle_cast({monitor_all_regions}, State) ->
    State1 = monitor_all_regions(State),
    {noreply, State1};

handle_cast(_Request, State) ->
    ?DEBUG("Invalid request, ignoring it: ~p", [_Request]),
    {noreply, State}.


handle_info({moment_notif_timer_alert, Region, Day, NotifId}, State) ->
    State1 = moment_notif_timer_alert(Region, Day, NotifId, State),
    {noreply, State1};

handle_info({uid_count_timer_alert, Region, NumUids, Day, NotifId}, State) ->
    State1 = uid_count_timer_alert(Region, NumUids, Day, NotifId, State),
    {noreply, State1};

handle_info(Request, State) ->
    ?DEBUG("Unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================


monitor_all_regions(State) ->
    CurrentTimestamp = util:now(),
    {{_,_, _}, {CurrentHrGMT, CurrentMinGMT, _}} =
        calendar:system_time_to_universal_time(CurrentTimestamp, second),
    AllRegions = mod_moment_notification2:get_regions(),
    State1 = lists:foldl(
        fun({Region, _Predicate, OffsetHr}, AccState) ->
            %% Get the local time there.
            LocalMinNow = (CurrentHrGMT * 60) + (OffsetHr * 60) + CurrentMinGMT,
            %% Based on the local minute: determine what notification info should be fetched.
            TimestampForNotifInfo = if
                LocalMinNow > (24 * 60) ->
                    %% LocalMinNow is tomorrow in this offset
                    CurrentTimestamp + ?DAYS;
                LocalMinNow < 0 ->
                    %% LocalMinNow is yesterday in this offset
                    CurrentTimestamp - ?DAYS;
                true ->
                    CurrentTimestamp
            end,
            Day = util:get_day(TimestampForNotifInfo),
            %% Fetch the appropriate notification info for that region.
            MomentInfo = model_feed:get_moment_info(TimestampForNotifInfo),
            LocalMinToSend = MomentInfo#moment_notification.mins_to_send,
            NotifId = MomentInfo#moment_notification.id,
            %% Calculate the time to wait for this notification.
            AdjustedLocalMinNow = if
                LocalMinNow > (24 * 60) ->
                    %% LocalMinNow is tomorrow in this offset
                    LocalMinNow - (24 * 60);
                LocalMinNow < 0 ->
                    %% LocalMinNow is yesterday in this offset
                    LocalMinNow + (24 * 60);
                true -> LocalMinNow
            end,
            %% Schedule an alert timer if we are yet to send notification, else ignore.
            MomentTimers = maps:get(moment_timers, AccState, #{}),
            case LocalMinToSend - AdjustedLocalMinNow of
                MinsUntilSend when MinsUntilSend >= 0 ->
                    %% Now schedule an alert timer for these mins + 1 to ensure that the timer_started hook gets triggered by then.
                    %% timer_started hook if triggered correctly will cancel this alert timer.
                    %% If not, this alert timer will send an alert to us indicating that the timer was not fired correctly.
                    MomentTimers = maps:get(moment_timers, AccState, #{}),
                    TRef = case maps:get(Region, MomentTimers, undefined) of
                        undefined ->
                            ?INFO("Setting moment_notif_timer_alert for Region: ~p, Day: ~p, NotifId: ~p, MinsUntilSend: ~p", [Region, Day, NotifId, MinsUntilSend]),
                            {ok, NewTRef} = timer:send_after((MinsUntilSend + 1) * ?MINUTES_MS, self(), {moment_notif_timer_alert, Region, Day, NotifId}),
                            NewTRef;
                        CurrentTRef ->
                            ?DEBUG("Already exists, moment_notif_timer_alert for Region: ~p, Day: ~p, NotifId: ~p, MinsUntilSend: ~p", [Region, Day, NotifId, MinsUntilSend]),
                            CurrentTRef
                    end,
                    AccState#{
                        moment_timers => MomentTimers#{
                            Region => TRef
                        }
                    };
                MinsUntilSend ->
                    ?DEBUG("Skip setting moment_notif_timer_alert for Region: ~p, Day: ~p, NotifId: ~p, MinsUntilSend: ~p", [Region, Day, NotifId, MinsUntilSend]),
                    AccState#{
                        moment_timers => MomentTimers#{
                            Region => undefined
                        }
                    }
            end
        end, State, AllRegions),
    State1.


moment_notif_timer_alert(Region, Day, NotifId, State) ->
    MomentTimers = maps:get(moment_timers, State),
    case maps:get(Region, maps:get(moment_timers, State, #{}), undefined) of
        undefined ->
            ?ERROR("Invalid state to end up in: ~p, Region: ~p, Day: ~p, NotifId: ~p", [State, Region, Day, NotifId]);
        _ ->
            Host = util:get_machine_name(),
            RegionBin = util:to_binary(Region),
            DayBin = util:to_binary(Day),
            NotifIdBin = util:to_binary(NotifId),
            alerts:send_alert(
                <<"Missed daily moment notification for ", RegionBin/binary, " on ", DayBin/binary>>,
                Host,
                <<"critical">>,
                <<"Region: ", RegionBin/binary, " Day: ", DayBin/binary, " NotifId: ", NotifIdBin/binary>>),
            ?ERROR("No Notification timer was started for Region: ~p, Day: ~p, NotifId: ~p", [Region, Day, NotifId])
    end,
    State#{
        moment_timers => MomentTimers#{
            Region => undefined
        }
    }.


moment_notif_timer_started(Region, State) ->
    MomentTimers = maps:get(moment_timers, State),
    TRef = maps:get(Region, MomentTimers, undefined),
    case TRef of
        undefined ->
            ?WARNING("Missing moment_notif alert timer for region: ~p", [Region]);
        _ ->
            Result = timer:cancel(TRef),
            ?INFO("Cancelled moment_notif alert timer for region: ~p, tref: ~p, Result: ~p", [Region, TRef, Result])
    end,
    State#{
        moment_timers => MomentTimers#{
            Region => undefined
        }
    }.


count_send_moment_notifs(Region, NumUids, Day, NotifId, State) ->
    ?INFO("Region: ~p, NumUids: ~p, Day: ~p, NotifId: ~p", [Region, NumUids, Day, NotifId]),
    UidCountTimers = maps:get(uid_count_timers, State, #{}),
    {ok, TRef} = timer:send_after(2 * ?MINUTES_MS, self(), {uid_count_timer_alert, Region, NumUids, Day, NotifId}),
    State#{
        uid_count_timers => UidCountTimers#{
            Region => {NumUids, TRef}
        }
    }.


sent_moment_notification(_Uid, Region, _NotificationId, State) ->
    UidCountTimers = maps:get(uid_count_timers, State, #{}),
    {NumUids, TRef} = case maps:get(Region, UidCountTimers, {undefined, undefined}) of
        {undefined, undefined} ->
            ?WARNING("Missing uid_count_timer alert timer for region: ~p", [Region]),
            {undefined, undefined};
        {TempNumUids, TempTRef} ->
            {TempNumUids - 1, TempTRef}
    end,
    State#{
        uid_count_timers => UidCountTimers#{
            Region => {NumUids, TRef}
        }
    }.


uid_count_timer_alert(Region, NumUids, Day, NotifId, State) ->
    UidCountTimers = maps:get(uid_count_timers, State),
    case maps:get(Region, maps:get(uid_count_timers, State, #{}), {undefined, undefined}) of
        {_, undefined} ->
            ?ERROR("Invalid state to end up in: ~p, Region: ~p, Day: ~p, NotifId: ~p", [State, Region, Day, NotifId]);
        {CurrentNumUids, _TRef} ->
            %% Difference of about 2% on either side is fine.
            SentNumUids = NumUids - CurrentNumUids,
            case (abs(NumUids - SentNumUids) * 100.0 / NumUids) > ?ALLOWED_DIFFERENCE_RATE of
                true ->
                    Host = util:get_machine_name(),
                    
                    DayBin = util:to_binary(Day),
                    RegionBin = util:to_binary(Region),
                    NumUidsBin = util:to_binary(NumUids),
                    CurrentNumUidsBin = util:to_binary(CurrentNumUids),
                    NotifIdBin = util:to_binary(NotifId),
                    alerts:send_alert(
                        <<"Some users in ", RegionBin/binary, " missed daily moment notification on ", DayBin/binary>>,
                        Host,
                        <<"critical">>,
                        <<"Region: ", RegionBin/binary, " ExpectedNumUidsBin: ", NumUidsBin/binary, " CurrentNumUids: ", CurrentNumUidsBin/binary, " NotifId: ", NotifIdBin/binary>>),
                    ?ERROR("Some users in Region: ~p missed daily moment notification on Day: ~p, NotifId: ~p, TotalNumUids: ~p, SentNumUids: ~p", [Region, Day, NotifId, NumUids, SentNumUids]);
                false ->
                    ?INFO("Sent daily notification to SentNumUids/TotalNumUids: ~p/~p in Region: ~p on Day: ~p, NotifId: ~p", [SentNumUids, NumUids, Region, Day, NotifId]),
                    ok
            end
    end,
    State#{
        uid_count_timers => UidCountTimers#{
            Region => {undefined, undefined}
        }
    }.


