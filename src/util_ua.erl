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
-include("sms.hrl").

%% API
-export([
    is_halloapp/1,
    is_katchup/1,
    get_client_type/1,
    get_app_type/1,
    get_app_hash/1,
    is_android/1,
    is_ios/1,
    is_android_debug/1,
    is_android_release/1,
    is_valid_ua/1,
    resource_to_client_type/1,
    is_resource_extension/1,
    is_version_greater_than/2,
    is_version_less_than/2
]).


-spec is_halloapp(UserAgent :: binary()) -> boolean().
is_halloapp(UserAgent) ->
    case re_match(UserAgent, "HalloApp") of
        match -> true;
        nomatch -> false
    end.


-spec is_katchup(UserAgent :: binary()) -> boolean().
is_katchup(UserAgent) ->
    case re_match(UserAgent, "Katchup") of
        match -> true;
        nomatch -> false
    end.


-spec get_client_type(RawUserAgent :: binary()) -> maybe(client_type()).
get_client_type(undefined) -> undefined;
get_client_type(RawUserAgent) ->
    case {is_android(RawUserAgent), is_ios(RawUserAgent)} of
        {true, false} -> android;
        {false, true} -> ios;
        _ -> undefined
    end.


-spec get_app_type(RawUserAgent :: binary()) -> maybe(app_type()).
get_app_type(undefined) -> undefined;
get_app_type(RawUserAgent) ->
    case is_halloapp(RawUserAgent) of
        true -> halloapp;
        false ->
            case is_katchup(RawUserAgent) of
                true -> katchup;
                false -> undefined
            end
    end.


%% TODO: Send AppHash for Katchup.
-spec get_app_hash(UserAgent :: binary()) -> binary().
get_app_hash(UserAgent) ->
    case is_halloapp(UserAgent) of
        true ->
            case {is_android_debug(UserAgent), is_android(UserAgent)} of
                {true, true} -> ?ANDROID_DEBUG_HASH;
                {false, true} -> ?ANDROID_RELEASE_HASH;
                _ -> <<"">>
            end;
        false ->
            case {is_android_debug(UserAgent), is_android(UserAgent)} of
                {true, true} -> ?KATCHUP_ANDROID_DEBUG_HASH;
                {false, true} -> ?KATCHUP_ANDROID_RELEASE_HASH;
                _ -> <<>>
            end
    end.


-spec is_android_debug(binary()) -> boolean().
is_android_debug(UserAgent) ->
    case re_match(UserAgent, "^HalloApp\/Android.*D$") =:= match of
        true -> true;
        false -> false
    end.

-spec is_android(binary()) -> boolean().
is_android(UserAgent) ->
    case re_match(UserAgent, "^HalloApp\/Android.*$") =:= match of
        true -> true;
        false -> false
    end.

-spec is_ios(binary()) -> boolean().
is_ios(UserAgent) ->
    case re_match(UserAgent, "^HalloApp\/iOS.*$") =:= match of
        true -> true;
        false -> false
    end.

-spec is_android_release(binary()) -> boolean().
is_android_release(UserAgent) ->
    is_android(UserAgent) and not is_android_debug(UserAgent).


-spec is_valid_ua(binary()) -> boolean().
is_valid_ua(undefined) -> false;
is_valid_ua(UserAgent) ->
    is_android(UserAgent) orelse is_ios(UserAgent).


-spec re_match(iodata(), any()) -> match | nomatch.
re_match(Subject, RE) ->
    re:run(Subject, RE, [{capture, none}]).

% TODO: maybe rename client_type to platform everywhere
-spec resource_to_client_type(Resource :: maybe(binary())) -> maybe(client_type()).
resource_to_client_type(Resource) ->
    case Resource of
        <<"android">> -> android;
        <<"iphone">> -> ios;
        <<"iphone_nse">> -> ios;
        <<"iphone_share">> -> ios;
        <<"ipad">> -> ios;
        _ -> undefined
    end.


