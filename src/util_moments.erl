%%%-------------------------------------------------------------------
%%% File: util_moments.erl
%%% copyright (C) 2022, HalloApp, Inc.
%%%
%%%-------------------------------------------------------------------
-module(util_moments).
-author('vipin').

-include("moments.hrl").
-include("logger.hrl").
-include("time.hrl").

-export([
    to_moment_type/1,
    moment_type_to_bin/1,
    calculate_notif_timestamp/3
]).

-spec to_moment_type(Bin :: binary()) -> moment_type().
to_moment_type(Bin) ->
    case util:to_integer_maybe(Bin) of
        undefined ->
            ?ERROR("Got invalid type: ~p", [Bin]),
            live_camera;
        1 -> live_camera;
        2 -> text_post;
        3 -> album_post;
        _ ->
            ?ERROR("Got invalid type: ~p", [Bin]),
            live_camera
    end.

-spec moment_type_to_bin(MomentType :: moment_type()) -> binary().
moment_type_to_bin(MomentType) ->
    case MomentType of
        live_camera -> <<"1">>;
        text_post -> <<"2">>;
        album_post -> <<"3">>
    end.


-spec calculate_notif_timestamp(DayAdjustment :: integer(), MinToSend :: integer(), ZoneOffsetHr :: integer()) -> integer().
calculate_notif_timestamp(DayAdjustment, MinToSend, ZoneOffsetHr) ->
    %% MinToSend is local time in minutes to send on that day.
    %% We subtract ZoneOffsetHr to get the GMT time at that time - since that is the notification timestamp.
    %% we obtain the appropriate day adjustment from it if necessary.
    %% So if Hrs > 24, then subtract 24.
    %% If Hrs < 0, then add 24.
    %% Otherwise - just use the result.
    {TimezoneDayAdjustment, TimeHr} = case (MinToSend div 60)-ZoneOffsetHr of
        Hrs when Hrs > 0 andalso Hrs < 24 -> {0, Hrs};
        Hrs when Hrs >= 24 -> {1, Hrs - 24};
        Hrs -> {-1, Hrs + 24}
    end,
    TotalDayAdjustment = DayAdjustment + TimezoneDayAdjustment,
    %% Get date.
    {Date, {_,_,_}} = calendar:system_time_to_universal_time(util:now() + TotalDayAdjustment * ?DAYS, second),
    TimeMin = MinToSend rem 60,
    %% Calculate timestamp now.
    NotificationDateTime = {Date, {TimeHr, TimeMin, 0}},
    %% 62167219200 == calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
    Timestamp = calendar:datetime_to_gregorian_seconds(NotificationDateTime) - 62167219200,
    Timestamp.
