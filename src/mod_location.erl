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


-spec get_tagged_locations() -> list().
get_tagged_locations() ->
    [{cal_ave,
        [{37.4295388, -122.1435419},
         {37.4290103, -122.1426232},
         {37.4251790, -122.1456645},
         {37.4256235, -122.1462536}]}].


%% We calculate the sum of the area of the triangles formed with the point and the corners of the rectangle.
%% We calculate the area of the rectangle itself and compare it with the above value.
%% If the values match - then the point is inside - else the point is outside.
-spec is_location_interior(GpsLocation :: {float(), float()}, Coordinates :: [{float(), float()}]) -> boolean().
is_location_interior(GpsLocation, Coordinates) ->
    Point = GpsLocation,
    [Corner1, Corner2, Corner3, Corner4] = Coordinates,
    PointArea1 = triangle_area(Corner1, Corner2, Point),
    PointArea2 = triangle_area(Corner2, Corner3, Point),
    PointArea3 = triangle_area(Corner3, Corner4, Point),
    PointArea4 = triangle_area(Corner4, Corner1, Point),

    Area1 = triangle_area(Corner1, Corner2, Corner3),
    Area2 = triangle_area(Corner3, Corner4, Corner1),

    %% Use large error threshold for now.
    case (PointArea1 + PointArea2 + PointArea3 + PointArea4) > (Area1 + Area2) + 0.01  of
        true -> false;
        false -> true
    end.


triangle_area(Corner1, Corner2, Corner3) ->
    A = distance(Corner1, Corner2),
    B = distance(Corner2, Corner3),
    C = distance(Corner3, Corner1),
    S = (A + B + C) / 2,
    Area = math:sqrt(S * (S - A) * (S - B) * (S - C)),
    Area.



distance(Corner1, Corner2) ->
    {X1, Y1} = Corner1,
    {X2, Y2} = Corner2,
    Xdiff = X2 - X1,
    Ydiff = Y2 - Y1,
    Distance = math:sqrt(Xdiff*Xdiff + Ydiff*Ydiff),
    Distance.




