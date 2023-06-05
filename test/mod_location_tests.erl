%%%-------------------------------------------------------------------
%%% File: mod_location_tests.erl
%%%
%%% Copyright (C) 2022, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_location_tests).
-author('murali').

-include("packets.hrl").
-include("feed.hrl").

-include("tutil.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(PHONE1, <<"14703381473">>).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

setup() ->
    tutil:setup([
        {meck, model_accounts, get_blocked_geo_tags, fun(_) -> [] end}
    ]).


set_name_iq_testset() ->
    GpsLocation1 = #pb_gps_location{latitude = 37.4290788, longitude = -122.1432234},
    GpsLocation2 = #pb_gps_location{latitude = 37.4278570, longitude = -122.1420737},
    [?_assertEqual(katchup_hq, mod_location:get_geo_tag(?UID1, GpsLocation1)),
    ?_assertEqual(undefined, mod_location:get_geo_tag(?UID1, GpsLocation2))].


clockwise_points_testset() ->
    %% Ensures our defined locations are points in clockwise order
    lists:map(
        fun({Tag, PointList}) ->
            %% From: https://stackoverflow.com/q/38080582/11106258
            %% A is the vertex with the smallest Y value (largest X is tiebreaker)
            {A, Index, _} = lists:foldl(
                fun({X1, Y1} = P1, {{X2, Y2} = P2, PIndex, CurrIndex}) ->
                    P = if
                        Y1 < Y2 -> P1;
                        Y1 == Y2 ->
                            case X1 > X2 of
                                true -> P1;
                                false -> P2
                            end;
                        Y1 > Y2 -> P2
                    end,
                    case P of
                        P1 -> {P, CurrIndex, CurrIndex + 1};
                        P2 -> {P, PIndex, CurrIndex + 1}
                    end
                end,
                {{1.0e10, 1.0e10}, 1, 1},
                PointList),
            LastIndex = length(PointList),
            {PrevIndex, NextIndex} = case Index of
                1 -> {LastIndex, 2};
                LastIndex -> {3, 1};
                _ -> {Index - 1, Index + 1}
            end,
            %% B is the vertex before A; C the vertex after A
            B = lists:nth(PrevIndex, PointList),
            C = lists:nth(NextIndex, PointList),
            {XA, YA} = A,
            {XB, YB} = B,
            {XC, YC} = C,
            %% Compute the sign of the cross product AB x AC by finding the determinant
            Determinant = ((XB * YC) + (XA * YB) + (YA * XC)) - ((YA * XB) + (YB * XC) + (XA * YC)),
            %% If Determinant is 0, the points are collinear
            IsClockwise = (Determinant > 0) andalso (Determinant =/= 0),
            %% test is formatted in this way so the output of a failed test is easy to understand
            ?_assertMatch({Tag, true, _}, {Tag, IsClockwise, Determinant})
        end,
        mod_location:get_tagged_locations()).


convex_polygon_testset() ->
    %% Ensures our defined locations are convex polygons
    lists:map(
        fun({Tag, PointList}) ->
            %% From: https://stackoverflow.com/a/45372025/11106258
            % Get starting information
            {InitOldX, InitOldY} = lists:nth(length(PointList) - 1, PointList),
            {InitNewX, InitNewY} = lists:last(PointList),
            InitNewDirection = math:atan2(InitNewY - InitOldY, InitNewX - InitOldX),
            Pi = math:pi(),
            {FinalAngleSum, _, _, _, _, SubTests} = lists:foldl(
                fun({NewX, NewY}, {AngleSum, Index, {OldX, OldY}, OldDirection, Orientation, Tests}) ->
                    % Update point coordinates and side directions, check side length
                    NewDirection = math:atan2(NewY - OldY, NewX - OldX),
                    % Calculate & check the normalized direction-change angle
                    InitAngle = NewDirection - OldDirection,
                    Angle = if
                        InitAngle =< -Pi -> InitAngle + (2 * Pi);
                        InitAngle > Pi -> InitAngle - (2 * Pi);
                        true -> InitAngle
                    end,
                    {NewTest, NewOrientation} = case Index of
                        1 ->
                            % if first time through loop, initialize orientation
                            NewOrient = case Angle > 0 of
                                true -> 1;
                                false -> -1
                            end,
                            {?_assertNotEqual({Tag, 0}, {Tag, Angle}), NewOrient};
                        _ ->
                            % if other time through loop, check orientation is stable
                            OrientationCheck = Orientation * Angle,
                            {?_assertMatch({Tag, true, _}, {Tag, OrientationCheck > 0, OrientationCheck}), Orientation}
                    end,
                    % Accumulate the direction-change angle and update values to change in next loop
                    {AngleSum + Angle, Index + 1, {NewX, NewY}, NewDirection, NewOrientation, [NewTest | Tests]}
                end,
                {0.0, 1, {InitNewX, InitNewY}, InitNewDirection, 0, []},
                PointList),
                % Check that the total number of full turns is plus-or-minus 1
                [?_assertEqual({Tag, 1}, {Tag, abs(round(FinalAngleSum / (2 * math:pi())))}) | SubTests]
        end,
        mod_location:get_tagged_locations()).

