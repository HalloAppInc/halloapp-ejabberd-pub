%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp Inc.
%%% @doc
%%% Utility functions for parsing UserAgents, and App Version.
%%% @end
%%% Created : 31. Mar 2020 10:29 AM
%%%-------------------------------------------------------------------
-module(util_ua).
-author("nikola").

-include("ha_types.hrl").

%% API
-export([
    get_client_type/1,
    is_android/1,
    is_android_debug/1,
    is_android_release/1,
    is_hallo_ua/1,
    resource_to_client_type/1
]).

%% TODO: add function is_ios(), add case where user agent cannot be parsed
-spec get_client_type(RawUserAgent :: binary()) -> client_type().
get_client_type(RawUserAgent) ->
    case is_android(RawUserAgent) of
        true -> android;
        false -> ios
    end.

-spec is_android_debug(binary()) -> boolean().
is_android_debug(UserAgent) ->
    case re_match(UserAgent, "HalloApp\/Android.*D$") of
        match -> true;
        nomatch -> false
    end.

-spec is_android(binary()) -> boolean().
is_android(UserAgent) ->
    case re_match(UserAgent, "HalloApp\/Android.*$") of
        match -> true;
        nomatch -> false
    end.

-spec is_android_release(binary()) -> boolean().
is_android_release(UserAgent) ->
    is_android(UserAgent) and not is_android_debug(UserAgent).


-spec is_hallo_ua(binary()) -> boolean().
is_hallo_ua(UserAgent) ->
    case re_match(UserAgent, "^HalloApp\/") of
        match -> true;
        nomatch -> false
    end.

-spec re_match(iodata(), any()) -> {match | nomatch}.
re_match(Subject, RE) ->
    re:run(Subject, RE, [{capture, none}]).


-spec resource_to_client_type(Resource :: binary()) -> client_type() | undefined.
resource_to_client_type(Resource) ->
    case Resource of
        <<"android">> -> android;
        <<"iphone">> -> ios;
        <<"ipad">> -> ios;
        _ -> undefined
    end.
