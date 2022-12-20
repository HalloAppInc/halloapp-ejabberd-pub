%%%-------------------------------------------------------------------
%%% File: util_moments.erl
%%% copyright (C) 2022, HalloApp, Inc.
%%%
%%%-------------------------------------------------------------------
-module(util_moments).
-author('vipin').

-include("moments.hrl").
-include("logger.hrl").

-export([
    to_moment_type/1,
    moment_type_to_bin/1
]).

-spec to_moment_type(Bin :: binary()) -> moment_type().
to_moment_type(Bin) ->
    case util:to_integer_maybe(Bin) of
        undefined ->
            ?ERROR("Got invalid type: ~p", [Bin]),
            live_camera;
        1 -> live_camera;
        2 -> text_post;
        _ ->
            ?ERROR("Got invalid type: ~p", [Bin]),
            live_camera
    end.

-spec moment_type_to_bin(MomentType :: moment_type()) -> binary().
moment_type_to_bin(MomentType) ->
    case MomentType of
        live_camera -> <<"1">>;
        text_post -> <<"2">>
    end.

