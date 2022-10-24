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
    send_moment_notification/1
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
    send_notification(integer_to_binary(Day)),
    ok.

%%====================================================================

-spec send_notification(Tag :: binary()) -> ok.
send_notification(Tag) ->
    case model_feed:is_moment_tag_done(Tag) of
        true -> ok;
        false -> process_moment_tag(Tag)
    end.

process_moment_tag(Tag) ->
    HrToSend = model_feed:get_moment_time_to_send(Tag),
    List = dev_users:get_dev_uids(),
    Phones = model_accounts:get_phones(List),
    UidPhones = lists:zip(List, Phones),
    Processed =
        lists:foldl(fun({Uid, Phone}, Acc) ->
            {ok, PushInfo} = model_accounts:get_push_info(Uid),
            ClientVersion = PushInfo#push_info.client_version,
            ZoneOffset = PushInfo#push_info.zone_offset,
            ProcessingDone = case is_time_ok(Phone, ZoneOffset, HrToSend) andalso
                    is_client_version_ok(ClientVersion) of
                true ->
                      maybe_send_moment_notification(Uid, Tag),
                      true;
                false -> false
            end,
            Acc andalso ProcessingDone
        end, true, UidPhones),
    case Processed of
        true -> model_feed:mark_moment_tag_done(Tag);
        false -> ok
    end.

is_client_version_ok(_UserAgent) ->
    true.

is_time_ok(Phone, ZoneOffset, HrToSend) ->
    {{_,_,_}, {UtcHr,_,_}} = calendar:system_time_to_universal_time(util:now(), second),
    UtcHr2 = UtcHr + 24,
    CCLocalHr1 = case ZoneOffset of
        undefined ->
            CC = mod_libphonenumber:get_cc(Phone),
            case CC of
                <<"AE">> -> UtcHr2 + 4;
                <<"BA">> -> UtcHr2 + 2;
                <<"GB">> -> UtcHr2 + 1;
                <<"ID">> -> UtcHr2 + 7;
                <<"IR">> -> UtcHr2 + 3;  %% + 3:30
                <<"US">> -> UtcHr2 - 6;
                <<"IN">> -> UtcHr2 + 5;
                _ -> UtcHr2
            end;
        _ ->
            ZoneOffsetHr = round(ZoneOffset / 3600),
            UtcHr2 + ZoneOffsetHr
    end,
    CCLocalHr = CCLocalHr1 rem 24,
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
 
