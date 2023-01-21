%%%-------------------------------------------------------------------
%%% File: mod_moment_notification.erl
%%% copyright (C) 2022, HalloApp, Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_moment_notification).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").
-include("feed.hrl").
-include("packets.hrl").
-include("time.hrl").
-include("util_redis.hrl").
-include("account.hrl").
-include("moments.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1, depends/2]).

-export([
    register_user/4,
    re_register_user/4,
    send_latest_notification/2,
    schedule/0,
    unschedule/0,
    send_notifications/0,
    send_moment_notification/1,
    send_moment_notification/4,
    maybe_send_moment_notification/5,
    maybe_send_moment_notification/6,
    get_four_zone_offset_hr/1,
    fix_zone_tag_uids/1,
    is_time_ok/4,
    get_local_time_in_minutes/4,
    get_local_time_in_minutes/5,
    get_offset_region_by_uid/1,
    process_moment_tag/3
]).

%% Hooks
-export([reassign_jobs/0]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    ejabberd_hooks:add(reassign_jobs, ?MODULE, reassign_jobs, 10),
    check_and_schedule(),
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
    [].

mod_options(_Host) ->
    [].

%%====================================================================
%% Hooks
%%====================================================================

reassign_jobs() ->
    unschedule(),
    check_and_schedule(),
    ok.


check_and_schedule() ->
    case util:is_main_stest() of
        true ->
            %% Process last two hours again in case notifications were lost
            %% because of server restart.
            process_moment_tag([], util:now(), false),
            process_moment_tag([], util:now() - ?MOMENT_TAG_INTERVAL_SEC, true),
            schedule();
        false -> ok
    end,
    ok.



%%====================================================================
%% api
%%====================================================================

-spec schedule() -> ok.
schedule() ->
    ?INFO("Scheduling", []),
    erlcron:cron(send_notifications, {
        {daily, {every, {1, hr}}},
        {?MODULE, send_notifications, []}
    }),
    ok.

-spec unschedule() -> ok.
unschedule() ->
    erlcron:cancel(send_notifications),
    ok.

-spec send_notifications() -> ok.
send_notifications() ->
    process_moment_tag([], util:now(), false),
    ok.

-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
register_user(Uid, _Server, Phone, _CampaignId) ->
    ?INFO("Uid: ~s", [Uid]),
    send_latest_notification(Uid, Phone),
    ok.


-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
re_register_user(Uid, _Server, Phone, _CampaignId) ->
    ?INFO("Uid: ~s", [Uid]),
    %% Clear out any recent moment notifications sent.
    %% This will enable us to send another again if necessary.
    Today = util:get_date(util:now()),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(Today-1)),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(Today-2)),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(Today)),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(Today+1)),
    model_accounts:delete_moment_notification_sent(Uid, util:to_binary(Today+2)),
    send_latest_notification(Uid, Phone),
    ok.


