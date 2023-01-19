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

-spec get_geo_tag(Uid :: binary(), GpsLocation :: pb_gps_location()) -> atom().
get_geo_tag(_Uid, GpsLocation) when GpsLocation =:= undefined -> undefined;
get_geo_tag(Uid, GpsLocation = #pb_gps_location{latitude = Latitude, longitude = Longitude}) ->
    GpsCoordinates = {Latitude, Longitude},
    TaggedLocations = get_tagged_locations(),
    GeoTag = lists:foldl(
            fun({GeoTag, Coordinates}, Acc) ->
                case Acc =:= undefined of
                    false -> Acc;
                    true ->
                        case is_location_interior(GpsCoordinates, Coordinates) of
                            false -> Acc;
                            true -> GeoTag
                        end
                end
            end,
            undefined,
            TaggedLocations),
    ?INFO("Uid: ~p, GpsLocation: ~p, GeoTag assigned: ~p", [Uid, GpsLocation, GeoTag]),
    GeoTag.


%% Currently, our shapes must be convex polygons to satisfy the is_location_interior algo.
%% The list of points should be defined s.t. the points are ordered in clockwise direction
%% and any two points next to each other (incl. first and last point) form an edge of the polygon.
-spec get_tagged_locations() -> list().
get_tagged_locations() ->
    [{cal_ave,
        [{37.4256235, -122.1462536},
         {37.4251790, -122.1456645},
         {37.4290103, -122.1426232},
         {37.4295388, -122.1435419}]},
    {ucla,
        [{34.078689, -118.453409},
         {34.079122, -118.433941},
         {34.056059, -118.419916},
         {34.050827, -118.458642}]},
    {pepperd,
        [{34.049915, -118.724660},
         {34.050839, -118.700670},
         {34.033628, -118.700112},
         {34.032596, -118.719939}]},
    {ucdav,
        [{38.557285, -121.811774},
         {38.555099, -121.701078},
         {38.525800, -121.703687},
         {38.530611, -121.795374}]},
    {ucbkly,
        [{37.885401, -122.283466},
         {37.885667, -122.233477},
         {37.861299, -122.225091},
         {37.852175, -122.276108}]},
    {cal_poly,
        [{35.312516, -120.672516},
         {35.310952, -120.655267},
         {35.295558, -120.651501},
         {35.294871, -120.673424}]},
    {stanford,
        [{37.428688, -122.200433},
         {37.447210, -122.171303},
         {37.427907, -122.148653},
         {37.402363, -122.182350}]},
    {askokau,
        [{28.950994, 77.097699},
         {28.951757, 77.104743},
         {28.943766, 77.104514},
         {28.943083, 77.099534}]}].


%% Checks if the point is on the left side of each line.
%% https://stackoverflow.com/questions/2752725/finding-whether-a-point-lies-inside-a-rectangle-or-not/2752753#2752753
-spec is_location_interior(GpsLocation :: {float(), float()}, Coordinates :: [{float(), float()}]) -> boolean().
is_location_interior(GpsLocation, Coordinates) ->
    Point = GpsLocation,
    [Corner1, Corner2, Corner3, Corner4] = Coordinates,
    IsPointRight1 = is_point_right_of_edge(Corner1, Corner2, Point),
    IsPointRight2 = is_point_right_of_edge(Corner2, Corner3, Point),
    IsPointRight3 = is_point_right_of_edge(Corner3, Corner4, Point),
    IsPointRight4 = is_point_right_of_edge(Corner4, Corner1, Point),

    IsPointRight1 andalso IsPointRight2 andalso IsPointRight3 andalso IsPointRight4.


is_point_right_of_edge(Corner1, Corner2, Point) ->
    {X1, Y1} = Corner1,
    {X2, Y2} = Corner2,
    {Xp, Yp} = Point,
    D = (X2 - X1) * (Yp - Y1) - (Xp - X1) * (Y2 - Y1),
    D =< 0.

