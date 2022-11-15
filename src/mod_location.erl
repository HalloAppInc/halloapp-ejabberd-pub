%%%-----------------------------------------------------------------------------------
%%% File    : mod_location.erl
%%%
%%% Copyright (C) 2022 halloappinc.
%%%
%%%-----------------------------------------------------------------------------------

-module(mod_location).
-behaviour(gen_mod).
-author('murali').

-include("logger.hrl").
-include("location.hrl").
-include("packets.hrl").


%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% Hooks and API.
-export([
    get_geo_tag/2
]).


start(_Host, _Opts) ->
    ?INFO("start", []),
    ok.

stop(_Host) ->
    ?INFO("stop", []),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% feed: IQs
%%====================================================================

-spec get_geo_tag(Uid :: binary(), GpsLocation :: {float(), float()}) -> atom().
get_geo_tag(Uid, GpsLocation) ->
    TaggedLocations = get_tagged_locations(),
    GeoTag = lists:foldl(
            fun({GeoTag, Coordinates}, Acc) ->
                case Acc =:= undefined of
                    false -> Acc;
                    true ->
                        case is_location_interior(GpsLocation, Coordinates) of
                            false -> Acc;
                            true -> GeoTag
                        end
                end
            end,
            undefined,
            TaggedLocations),
    ?INFO("Uid: ~p, GpsLocation: ~p, GeoTag assigned: ~p", [Uid, GpsLocation, GeoTag]),
    GeoTag.


%% Points of the quadrilateral must be in the counter clockwise direction.
-spec get_tagged_locations() -> list().
get_tagged_locations() ->
    [{cal_ave,
        [{37.4256235, -122.1462536},
         {37.4251790, -122.1456645},
         {37.4290103, -122.1426232},
         {37.4295388, -122.1435419}]}].


%% Checks if the point is on the left side of each line.
%% https://stackoverflow.com/questions/2752725/finding-whether-a-point-lies-inside-a-rectangle-or-not/2752753#2752753
-spec is_location_interior(GpsLocation :: {float(), float()}, Coordinates :: [{float(), float()}]) -> boolean().
is_location_interior(GpsLocation, Coordinates) ->
    Point = GpsLocation,
    [Corner1, Corner2, Corner3, Corner4] = Coordinates,
    IsLeftSide1 = check_point_direction(Corner1, Corner2, Point),
    IsLeftSide2 = check_point_direction(Corner2, Corner3, Point),
    IsLeftSide3 = check_point_direction(Corner3, Corner4, Point),
    IsLeftSide4 = check_point_direction(Corner4, Corner1, Point),

    IsLeftSide1 andalso IsLeftSide2 andalso IsLeftSide3 andalso IsLeftSide4.


check_point_direction(Corner1, Corner2, Point) ->
    {X1, Y1} = Corner1,
    {X2, Y2} = Corner2,
    {Xp, Yp} = Point,
    A = -(Y2 - Y1),
    B = X2 - X1,
    C = -(A * X1 + B * Y1),
    D = A * Xp + B * Yp + C,
    %% return if point is on the left side.
    D >= 0.