send_latest_notification(Uid, Phone) ->
    %% Fetch time for today, tomorrow, yesterday and day before yesterday.
    TodaySecs = util:now(),
    DayBeforeYesterdaySecs = (TodaySecs - 2*?DAYS),
    YesterdaySecs = (TodaySecs - ?DAYS),
    TomorrowSecs = (TodaySecs + ?DAYS),
    ?DEBUG("TodaySecs: ~p, DayBeforeYesterdaySecs: ~p, YesterdaySecs: ~p, TomorrowSecs: ~p",
        [TodaySecs, DayBeforeYesterdaySecs, YesterdaySecs, TomorrowSecs]),

    Today = util:get_date(TodaySecs),
    DayBeforeYesterday = util:get_date(DayBeforeYesterdaySecs),
    Yesterday = util:get_date(YesterdaySecs),
    Tomorrow = util:get_date(TomorrowSecs),
    ?DEBUG("Today: ~p, DayBeforeYesterday: ~p, Yesterday: ~p, Tomorrow: ~p",
        [Today, DayBeforeYesterday, Yesterday, Tomorrow]),

    %% Fetch current gmt time.
    {{_,_,_}, {CurrentHrGMT, CurrentMinGMT,_}} = calendar:system_time_to_universal_time(TodaySecs, second),
    ?DEBUG("CurrentHrGMT: ~p, CurrentMinGMT: ~p", [CurrentMinGMT, CurrentMinGMT]),

    %% Fetch time to send for different days, corresponding notif ids and types.
    {_MinToSendPrevPrevDay, DayBeforeYesterdayNotifId, DayBeforeYesterdayNotifType, DayBeforeYesterdayPrompt} =
        model_feed:get_moment_time_to_send(DayBeforeYesterdaySecs),
    {MinToSendToday, TodayNotificationId, TodayNotificationType, TodayPrompt} =
        model_feed:get_moment_time_to_send(TodaySecs),
    {MinToSendPrevDay, YesterdayNotificationId, YesterdayNotificationType, YesterdayPrompt} =
        model_feed:get_moment_time_to_send(YesterdaySecs),
    {MinToSendNextDay, TomorrowNotificationId, TomorrowNotificationType, TomorrowPrompt} =
        model_feed:get_moment_time_to_send(TomorrowSecs),

    %% Get local time in minutes
    {ok, PushInfo} = model_accounts:get_push_info(Uid),
    LocalMin = get_local_time_in_minutes(Uid, Phone, PushInfo, CurrentHrGMT, CurrentMinGMT),

    %% Check if it is okay to send now.
    {TimeOk, MinToWait, DayAdjustment} = is_time_ok(LocalMin, MinToSendToday, MinToSendPrevDay, MinToSendNextDay),
    ?DEBUG("LocalMin: ~p, TimeOk: ~p, MinToWait: ~p, DayAdjustment: ~p",
        [LocalMin, TimeOk, MinToWait, DayAdjustment]),

    %% If we are supposed to send immediately.
    %% This means - current local time's notification was already sent.
    %% So we just send that days notification.
    %% If not - we first send previous days notification and then schedule the next one.
    {LocalDay, NotificationId, NotificationType, Prompt} = case TimeOk =:= true andalso MinToWait =:= 0 of
        true ->
            %% Send todays notification
            case DayAdjustment of
                0 -> {Today, TodayNotificationId, TodayNotificationType, TodayPrompt};
                -1 -> {Yesterday, YesterdayNotificationId, YesterdayNotificationType, YesterdayPrompt};
                1 -> {Tomorrow, TomorrowNotificationId, TomorrowNotificationType, TomorrowPrompt}
            end;
        false ->
            %% Send yesterdays notification first
            Result = case DayAdjustment of
                0 -> {Yesterday, YesterdayNotificationId, YesterdayNotificationType, YesterdayPrompt};
                -1 -> {DayBeforeYesterday, DayBeforeYesterdayNotifId, DayBeforeYesterdayNotifType, DayBeforeYesterdayPrompt};
                1 -> {Today, TodayNotificationId, TodayNotificationType, TodayPrompt}
            end,
            %% Schedule todays again separately.
            spawn(?MODULE, process_moment_tag, [[Uid], util:now(), false]),
            Result
    end,
    ?INFO("Scheduling: ~p, Local day: ~p, MinToWait: ~p, NotificationId: ~p", [Uid, LocalDay, 0, NotificationId]),
    {NotificationTimestamp, _, _} = model_feed:get_moment_info(NotificationId),
    wait_and_send_notification(Uid, util:to_binary(LocalDay), NotificationId, NotificationTimestamp, NotificationType, Prompt, 0),
    ok.

%%====================================================================

