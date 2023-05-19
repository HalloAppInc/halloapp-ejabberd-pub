%%%-------------------------------------------------------------------
%%% File: mod_moment_notification.erl
%%% copyright (C) 2022, HalloApp, Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_moment_notification2).
-author(josh).
-behaviour(gen_mod).

-include("logger.hrl").
-include("feed.hrl").
-include("packets.hrl").
-include("prompts.hrl").
-include("time.hrl").
-include("util_redis.hrl").
-include("account.hrl").
-include("moments.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1, depends/2]).

-export([
    register_user/4,
    re_register_user/4,
    check_and_schedule/0,
    schedule/0,
    unschedule/0,
    send_latest_notification/2,
    maybe_schedule_notifications/0,
    maybe_schedule_moment_notif/2,
    check_and_send_moment_notifications/8,
    send_moment_notification/9,
    send_moment_notification_async/9,
    get_region_offset_hr_by_sec/1,
    get_region_offset_hr/1,
    get_region_offset_hr/2,
    get_region_by_zone_offset_sec/1,
    get_region_by_uid/1,
    get_current_offsets/1,
    is_region_offset_hr/1,
    get_regions/0,
    send_latest_notification/3,
    get_fallback_region/0,
    get_region_by_zone_offset_hr/1
]).

%% Hooks
-export([reassign_jobs/0]).

-define(REMINDER_TIME, 7 * ?HOURS).
-define(NUM_MOMENT_NOTIF_SENDER_PROCS, 10).

%%====================================================================
%% Region definitions
%%====================================================================

-spec get_regions() -> [{RegionName :: atom(), Predicate :: fun((ZoneOffsetHr :: integer()) -> boolean()), OffsetHrToSend :: integer()}].
get_regions() ->
    %% RegionName is an atom that the region is referred to as (e.g. america, europe, etc.)
    %% Predicate is a function that takes a ZoneOffsetHr and returns true if it is within the region, false otherwise
    %% OffsetHrToSend is the ZoneOffsetHr within that region that the moment notification should send
    %%     e.g. if OffsetHrToSend is -5, all the moment notifications for that region will be sent
    %%     when the moment notification time in GMT-5 is reached
    [
        {america, fun(Hr) -> -10 =< Hr andalso Hr =< -3 end, get_hr_to_send_america()},   %% PST (California)
        {europe, fun(Hr) -> -3 < Hr andalso Hr < 3 end, get_hr_to_send_europe()},         %% GMT (UK)
        {west_asia, fun(Hr) -> 3 =< Hr andalso Hr < 5 end, 3},                            %% Saudi Arabia
        {east_asia, fun(Hr) -> 5 =< Hr orelse Hr < -10 end, 6}                            %% India
    ].


get_fallback_region() ->
    %% Currently fallback to the US if no region info can be determined otherwise
    america.


get_hr_to_send_america() ->
    case util:is_dst_america(util:now() - (8 * ?HOURS)) of
        true -> -7;
        false -> -8
    end.


get_hr_to_send_europe() ->
    case util:is_dst_europe(util:now()) of
        true -> 1;
        false -> 0
    end.

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    ejabberd_hooks:add(reassign_jobs, ?MODULE, reassign_jobs, 10),
    spawn(?MODULE, check_and_schedule, []),
    ejabberd_hooks:add(register_user, katchup, ?MODULE, register_user, 1),
    ejabberd_hooks:add(re_register_user, katchup, ?MODULE, re_register_user, 1),
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ejabberd_hooks:delete(reassign_jobs, ?MODULE, reassign_jobs, 10),
    case util:is_main_stest() of
        true ->
            unschedule();
        false ->
            ok
    end,
    ejabberd_hooks:delete(register_user, katchup, ?MODULE, register_user, 1),
    ejabberd_hooks:delete(re_register_user, katchup, ?MODULE, re_register_user, 1),
    ok.

depends(_Host, _Opts) ->
    [{mod_moment_notif_monitor, hard}].

mod_options(_Host) ->
    [].

%%====================================================================
%% Hooks
%%====================================================================

reassign_jobs() ->
    unschedule(),
    check_and_schedule(),
    ok.


-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
register_user(Uid, _Server, _Phone, _CampaignId) ->
    ?INFO("Uid: ~s", [Uid]),
    send_latest_notification(Uid, true),
    ok.


-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
re_register_user(Uid, _Server, _Phone, _CampaignId) ->
    ?INFO("Uid: ~s", [Uid]),
    %% Clear out any recent moment notifications sent.
    %% This will enable us to send another again if necessary.
    Today = util:get_day(util:now()),
    Yesterday = util:get_day(util:now() - ?DAYS),
    DayBeforeYesterday = util:get_day(util:now() - (2 * ?DAYS)),
    Tomorrow = util:get_day(util:now() + ?DAYS),
    DayAfterTomorrow = util:get_day(util:now() + (2 * ?DAYS)),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(DayBeforeYesterday)),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(Yesterday)),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(Today)),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(Tomorrow)),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(DayAfterTomorrow)),
    send_latest_notification(Uid, true),
    ok.


