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
    get_geo_tag/2,
    get_geo_tag/3,
    map_geo_tags/2
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

get_geo_tag(Uid, GpsLocation) ->
    get_geo_tag(Uid, GpsLocation, true).

-spec get_geo_tag(Uid :: binary(), GpsLocation :: pb_gps_location(), FilterBlocked :: boolean()) -> atom().
get_geo_tag(_Uid, GpsLocation, _FilterBlocked) when GpsLocation =:= undefined -> undefined;
get_geo_tag(Uid, GpsLocation = #pb_gps_location{latitude = Latitude, longitude = Longitude}, FilterBlocked) ->
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
    FinalGeoTag = case FilterBlocked of
        false -> GeoTag;
        true ->
            case sets:is_element(GeoTag, sets:from_list(model_accounts:get_blocked_geo_tags(Uid))) of
                true -> undefined;
                false -> GeoTag
            end
    end,
    ?INFO("Uid: ~p, GpsLocation: ~p, GeoTag assigned: ~p", [Uid, GpsLocation, FinalGeoTag]),
    FinalGeoTag.


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
        [{34.050827, -118.458642},
         {34.056059, -118.419916},
         {34.079122, -118.433941},
         {34.078689, -118.453409}]},
    {pepperdine,
        [{34.032596, -118.719939},
         {34.033628, -118.700112},
         {34.050839, -118.700670},
         {34.049915, -118.724660}]},
    {pepperdine,
        [{33.973472, -118.394384},
         {33.973971, -118.388364},
         {33.978413, -118.388470},
         {33.978794, -118.394057}]},
    {ucsb,
        [{34.401100, -119.883962},
         {34.402512, -119.825374},
         {34.428859, -119.824220},
         {34.427692, -119.879719}]},
    {csulb,
        [{33.744906, -118.133806},
         {33.743926, -118.093462},
         {33.793045, -118.088869},
         {33.792736, -118.130826}]},
    {ucdavis,
        [{38.530611, -121.795374},
         {38.525800, -121.703687},
         {38.555099, -121.701078},
         {38.557285, -121.811774}]},
    {ucberkeley,
        [{37.852175, -122.276108},
         {37.861299, -122.225091},
         {37.885667, -122.233477},
         {37.885401, -122.283466}]},
    {cal_poly,
        [{35.294871, -120.673424},
         {35.295558, -120.651501},
         {35.310952, -120.655267},
         {35.312516, -120.672516}]},
    {stanford,
        [{37.402363, -122.182350},
         {37.427907, -122.148653},
         {37.447210, -122.171303},
         {37.428688, -122.200433}]},
    {usc,
        [{34.032831, -118.300221},
         {34.031894, -118.266547},
         {34.007679, -118.264816},
         {34.007348, -118.300088}]},
    {lmu,
        [{33.979609, -118.427413},
         {33.984794, -118.403582},
         {33.957656, -118.402818},
         {33.956849, -118.433179}]},
    {ashokau,
        [{28.943083, 77.099534},
         {28.943766, 77.104514},
         {28.951757, 77.104743},
         {28.950994, 77.097699}]}
    ].


%% Function to manually run for pepperdine, ucdavis, ucberkeley, ashokau
map_geo_tags(OldGeoTag, NewGeoTag) ->
    AllUids = model_accounts:get_geotag_uids(OldGeoTag),
    lists:foreach(
        fun(Uid) ->
            model_accounts:add_geo_tag(Uid, NewGeoTag, util:now())
        end, AllUids),
    ok.


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

