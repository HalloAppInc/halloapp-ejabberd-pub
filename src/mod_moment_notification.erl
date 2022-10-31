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
    send_notification/1,
    send_notifications/0,
    send_moment_notification/1,
    is_time_ok/5  %% for testing
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
        true -> schedule();
        false -> ok
    end,
    ok.



%%====================================================================
%% api
%%====================================================================

-spec schedule() -> ok.
schedule() ->
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
    {{_,_,Day}, {_,_,_}} = calendar:system_time_to_universal_time(util:now(), second),
    send_notification(Day),
    ok.

%%====================================================================

-spec send_notification(Today :: integer()) -> ok.
send_notification(Today) ->
    %% Have we processed all the accounts regardless of their timezone Today (GMT).
    case model_feed:is_moment_tag_done(util:to_binary(Today)) of
        true -> ok;
        false -> process_moment_tag(Today)
    end.

process_moment_tag(Today) ->
    HrToSendToday = model_feed:get_moment_time_to_send(util:to_binary(Today)),
    HrToSendPrevDay = model_feed:get_moment_time_to_send(util:to_binary(Today - 1)), %% Local time is 1 day behind
    HrToSendNextDay = model_feed:get_moment_time_to_send(util:to_binary(Today + 1)), %% Local time is 1 day ahead
    List = dev_users:get_dev_uids(),
    Phones = model_accounts:get_phones(List),
    UidPhones = lists:zip(List, Phones),
    Processed =
        lists:foldl(fun({Uid, Phone}, Acc) ->
            {ok, PushInfo} = model_accounts:get_push_info(Uid),
            ClientVersion = PushInfo#push_info.client_version,
            ZoneOffset = case is_client_version_ok(ClientVersion) of
                true -> PushInfo#push_info.zone_offset;
                false -> undefined
            end,
            ProcessingDone = case Phone =/= undefined andalso
                    is_time_ok(Phone, ZoneOffset, HrToSendToday, HrToSendPrevDay, HrToSendNextDay) andalso
                    is_client_version_ok(ClientVersion) of
                true ->
                      maybe_send_moment_notification(Uid, util:to_binary(Today)),
                      true;
                false -> false
            end,
            Acc andalso ProcessingDone
        end, true, UidPhones),
    case Processed of
        true -> model_feed:mark_moment_tag_done(util:to_binary(Today));
        false -> ok
    end.

%% TODO(vipin): Update this method. false clause is to satisfy Dialyzer
is_client_version_ok(UserAgent) when is_binary(UserAgent) ->
    true;
is_client_version_ok(_UserAgent) ->
    false.

%% If localtime if within GMT day, use HrToSendToday. If locatime is in the prev day with
%% respect to GMT day, use HrToSendPrevDay. If localtime is in the next day with respect to
%% GMT day, use HrToSendNextDay.
is_time_ok(Phone, ZoneOffset, HrToSendToday, HrToSendPrevDay, HrToSendNextDay) ->
    {{_,_,_}, {UtcHr,_,_}} = calendar:system_time_to_universal_time(util:now(), second),
    ?DEBUG("UtcHr: ~p", [UtcHr]),
    CCLocalHr1 = case ZoneOffset of
        undefined ->
            CC = mod_libphonenumber:get_cc(Phone),
            case CC of
                <<"AE">> -> UtcHr + 4;
                <<"BA">> -> UtcHr + 2;
                <<"GB">> -> UtcHr + 1;
                <<"ID">> -> UtcHr + 7;
                <<"IR">> -> UtcHr + 3;  %% + 3:30
                <<"US">> -> UtcHr - 6;
                <<"IN">> -> UtcHr + 5;
                _ -> UtcHr
            end;
        _ ->
            ZoneOffsetHr = round(ZoneOffset / 3600),
            UtcHr + ZoneOffsetHr
    end,
    ?DEBUG("LocalHr: ~p", [CCLocalHr1]),
    {HrToSend, CCLocalHr} = case CCLocalHr1 >= 24 of
        true ->
            {HrToSendNextDay, CCLocalHr1 - 24};
        false ->
            case CCLocalHr1 < 0 of
                true -> {HrToSendPrevDay, CCLocalHr1 + 24};
                false -> {HrToSendToday, CCLocalHr1}
            end
    end,
    ?DEBUG("HrToSend: ~p, CCLocalHr: ~p", [HrToSend, CCLocalHr]),
    (CCLocalHr >= 15) andalso ((CCLocalHr >= HrToSend) orelse (HrToSend > 21)).

-spec maybe_send_moment_notification(Uid :: uid(), Tag :: binary()) -> ok.
maybe_send_moment_notification(Uid, Tag) ->
    case model_accounts:mark_moment_notification_sent(Uid, Tag) of
        true ->
            send_moment_notification(Uid);
       false ->
            ?DEBUG("Moment notification already sent to Uid: ~p", [Uid])
    end.


send_moment_notification(Uid) ->
    Packet = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = Uid,
        type = headline,
        payload = #pb_moment_notification{
            timestamp = util:now()
        }
    },
    ejabberd_router:route(Packet).
 