check_and_schedule() ->
    case util:is_main_stest() of
        true ->
            %% Process last two hours again in case notifications were lost
            %% because of server restart.
            ?INFO("Server restart – process current hour", []),
            maybe_schedule_moment_notif(util:now(), false),
            ?INFO("Server restart – process 1 hour prior", []),
            maybe_schedule_moment_notif(util:now() - ?HOURS, true),
            schedule();
        false -> ok
    end,
    ok.


schedule() ->
    erlcron:cron(maybe_schedule_notifications, {
        {daily, {every, {1, hr}}},
        {?MODULE, maybe_schedule_notifications, []}
    }),
    ok.


unschedule() ->
    erlcron:cancel(maybe_schedule_notifications),
    ok.

%%====================================================================
%% API
%%====================================================================

%% Sends latest notification immediately, intentionally hides banner on the client.
send_latest_notification(Uid, HideBanner) ->
    send_latest_notification(Uid, util:now(), HideBanner).

send_latest_notification(Uid, CurrentTime, HideBanner) ->
    %% Figure out which region's offset is assigned to this user
    Region = get_region_by_uid(Uid),
    OffsetHr = get_region_offset_hr(Region),
    %% Figure out the most recent moment notif to send for the user's offset
    %% Fetch time for today, tomorrow, yesterday and day before yesterday.
    [YesterdayInfoMap, TodayInfoMap, TomorrowInfoMap] = get_current_offsets(CurrentTime),

    TomorrowOffsetHr = maps:get(current_offset_hr, TomorrowInfoMap),
    TodayOffsetHr = maps:get(current_offset_hr, TodayInfoMap),
    YesterdayOffsetHr = maps:get(current_offset_hr, YesterdayInfoMap),

    {{_,_,_}, {Hours, Minutes,_}} = calendar:system_time_to_universal_time(CurrentTime, second),
    CurrentMins = (Hours * 60) + Minutes,
    CurrentLocalMins = CurrentMins + (OffsetHr * 60),

    ?INFO("Sending latest moment notification to ~s with region offset ~p", [Uid, OffsetHr]),

    SendFun = fun(InfoMap, DayOffset) ->
        PromptRecord = mod_prompts:get_prompt_from_id(maps:get(promptId, InfoMap)),
        Image = mod_prompts:get_prompt_image_bytes(PromptRecord#prompt.image_id),
        check_and_send_moment_notification(Uid, Region, maps:get(date, InfoMap), maps:get(day_of_month, InfoMap), maps:get(notif_id, InfoMap),
            util_moments:calculate_notif_timestamp(DayOffset, maps:get(mins_to_send, InfoMap), OffsetHr),
            maps:get(notif_type, InfoMap), PromptRecord, Image, HideBanner, false)
    end,

    if
    %% if Uid is ahead of a certain offset, need to send that moment notification
    %% if OffsetHr is equal to the offset for tomorrow, today, or yesterday, check the minutes to
    %% determine which day's notification needs to be sent
        OffsetHr > TomorrowOffsetHr ->
            SendFun(TomorrowInfoMap, 1);
        OffsetHr =:= TomorrowOffsetHr ->
            case CurrentLocalMins > maps:get(mins_to_send, TomorrowInfoMap) of
                true -> SendFun(TomorrowInfoMap, 1);
                false -> SendFun(TodayInfoMap, 0)
            end;
        OffsetHr > TodayOffsetHr ->
            SendFun(TodayInfoMap, 0);
        OffsetHr =:= TodayOffsetHr ->
            case CurrentLocalMins > maps:get(mins_to_send, TodayInfoMap) of
                true -> SendFun(TodayInfoMap, 0);
                false -> SendFun(YesterdayInfoMap, -1)
            end;
        OffsetHr > YesterdayOffsetHr ->
            SendFun(YesterdayInfoMap, -1);
        OffsetHr =:= YesterdayOffsetHr ->
            case CurrentLocalMins > maps:get(mins_to_send, YesterdayInfoMap) of
                true -> SendFun(YesterdayInfoMap, -1);
                false ->
                    [DayBeforeYesterdayInfoMap, _, _] = get_current_offsets(CurrentTime - ?DAYS),
                    SendFun(DayBeforeYesterdayInfoMap, -2)
            end;
        true ->
            %% if Uid isn't ahead of any of the current offsets, the moment notif is from day before yesterday
            [DayBeforeYesterdayInfoMap, _, _] = get_current_offsets(CurrentTime - ?DAYS),
            SendFun(DayBeforeYesterdayInfoMap, -2)
    end.


%% Every hour, we should check if a moment notification needs to be sent soon (within the hour)
%% We check the offset hours for today, yesterday, and tomorrow that would send within this hour
maybe_schedule_notifications() ->
    maybe_schedule_moment_notif(util:now(), false),
    ok.

maybe_schedule_moment_notif(TodaySecs, IsImmediateNotification) ->
    [YesterdayInfoMap, TodayInfoMap, TomorrowInfoMap] = get_current_offsets(TodaySecs),
    [YesterdayReminderInfoMap, TodayReminderInfoMap, TomorrowReminderInfoMap] = get_reminder_offsets(TodaySecs),

    ?INFO("Times to send - Today: ~p, Yesterday: ~p, Tomorrow: ~p",
        [maps:get(mins_to_send, TodayInfoMap), maps:get(mins_to_send, YesterdayInfoMap),
            maps:get(mins_to_send, TomorrowInfoMap)]),

    ?INFO("Current offset hr for today: ~p, yesterday: ~p, tomorrow: ~p",
        [maps:get(current_offset_hr, TodayInfoMap), maps:get(current_offset_hr, YesterdayInfoMap),
            maps:get(current_offset_hr, TomorrowInfoMap)]),

    ?INFO("Times to send reminder - Today: ~p, Yesterday: ~p, Tomorrow: ~p",
        [maps:get(mins_to_send, TodayReminderInfoMap), maps:get(mins_to_send, YesterdayReminderInfoMap),
            maps:get(mins_to_send, TomorrowReminderInfoMap)]),

    ?INFO("Current reminder offset hr for today: ~p, yesterday: ~p, tomorrow: ~p",
        [maps:get(current_offset_hr, TodayReminderInfoMap), maps:get(current_offset_hr, YesterdayReminderInfoMap),
            maps:get(current_offset_hr, TomorrowReminderInfoMap)]),

    %% Now that we have the offsets that would be sending for each of today, yesterday, and tomorrow
    %% We need to decide if any of those offsets are the actual offset to send for a region
    {{_,_, _}, {CurrentHrGMT, CurrentMinGMT, _}} =
        calendar:system_time_to_universal_time(TodaySecs, second),
    lists:foreach(
        fun(#{day_of_month := DayOfMonth, date := Date, current_offset_hr := OffsetHr, mins_to_send := LocalMinToSend,
            notif_id := NotifId, notif_type := NotifType, promptId := PromptId, reminder := Reminder}) ->
            case check_for_region_offset_hr(OffsetHr) of
                false -> ok;
                {Region, _Predicate, OffsetHr} ->
                    %% It is almost time to send for a particular region (< 1hr)
                    %% Calculate the remaining minutes to wait until sending notification
                    LocalMinNow = (CurrentHrGMT * 60) + (OffsetHr * 60) + CurrentMinGMT,
                    MinsUntilSend = case IsImmediateNotification of
                        true -> 0;
                        false ->
                            AdjustedLocalMinNow = if
                                LocalMinNow > (24 * 60) ->
                                    %% LocalMinNow is tomorrow in this offset
                                    LocalMinNow - (24 * 60);
                                LocalMinNow < 0 ->
                                    %% LocalMinNow is yesterday in this offset
                                    LocalMinNow + (24 * 60);
                                true -> LocalMinNow
                            end,
                            max(0, LocalMinToSend - AdjustedLocalMinNow)
                    end,
                    PromptRecord = mod_prompts:get_prompt_from_id(PromptId),
                    Image = mod_prompts:get_prompt_image_bytes(PromptRecord#prompt.image_id),
                    ?INFO("Scheduling moment notification to send in ~p minutes for OffsetHr ~p, Date: ~p, DayOfMonth: ~p",
                        [MinsUntilSend, OffsetHr, Date, DayOfMonth]),
                    ejabberd_hooks:run(start_timer_moment_notification, ?KATCHUP,
                        [Region, MinsUntilSend, OffsetHr, Date, DayOfMonth, NotifId, NotifType, PromptRecord, Reminder]),
                    timer:apply_after(MinsUntilSend * ?MINUTES_MS, ?MODULE, check_and_send_moment_notifications,
                        [OffsetHr, Date, DayOfMonth, NotifId, NotifType, PromptRecord, Image, Reminder])
            end
        end,
        [YesterdayInfoMap, TodayInfoMap, TomorrowInfoMap, YesterdayReminderInfoMap, TodayReminderInfoMap, TomorrowReminderInfoMap]).


-spec check_and_send_moment_notifications(OffsetHr :: integer(), Date :: string(), DayOfMonth :: integer(), NotifId :: integer(),
    NotifType :: moment_type(), PromptRecord :: prompt_record(), Image :: binary(), Reminder :: boolean()) -> ok.
check_and_send_moment_notifications(OffsetHr, Date, DayOfMonth, NotificationId, NotificationType, PromptRecord, Image, Reminder) ->
    StartTime = util:now_ms(),
    {Region, Predicate, OffsetHr} = lists:keyfind(OffsetHr, 3, get_regions()),
    Uids = get_uids_by_region(Predicate),
    ejabberd_hooks:run(check_and_send_moment_notifications, ?KATCHUP,
        [Region, length(Uids), OffsetHr, Date, DayOfMonth, NotificationId, NotificationType, PromptRecord, Reminder]),
    %% Spawn some worker processes
    NumWorkers = ?NUM_MOMENT_NOTIF_SENDER_PROCS,
    WorkerPids = lists:map(
        fun(N) ->
            spawn(?MODULE, send_moment_notification_async, [Region, Date, DayOfMonth, NotificationId, NotificationType, PromptRecord, Image, N, Reminder])
        end,
        lists:seq(1, NumWorkers)),
    %% Send Uids to the worker processes for moment notifications to be sent
    lists:foldl(
        fun(Uid, N) ->
            lists:nth((N rem NumWorkers) + 1, WorkerPids) ! Uid,
            N + 1
        end,
        0,
        Uids),
    %% Terminate the worker processes
    lists:foreach(fun(Pid) -> Pid ! done end, WorkerPids),
    TotalTime = (util:now_ms() - StartTime) / 1000,
    ?INFO("Finish assgining ~p uids in ~p to ~p workers to send moment notifications, took ~p seconds",
        [length(Uids), Region, NumWorkers, TotalTime]),
    ok.


send_moment_notification_async(Region, Date, DayOfMonth, NotificationId, NotificationType, PromptRecord, Image, Name, Reminder) ->
    receive
        done ->
            ok;
        Uid ->
            check_and_send_moment_notification(Uid, Region, Date, DayOfMonth, NotificationId, util:now(), NotificationType, PromptRecord, Image, false, Reminder),
            send_moment_notification_async(Region, Date, DayOfMonth, NotificationId, NotificationType, PromptRecord, Image, Name, Reminder)
    end.


%% Before sending, check to ensure a notification has not been sent to this user on this date
check_and_send_moment_notification(Uid, Region, Date, DayOfMonth, NotificationId, NotificationTimestamp, NotificationType, PromptRecord, Image, HideBanner, Reminder) ->
    %% Check if it is a reminder or if it can be sent the first time.
    case Reminder orelse model_accounts:mark_moment_notification_sent(Uid, util:to_binary(DayOfMonth)) of
        true ->
            AppType = util_uid:get_app_type(Uid),
            stat:count(util:get_stat_namespace(AppType) ++ "/moment_notif", "send"),
            Prompt = mod_prompts:get_prompt_text(Uid, PromptRecord),
            send_moment_notification(Uid, Date, NotificationTimestamp, NotificationId, NotificationType, Prompt, Image, HideBanner, Reminder),
            ejabberd_hooks:run(send_moment_notification, AppType,
                [Uid, Region, NotificationId, NotificationTimestamp, NotificationType, Prompt, HideBanner, Reminder]);
        NeverSent ->
            ?INFO("NOT Sending moment notification to ~s, already_sent = ~p, date = ~p, dayOfMonth = ~p, reminder: ~p", [Uid, not NeverSent, Date, DayOfMonth, Reminder])
    end.


%% This is the function that actually sends the notification to the client
send_moment_notification(Uid, Date, Timestamp, Id, Type, Prompt, Image, HideBanner, Reminder) ->
    Packet = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = Uid,
        type = headline,
        payload = #pb_moment_notification{
            timestamp = Timestamp,
            notification_id = Id,
            type = Type,
            prompt = Prompt,
            prompt_image = Image,
            hide_banner = HideBanner,
            date = Date,
            reminder = Reminder
        }
    },
    ?INFO("Sending moment notification to ~s | date = ~p, notif_id = ~p, notif_ts = ~p, notif_type = ~p, prompt = ~p, hide_banner = ~p, reminder = ~p",
        [Uid, Date, Id, Timestamp, Type, Prompt, HideBanner, Reminder]),
    ejabberd_router:route(Packet).

