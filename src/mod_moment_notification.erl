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

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1, depends/2]).

-export([
    schedule/0,
    unschedule/0,
    send_notifications/0,
    send_moment_notification/1,
    maybe_send_moment_notification/2,
    is_time_ok/7  %% for testing
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
            process_moment_tag(util:now(), false),
            process_moment_tag(util:now() - ?MOMENT_TAG_INTERVAL_SEC, true),
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
    process_moment_tag(util:now(), false),
    ok.

%%====================================================================

%% Following function exists to convert old format notification time (hr) to new format (min).
backward_compatible(Min) ->
    case Min < 15 * 60 of
        true -> Min * 60;
        false -> Min
    end.

% At the current GMT time, we need to process everybody between GMT-24 to GMT+24.
% These time zones represent -1 day for some, current day for some, +1 day for some.
% For all these three days we can fetch applicable time the notification is supposed to go.
%
% If the local time's hr is greater than the hr of notification, we schedule the notification
% to be sent after some time. We need to make sure no double notifications are sent.
process_moment_tag(CurrentTimeSecs, IsImmediateNotification) ->
    {{_,_,Today}, {CurrentHrGMT, CurrentMinGMT,_}} = 
        calendar:system_time_to_universal_time(CurrentTimeSecs, second),
    {{_,_,Yesterday}, {_,_,_}} =
        calendar:system_time_to_universal_time(CurrentTimeSecs - ?DAYS, second),
    {{_,_,Tomorrow}, {_,_,_}} =
        calendar:system_time_to_universal_time(CurrentTimeSecs + ?DAYS, second),
    ?INFO("Processing Today: ~p, GMT: ~p:~p", [Today, CurrentHrGMT, CurrentMinGMT]),

    %% Following are number of minutes in local time when moment notification needs to be sent
    %% today, yesterday and tomorrow.
    MinToSendToday = backward_compatible(model_feed:get_moment_time_to_send(util:to_binary(Today))),
    MinToSendPrevDay = backward_compatible(model_feed:get_moment_time_to_send(util:to_binary(Yesterday))),
    MinToSendNextDay = backward_compatible(model_feed:get_moment_time_to_send(util:to_binary(Tomorrow))),
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
    TodaysList = get_zone_tag_uids(TodayOffsetHr),
    YesterdayList = get_zone_tag_uids(YesterdayOffsetHr),
    TomorrowList = get_zone_tag_uids(TomorrowOffsetHr),
    List = lists:flatten([TodaysList, YesterdayList, TomorrowList]),

    Phones = model_accounts:get_phones(List),
    UidPhones = lists:zip(List, Phones),
    Processed =
        lists:foldl(
            fun({Uid, Phone}, Acc) when Phone =/= undefined ->
                {ok, PushInfo} = model_accounts:get_push_info(Uid),
                ClientVersion = PushInfo#push_info.client_version,
                ZoneOffset = case is_client_version_ok(ClientVersion) of
                    true -> PushInfo#push_info.zone_offset;
                    false -> undefined
                end,
                {TimeOk, MinToWait, DayAdjustment} = 
                    is_time_ok(CurrentHrGMT, CurrentMinGMT, Phone, ZoneOffset,
                        MinToSendToday, MinToSendPrevDay, MinToSendNextDay),
                MinToWait2 = case IsImmediateNotification of
                    false -> MinToWait;
                    true -> 0
                end,
                ProcessingDone = case TimeOk andalso is_client_version_ok(ClientVersion) of
                    true ->
                          LocalDay = case DayAdjustment of
                              0 -> Today;
                              -1 -> Yesterday;
                              1 -> Tomorrow
                          end,
                          ?INFO("Scheduling: ~p, Local day: ~p, MinToWait: ~p", [Uid, LocalDay, MinToWait2]),
                          wait_and_send_notification(Uid, util:to_binary(LocalDay), MinToWait2),
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

get_zone_tag_uids(ZoneOffsetDiff) ->
    %% If the tag is < -12 or greater than +14, it can safely be ignored.
    {ok, UidsList} = case ZoneOffsetDiff >= -12 andalso ZoneOffsetDiff =< 14 of
        true -> model_accounts:get_zone_offset_tag_uids(ZoneOffsetDiff * ?MOMENT_TAG_INTERVAL_SEC);
        false ->
            ?INFO("Invalid zone offset diff: ~p, Ignoring", [ZoneOffsetDiff]),
            {ok, []}
    end,
    UidsList.
 
%% If localtime if within GMT day, use MinToSendToday. If locatime is in the prev day with
%% respect to GMT day, use MinToSendPrevDay. If localtime is in the next day with respect to
%% GMT day, use MinToSendNextDay.
is_time_ok(CurrentHrGMT, CurrentMinGMT, Phone, ZoneOffset,
        MinToSendToday, MinToSendPrevDay, MinToSendNextDay) ->
    ?DEBUG("GMTHr: ~p", [CurrentHrGMT]),
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
    ?INFO("Phone: ~p, WhichTimeToSend: ~p:~p, LocalTime: ~p:~p",
        [Phone, WhichHrToSend, WhichMinToSend, LocalCurrentHr, LocalCurrentMin]),
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


-spec wait_and_send_notification(Uid :: uid(), Tag :: binary(), MinToWait :: integer()) -> ok.
wait_and_send_notification(Uid, Tag, MinToWait) ->
    case dev_users:is_dev_uid(Uid) of
        true ->
            timer:apply_after(MinToWait * ?MINUTES_MS, ?MODULE,
                maybe_send_moment_notification, [Uid, Tag]);
        false ->
            ?INFO("Not a developer: ~p", [Uid])
    end,
    ok.

-spec maybe_send_moment_notification(Uid :: uid(), Tag :: binary()) -> ok.
maybe_send_moment_notification(Uid, Tag) ->
    case model_accounts:mark_moment_notification_sent(Uid, Tag) of
        true -> send_moment_notification(Uid);
        false -> ?INFO("Moment notification already sent to Uid: ~p", [Uid])
    end.


send_moment_notification(Uid) ->
    AppType = util_uid:get_app_type(Uid),
    Packet = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = Uid,
        type = headline,
        payload = #pb_moment_notification{
            timestamp = util:now()
        }
    },
    ejabberd_router:route(Packet),
    ejabberd_hooks:run(send_moment_notification, AppType, [Uid]),
    ok.
 