-spec is_resource_extension(Resource :: maybe(binary())) -> boolean().
is_resource_extension(Resource) ->
    case Resource of
        <<"android">> -> false;
        <<"iphone">> -> false;
        <<"iphone_nse">> -> true;
        <<"iphone_share">> -> true;
        <<"ipad">> -> false;
        _ -> false
    end.


%% Returns true if Version1 is strictly greater than Version2.
-spec is_version_greater_than(Version1 :: binary(), Version2 :: binary()) -> boolean().
is_version_greater_than(Version1, Version1) -> false;
is_version_greater_than(Version1, Version2) ->
    {Major1, Minor1, Patch1} = split_version(Version1),
    {Major2, Minor2, Patch2} = split_version(Version2),
    if
        Major1 > Major2 ->
            true;
        Major1 =:= Major2 andalso Minor1 > Minor2 ->
            true;
        Major1 =:= Major2 andalso Minor1 =:= Minor2 andalso Patch1 > Patch2 ->
            true;
        true ->
            false
    end.


%% Returns true if Version1 is strictly less than Version2.
-spec is_version_less_than(Version1 :: binary(), Version2 :: binary()) -> boolean().
is_version_less_than(Version1, Version1) -> false;
is_version_less_than(Version1, Version2) ->
    is_version_greater_than(Version2, Version1).



-spec split_version(Version :: binary()) -> {integer(), integer(), integer()}.
split_version(Version) ->
    case is_halloapp(Version) of
        true -> split_halloapp_version(Version);
        false ->
            case is_katchup(Version) of
                true -> split_katchup_version(Version);
                false -> {undefined, undefined, undefined}
            end
    end.


-spec split_halloapp_version(Version :: binary()) -> {integer(), integer(), integer()}.
split_halloapp_version(Version) ->
    case util_ua:get_client_type(Version) of
        android ->
            case re:run(Version, "^HalloApp\/Android([0-9]+).([0-9]+)D?$", [{capture, all, binary}]) of
                nomatch ->
                    case re:run(Version, "^HalloApp\/Android([0-9]+).([0-9]+).([0-9]+)D?$", [{capture, all, binary}]) of
                        {match, [Version, Major, Minor, Patch]} ->
                            {binary_to_integer(Major), binary_to_integer(Minor), binary_to_integer(Patch)};
                        nomatch ->
                            {undefined, undefined, undefined}
                    end;
                {match, [Version, Major, Patch]} ->
                    {binary_to_integer(Major), 1, binary_to_integer(Patch)}
            end;
        ios ->
            case re:run(Version, "^HalloApp\/iOS([0-9]+).([0-9]+).([0-9]+)$", [{capture, all, binary}]) of
                nomatch ->
                    {undefined, undefined, undefined};
                {match, [Version, Major, Minor, Patch]} ->
                    {binary_to_integer(Major), binary_to_integer(Minor), binary_to_integer(Patch)}
            end;
        undefined ->
            {undefined, undefined, undefined}
    end.


-spec split_katchup_version(Version :: binary()) -> {integer(), integer(), integer()}.
split_katchup_version(Version) ->
    case util_ua:get_client_type(Version) of
        android ->
            case re:run(Version, "^Katchup\/Android([0-9]+).([0-9]+)D?$", [{capture, all, binary}]) of
                nomatch ->
                    case re:run(Version, "^Katchup\/Android([0-9]+).([0-9]+).([0-9]+)D?$", [{capture, all, binary}]) of
                        {match, [Version, Major, Minor, Patch]} ->
                            {binary_to_integer(Major), binary_to_integer(Minor), binary_to_integer(Patch)};
                        nomatch ->
                            {undefined, undefined, undefined}
                    end;
                {match, [Version, Major, Patch]} ->
                    {binary_to_integer(Major), 1, binary_to_integer(Patch)}
            end;
        ios ->
            case re:run(Version, "^Katchup\/iOS([0-9]+).([0-9]+).([0-9]+)$", [{capture, all, binary}]) of
                nomatch ->
                    {undefined, undefined, undefined};
                {match, [Version, Major, Minor, Patch]} ->
                    {binary_to_integer(Major), binary_to_integer(Minor), binary_to_integer(Patch)}
            end;
        undefined ->
            {undefined, undefined, undefined}
    end.