%%====================================================================
%% Helper/internal functions
%%====================================================================

get_current_offsets(TodayTimestamp) -> get_current_offsets(TodayTimestamp, false).

get_reminder_offsets(TodayTimestamp) -> get_current_offsets(TodayTimestamp, true).


%% Returns [YesterdayMomentInfoMap, TodayMomentInfoMap, TomorrowMomentInfoMap]
%% Each map has keys: dayOfMonth, date, current_offset_hr, mins_to_send, notif_id, notif_type, prompt
-spec get_current_offsets(TodayTimestamp :: non_neg_integer(), Reminder :: boolean()) -> [map()].
get_current_offsets(TodayTimestamp, Reminder) ->
    %% Based on Timestamp, fetch the zone offset hrs that would send during this hour
    {{_,_, _}, {CurrentHrGMT, _,_}} =
        calendar:system_time_to_universal_time(TodayTimestamp, second),
    {{_,_, _}, {CurrentReminderHrGMT, _,_}} =
        calendar:system_time_to_universal_time(TodayTimestamp - ?REMINDER_TIME, second),

    Inputs = case Reminder of
        false ->
            [
                {(TodayTimestamp - ?DAYS), fun(HrToSend) -> HrToSend - CurrentHrGMT - 24 end, false},
                {TodayTimestamp, fun(HrToSend) -> HrToSend - CurrentHrGMT end, false},
                {(TodayTimestamp + ?DAYS), fun(HrToSend) -> HrToSend - CurrentHrGMT + 24 end, false}
            ];
        true ->
            [
                %% Reminders
                {(TodayTimestamp - ?DAYS - ?REMINDER_TIME), fun(HrToSend) -> HrToSend - CurrentReminderHrGMT - 24 end, true},
                {TodayTimestamp - ?REMINDER_TIME, fun(HrToSend) -> HrToSend - CurrentReminderHrGMT end, true},
                {(TodayTimestamp + ?DAYS - ?REMINDER_TIME), fun(HrToSend) -> HrToSend - CurrentReminderHrGMT + 24 end, true}
            ]
    end,

    lists:map(
        fun({Timestamp, GmtOffsetModifierFun, IsReminder}) ->
            {{_, _, DayOfMonth}, {_, _,_}} =
                calendar:system_time_to_universal_time(Timestamp, second),
            Date = util:time_to_prettydatestring(Timestamp),
            MomentInfo = model_feed:get_moment_info(Timestamp),
            MinToSend = MomentInfo#moment_notification.mins_to_send,
            OffsetHr = GmtOffsetModifierFun((MinToSend div 60)),
            #{
                day_of_month => DayOfMonth,
                date => Date,
                current_offset_hr => OffsetHr,
                mins_to_send => MinToSend,
                notif_id => MomentInfo#moment_notification.id,
                notif_type => MomentInfo#moment_notification.type,
                promptId => MomentInfo#moment_notification.promptId,
                reminder => IsReminder
            }
        end,
        Inputs).