% At the current GMT time, we need to process everybody between GMT-24 to GMT+24.
% These time zones represent -1 day for some, current day for some, +1 day for some.
% For all these three days we can fetch applicable time the notification is supposed to go.
%
% If the local time's hr is greater than the hr of notification, we schedule the notification
% to be sent after some time. We need to make sure no double notifications are sent.
process_moment_tag(UidsList, TodaySecs, IsImmediateNotification) ->
    YesterdaySecs = (TodaySecs - ?DAYS),
    TomorrowSecs = (TodaySecs + ?DAYS),
    {{_,_,Today}, {CurrentHrGMT, CurrentMinGMT,_}} = 
        calendar:system_time_to_universal_time(TodaySecs, second),
    {{_,_,Yesterday}, {_,_,_}} =
        calendar:system_time_to_universal_time(YesterdaySecs, second),
    {{_,_,Tomorrow}, {_,_,_}} =
        calendar:system_time_to_universal_time(TomorrowSecs, second),
    ?INFO("Processing Today: ~p, GMT: ~p:~p", [Today, CurrentHrGMT, CurrentMinGMT]),

    %% Following are number of minutes in local time when moment notification needs to be sent
    %% today, yesterday and tomorrow.
    {MinToSendToday, TodayNotificationId, TodayNotificationType, TodayPrompt} =
        model_feed:get_moment_time_to_send(Today, TodaySecs),
    {MinToSendPrevDay, YesterdayNotificationId, YesterdayNotificationType, YesterdayPrompt} =
        model_feed:get_moment_time_to_send(Yesterday, YesterdaySecs),
    {MinToSendNextDay, TomorrowNotificationId, TomorrowNotificationType, TomorrowPrompt} =
        model_feed:get_moment_time_to_send(Tomorrow, TomorrowSecs),
    ?INFO("Times to send - Today: ~p, Yesterday: ~p, Tomorrow: ~p", 
        [MinToSendToday, MinToSendPrevDay, MinToSendNextDay]),

    TodayHr = MinToSendToday div ?MOMENT_TAG_INTERVAL_MIN,
    YesterdayHr = MinToSendPrevDay div ?MOMENT_TAG_INTERVAL_MIN,
    TomorrowHr = MinToSendNextDay div ?MOMENT_TAG_INTERVAL_MIN,

    %% Need to fetch list of users that are tagged to receive for Yesterday, Today and Tomorrow
    %% based on current GMT time.
    %% - CurrentHrGMT, TodayHr, YesterdayHr, TomorrowHr
    %%
    %% Today's tag - where in the world is the local time TodayHr
    %% - (TodayHr - CurrentHrGMT), e.g. PDT is GMT-8. If TodayHr is 15hr and CurrentHrGMT is 22Hr
    %%   (15 - 22) = -7 (cann't process PDT, but can process a zone that is 1 hr ahead of PDT)
    %%   (15 - 23) = -8 (can process PDT when currentHrGMT is 23Hr).
    %%   Today's tag at CurrentHrGMT is -7.
    %%
    %% Yesterday's tag
    %% - (YesterdayHr - CurrentHrGMT - 24), e.g. Hawaii is GMT-10. If YesterdayHr is 14Hr, and
    %%   CurrentHrGMT is 1Hr
    %%   (14 - 1 - 24) = -11 (processing Hawaii would be late by 1 Hr), but can process zone that
    %%                                                              is 1hr behind Hawaii
    %%   (14 - 0 - 24) = -10 (can process when CurrentHrGMT is 0Hr).
    %%   Yesterday's tag at CurrentHrGMT is -11
    %%
    %% Tomorrow's tag
    %% - (TomorrowHr - CurrentHrGMT + 24), e.g. Japan is GMT+9. If TomorrowHr is 8Hr, and 
    %%   CurrentHrGMT is 22Hr
    %%   (8 - 22 + 24) = 10 (cann't process Japan for 1 more hr).
    %%   (8 - 23 + 24) = 9 (can process Japan when CurrentHrGMT is 23hr).
    %%   Tomorrow's tag at CurrentHrGMT is 10
    %%
    %% Least tag is -12, Largest tag is +14. If any of the above tags is not within this limit,
    %% it can safely be ignored.
    %%
    
    TodayOffsetHr = TodayHr - CurrentHrGMT,
    YesterdayOffsetHr = YesterdayHr - CurrentHrGMT - 24,
    TomorrowOffsetHr = TomorrowHr - CurrentHrGMT + 24,
    ?INFO("Today's offset: ~p, Yesterday's offset: ~p, Tomorrow's offset: ~p",
        [TodayOffsetHr, YesterdayOffsetHr, TomorrowOffsetHr]),
    List = case UidsList of
        [] ->
            TodaysList = get_zone_tag_uids(TodayOffsetHr),
            YesterdayList = get_zone_tag_uids(YesterdayOffsetHr),
            TomorrowList = get_zone_tag_uids(TomorrowOffsetHr),
            lists:flatten([TodaysList, YesterdayList, TomorrowList]);
        _ -> UidsList
    end,
    Phones = model_accounts:get_phones(List),
    UidPhones = lists:zip(List, Phones),
    Processed =
        lists:foldl(
            fun({Uid, Phone}, Acc) when Phone =/= undefined ->
                {ok, PushInfo} = model_accounts:get_push_info(Uid),
                ClientVersion = PushInfo#push_info.client_version,
                LocalMin = get_local_time_in_minutes(Uid, Phone, PushInfo, CurrentHrGMT, CurrentMinGMT),

                {TimeOk, MinToWait, DayAdjustment} = 
                    is_time_ok(LocalMin, MinToSendToday, MinToSendPrevDay, MinToSendNextDay),
                MinToWait2 = case IsImmediateNotification of
                    false -> MinToWait;
                    true -> 0
                end,
                ProcessingDone = case TimeOk andalso is_client_version_ok(ClientVersion) of
                    true ->
                          {LocalDay, NotificationId, NotificationType, Prompt} = case DayAdjustment of
                              0 -> {Today, TodayNotificationId, TodayNotificationType, TodayPrompt};
                              -1 -> {Yesterday, YesterdayNotificationId, YesterdayNotificationType, YesterdayPrompt};
                              1 -> {Tomorrow, TomorrowNotificationId, TomorrowNotificationType, TomorrowPrompt}
                          end,
                          ?INFO("Scheduling: ~p, Local day: ~p, MinToWait: ~p", [Uid, LocalDay, MinToWait2]),
                          wait_and_send_notification(Uid, util:to_binary(LocalDay), NotificationId, NotificationType, Prompt, MinToWait2),
                          true;
                    false ->
                          ?INFO("Skipping: ~p", [Uid]),
                          false
                end,
                Acc andalso ProcessingDone;
            ({Uid, _}, Acc) ->
                ?INFO("Skipping: ~p, invalid Phone", [Uid]),
                Acc
        end, true, UidPhones),
    ?INFO("Processed fully: ~p", [Processed]).

%% TODO(vipin): Update this method. false clause is to satisfy Dialyzer
is_client_version_ok(UserAgent) when is_binary(UserAgent) ->
    true;
is_client_version_ok(_UserAgent) ->
    false.

fix_zone_tag_uids(ZoneTag) ->
    UidsList = get_zone_tag_uids(ZoneTag),
    TagOk = lists:foldl(fun(Uid, Acc) ->
        {ok, PushInfo} = model_accounts:get_push_info(Uid),
        ZoneOffset = PushInfo#push_info.zone_offset,
        case ZoneOffset of
            undefined -> Acc;
            _ ->
                Hr = get_four_zone_offset_hr(ZoneOffset),
                CorrectList = get_zone_tag_uids(Hr),
                Present = lists:member(Uid, CorrectList),
                ?INFO("Uid: ~p, new zone tag: ~p, old tag: ~p, present: ~p",  
                    [Uid, Hr, ZoneTag, Present]),
                Acc andalso Present
        end
    end, true, UidsList),
    ?INFO("Tag OK: ~p", [TagOk]). 

get_zone_tag_uids(ZoneOffsetDiff) ->
    %% If the tag is < -12 or greater than +14, it can safely be ignored.
    {ok, UidsList} = case ZoneOffsetDiff >= -12 andalso ZoneOffsetDiff =< 14 of
        true -> model_accounts:get_zone_offset_tag_uids(ZoneOffsetDiff * ?MOMENT_TAG_INTERVAL_SEC);
        false ->
            ?INFO("Invalid zone offset diff: ~p, Ignoring", [ZoneOffsetDiff]),
            {ok, []}
    end,
    UidsList.


get_four_zone_offset_hr(_Uid, Phone, PushInfo) ->
    case PushInfo#push_info.token =:= undefined of
        false -> get_region_offset_hr(get_offset_region(PushInfo#push_info.zone_offset));
        true ->
            case mod_libphonenumber:get_cc(Phone) of
                <<"US">> -> get_region_offset_hr(america);
                _ ->
                    %% Ignoring everything other than the US for now and we default to the US.
                    get_region_offset_hr(america)
            end
    end.


get_four_zone_offset_hr(ZoneOffsetSec) ->
    get_region_offset_hr(get_offset_region(ZoneOffsetSec)).


%% California time for America
%% UK time for Europe
%% Saudi Arabia time for West Asia
%% China time for East Asia
-spec get_region_offset_hr(Region :: atom()) -> integer().
get_region_offset_hr(Region) ->
    case Region of
        europe -> 0;  %% UK
        west_asia -> 3;  %% Saudi Arabia
        east_asia -> 8;  %% China
        america ->
            {{_, Month, _}, {_, _, _}} = calendar:local_time(),
            case Month >= 4 andalso Month =< 10 of %% April to Oct
                true -> -7;   %% PDT
                false -> -8   %% PST
            end;
        _ ->
            ?ERROR("Invalid Region: ~p", [Region]),
            get_region_offset_hr(america)
    end.


get_local_time_in_minutes(Uid, Phone, PushInfo, CurrentHrGMT, CurrentMinGMT) ->
    ?DEBUG("GMTHr: ~p", [CurrentHrGMT]),
    %% Why bother checking client version here?
    ClientVersion = PushInfo#push_info.client_version,
    ZoneOffset = case is_client_version_ok(ClientVersion) of
        true -> get_four_zone_offset_hr(Uid, Phone, PushInfo) * ?HOURS;
        false -> undefined
    end,
    get_local_time_in_minutes(Phone, ZoneOffset, CurrentHrGMT, CurrentMinGMT).


get_local_time_in_minutes(Phone, ZoneOffset, CurrentHrGMT, CurrentMinGMT) ->
    LocalMin = case ZoneOffset of
        undefined ->
            CC = mod_libphonenumber:get_cc(Phone),
            case CC of
                <<"AE">> -> (CurrentHrGMT + 4) * 60;
                <<"BA">> -> (CurrentHrGMT + 2) * 60;
                <<"GB">> -> (CurrentHrGMT + 1) * 60;
                <<"ID">> -> (CurrentHrGMT + 7) * 60;
                <<"IR">> -> (CurrentHrGMT + 3) * 60 + 30;  %% + 3:30
                <<"US">> -> (CurrentHrGMT - 6) * 60;
                <<"IN">> -> (CurrentHrGMT + 5) * 60;
                _ -> CurrentHrGMT * 60 + CurrentMinGMT
            end;
        _ ->
            ZoneOffsetMin = ZoneOffset div 60,
            (CurrentHrGMT * 60) + CurrentMinGMT + ZoneOffsetMin
    end,
    ?DEBUG("LocalMin: ~p", [LocalMin]),
    LocalMin.


%% If localtime if within GMT day, use MinToSendToday. If locatime is in the prev day with
%% respect to GMT day, use MinToSendPrevDay. If localtime is in the next day with respect to
%% GMT day, use MinToSendNextDay.
is_time_ok(LocalMin, MinToSendToday, MinToSendPrevDay, MinToSendNextDay) ->
    ?DEBUG("LocalMin: ~p", [LocalMin]),
    {DayAdjustment, MinToSend, LocalCurrentHr, LocalCurrentMin} = case LocalMin >= 24 * 60 of
        true ->
            AdjustedMin = LocalMin - 24 * 60,
            {1, MinToSendNextDay, AdjustedMin div 60, AdjustedMin rem 60};
        false ->
            case LocalMin < 0 of
                true ->
                    AdjustedMin = LocalMin + 24 * 60,
                    {-1, MinToSendPrevDay, AdjustedMin div 60, AdjustedMin rem 60};
                false -> {0, MinToSendToday, LocalMin div 60, LocalMin rem 60}
            end
    end,
    WhichHrToSend = MinToSend div 60,
    WhichMinToSend = MinToSend rem 60,
    ?INFO("LocalMin: ~p, WhichTimeToSend: ~p:~p, LocalTime: ~p:~p",
        [LocalMin, WhichHrToSend, WhichMinToSend, LocalCurrentHr, LocalCurrentMin]),
    IsTimeOk = (LocalCurrentHr >= WhichHrToSend),
    MinToWait = case LocalCurrentHr == WhichHrToSend of
        true ->
            case (WhichMinToSend - LocalCurrentMin) > 0 of
                true -> (WhichMinToSend - LocalCurrentMin);
                false -> 0
            end;
        false -> 0
    end,
    {IsTimeOk, MinToWait, DayAdjustment}.


-spec wait_and_send_notification(Uid :: uid(), Tag :: binary(), NotificationId :: integer(), NotificationType :: moment_type(), Prompt :: binary(), MinToWait :: integer()) -> ok.
wait_and_send_notification(Uid, Tag, NotificationId, NotificationType, Prompt, MinToWait) ->
    case dev_users:is_dev_uid(Uid) orelse util_uid:get_app_type(Uid) =:= katchup of
        true ->
            timer:apply_after(MinToWait * ?MINUTES_MS, ?MODULE,
                maybe_send_moment_notification, [Uid, Tag, NotificationId, NotificationType, Prompt]);
        false ->
            ?INFO("Not a developer: ~p", [Uid])
    end,
    ok.


-spec wait_and_send_notification(Uid :: uid(), Tag :: binary(), NotificationId :: integer(),
        NotificationTimestamp :: integer(), NotificationType :: moment_type(), Prompt :: binary(), MinToWait :: integer()) -> ok.
wait_and_send_notification(Uid, Tag, NotificationId, NotificationTimestamp, NotificationType, Prompt, MinToWait) ->
    case dev_users:is_dev_uid(Uid) orelse util_uid:get_app_type(Uid) =:= katchup of
        true ->
            timer:apply_after(MinToWait * ?MINUTES_MS, ?MODULE,
                maybe_send_moment_notification, [Uid, Tag, NotificationId, NotificationTimestamp, NotificationType, Prompt]);
        false ->
            ?INFO("Not a developer: ~p", [Uid])
    end,
    ok.


-spec maybe_send_moment_notification(Uid :: uid(), Tag :: binary(), NotificationId :: integer(),
        NotificationTimestamp :: integer(), NotificationType :: moment_type(), Prompt :: binary()) -> ok.
maybe_send_moment_notification(Uid, Tag, NotificationId, NotificationTimestamp, NotificationType, Prompt) ->
    case model_accounts:mark_moment_notification_sent(Uid, Tag) of
        true -> send_moment_notification(Uid, NotificationId, NotificationTimestamp, NotificationType, Prompt);
        false -> ?INFO("Moment notification already sent to Uid: ~p", [Uid])
    end.


-spec maybe_send_moment_notification(Uid :: uid(), Tag :: binary(), NotificationId :: integer(), NotificationType :: moment_type(), Prompt :: binary()) -> ok.
maybe_send_moment_notification(Uid, Tag, NotificationId, NotificationType, Prompt) ->
    case model_accounts:mark_moment_notification_sent(Uid, Tag) of
        true -> send_moment_notification(Uid, NotificationId, NotificationType, Prompt);
        false -> ?INFO("Moment notification already sent to Uid: ~p", [Uid])
    end.


send_moment_notification(Uid) ->
    send_moment_notification(Uid, 0, util_moments:to_moment_type(util:to_binary(rand:uniform(2))), <<"WYD?">>).

send_moment_notification(Uid, NotificationId, NotificationType, Prompt) ->
    send_moment_notification(Uid, NotificationId, util:now(), NotificationType, Prompt).

send_moment_notification(Uid, NotificationId, NotificationTimestamp, NotificationType, Prompt) ->
    NotificationTime = util:now(),
    AppType = util_uid:get_app_type(Uid),
    Packet = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = Uid,
        type = headline,
        payload = #pb_moment_notification{
            timestamp = NotificationTimestamp,
            notification_id = NotificationId,
            type = NotificationType,
            prompt = Prompt
        }
    },
    ejabberd_router:route(Packet),
    ejabberd_hooks:run(send_moment_notification, AppType, [Uid, NotificationId, NotificationTime, NotificationType, Prompt]),
    ok.


get_offset_region(ZoneOffsetSec) when is_integer(ZoneOffsetSec) ->
    ZoneOffsetHr = ZoneOffsetSec / ?HOURS,
    if
        ZoneOffsetHr >= -10 andalso ZoneOffsetHr =< -3 -> america;
        ZoneOffsetHr > -3 andalso ZoneOffsetHr < 3 -> europe;
        ZoneOffsetHr >= 3 andalso ZoneOffsetHr < 8 -> west_asia;
        ZoneOffsetHr >= 8 orelse ZoneOffsetHr < -10 -> east_asia;
        true ->
            ?ERROR("Invalid zone_offset: ~p", [ZoneOffsetSec]),
            undefined
    end;
get_offset_region(_ZoneOffsetSec) ->
    undefined.


-spec get_offset_region_by_uid(Uid :: uid()) -> maybe(america | europe | west_asia | east_asia).
get_offset_region_by_uid(Uid) ->
    ZoneOffsetSec = model_accounts:get_zone_offset(Uid),
    case get_offset_region(ZoneOffsetSec) of
        undefined ->
            ?ERROR("ZoneOffsetSec does not fit into region for ~s: ~p", [Uid, ZoneOffsetSec]),
            undefined;
        Res -> Res
    end.