%%====================================================================
%% Getters related to ZoneOffset or Region
%%====================================================================

get_uids_by_region(RegionPredicate) ->
    ZoneOffsetHrs = lists:filter(RegionPredicate, lists:seq(-12, 14)),
    model_accounts:get_uids_from_zone_offset_hrs(ZoneOffsetHrs).


check_for_region_offset_hr(ZoneOffsetHr) ->
    lists:keyfind(ZoneOffsetHr, 3, get_regions()).


is_region_offset_hr(ZoneOffsetHr) ->
    case lists:keyfind(ZoneOffsetHr, 3, get_regions()) of
        false -> false;
        _ -> true
    end.


get_region_offset_hr_by_sec(ZoneOffsetSec) ->
    true = (ZoneOffsetSec =/= undefined),
    get_region_offset_hr(get_region_by_zone_offset_sec(ZoneOffsetSec)).


get_region_offset_hr_by_phone(Phone) ->
    get_region_offset_hr(get_region_by_phone(Phone)).


get_region_offset_hr(ZoneOffsetSec, Phone) ->
    case ZoneOffsetSec =:= undefined of
        false -> get_region_offset_hr_by_sec(ZoneOffsetSec);
        true -> get_region_offset_hr_by_phone(Phone)
    end.


-spec get_region_offset_hr(Region :: atom()) -> integer().
get_region_offset_hr(Region) ->
    case lists:keyfind(Region, 1, get_regions()) of
        false ->
            DefaultRegion = get_fallback_region(),
            ?ERROR("Invalid region: ~p, defaulting to ~p", [Region, DefaultRegion]),
            get_region_offset_hr(DefaultRegion);
        {Region, _, OffsetHrToSend} -> OffsetHrToSend
    end.


get_region_by_phone(Phone) ->
    case mod_libphonenumber:get_cc(Phone) of
        <<"US">> -> america;
        <<"IN">> -> east_asia;
        _ ->
            %% Ignoring everything other than the US for now and we default to the US.
            get_fallback_region()
    end.


get_region_by_zone_offset_hr(ZoneOffsetHr) when is_integer(ZoneOffsetHr) andalso ZoneOffsetHr >= -12 andalso ZoneOffsetHr =< 14 ->
    RegionInfo = get_regions(),
    lists:foldl(
        fun({Region, Predicate, _}, Result) ->
            case Predicate(ZoneOffsetHr) of
                true -> Region;
                false -> Result
            end
        end,
        undefined,
        RegionInfo);
get_region_by_zone_offset_hr(_InvalidZoneOffsetHr) ->
    undefined.


get_region_by_zone_offset_sec(ZoneOffsetSec) when is_integer(ZoneOffsetSec) ->
    get_region_by_zone_offset_hr(util:secs_to_hrs(ZoneOffsetSec));
get_region_by_zone_offset_sec(_) ->
    undefined.


-spec get_region_by_uid(Uid :: uid()) -> maybe(america | europe | west_asia | east_asia).
get_region_by_uid(Uid) ->
    ZoneOffsetSec = model_accounts:get_zone_offset_secs(Uid),
    case get_region_by_zone_offset_sec(ZoneOffsetSec) of
        undefined ->
            case model_accounts:get_phone(Uid) of
                {error, missing} ->
                    DefaultRegion = get_fallback_region(),
                    ?ERROR("No phone for ~s, defaulting to region: ~p", [Uid, DefaultRegion]),
                    get_fallback_region();
                {ok, Phone} ->
                    get_region_by_phone(Phone)
            end;
        Region -> Region
    end.

