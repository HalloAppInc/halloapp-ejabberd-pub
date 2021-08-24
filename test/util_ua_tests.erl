%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 31. Mar 2020 3:14 PM
%%%-------------------------------------------------------------------
-module(util_ua_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").

simple_test() ->
    ?assert(true).

is_android_debug_test() ->
    ?assertEqual(true, util_ua:is_android_debug("HalloApp/Android1.0.0D")),
    ?assertEqual(false, util_ua:is_android_debug("HalloApp/Android1.0.0")),
    ?assertEqual(false, util_ua:is_android_debug("Random")),
    ?assertEqual(false, util_ua:is_android_debug("")),
    ok.

is_android_release_test() ->
    ?assertEqual(false, util_ua:is_android_release("HalloApp/Android1.0.0D")),
    ?assertEqual(true, util_ua:is_android_release("HalloApp/Android1.0.0")),
    ?assertEqual(false, util_ua:is_android_release("Random")),
    ?assertEqual(false, util_ua:is_android_release("")),
    ok.

is_android_test() ->
    ?assertEqual(true, util_ua:is_android("HalloApp/Android1.2.3")),
    ?assertEqual(false, util_ua:is_android("HalloApp/iOS")),
    ?assertEqual(false, util_ua:is_android("")),
    ok.

is_valid_ua_test() ->
    ?assertEqual(true, util_ua:is_valid_ua("HalloApp/Android1.2.3")),
    ?assertEqual(true, util_ua:is_valid_ua("HalloApp/Android1.2.3D")),
    ?assertEqual(true, util_ua:is_valid_ua("HalloApp/iOS1.2.3")),
    ?assertEqual(false, util_ua:is_valid_ua("HalloApp/other")),
    ?assertEqual(false, util_ua:is_valid_ua("Not")),
    ?assertEqual(false, util_ua:is_valid_ua("something HalloApp/Android1.2.3")),
    ok.

get_client_type_test() ->
    ?assertEqual(android, util_ua:get_client_type(<<"HalloApp/Android1.0">>)),
    ?assertEqual(ios, util_ua:get_client_type(<<"HalloApp/iOS1.0">>)),
    ?assertEqual(undefined, util_ua:get_client_type(<<"HalloApp/other">>)).


is_version_greater_than_test() ->
    ?assertEqual(true, util_ua:is_version_greater_than(<<"HalloApp/iOS1.0.0">>, <<"HalloApp/iOS0.3.65">>)),
    ?assertEqual(true, util_ua:is_version_greater_than(<<"HalloApp/iOS0.3.73">>, <<"HalloApp/iOS0.3.65">>)),
    ?assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/iOS0.3.62">>, <<"HalloApp/iOS0.3.65">>)),
    ?assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/iOS0.2.90">>, <<"HalloApp/iOS0.3.65">>)),
    ?assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/iOS0.3.65">>, <<"HalloApp/iOS0.3.65">>)),

    ?assertEqual(true, util_ua:is_version_greater_than(<<"HalloApp/Android1.0">>, <<"HalloApp/Android0.89">>)),
    ?assertEqual(true, util_ua:is_version_greater_than(<<"HalloApp/Android0.100">>, <<"HalloApp/Android0.89">>)),
    ?assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/Android0.88">>, <<"HalloApp/Android0.89">>)),
    ?assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/Android0.89">>, <<"HalloApp/Android0.89">>)),
    ok.


is_version_less_than_test() ->
    ?assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/iOS1.0.0">>, <<"HalloApp/iOS0.3.72">>)),
    ?assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/iOS0.3.73">>, <<"HalloApp/iOS0.3.72">>)),
    ?assertEqual(true, util_ua:is_version_less_than(<<"HalloApp/iOS0.3.62">>, <<"HalloApp/iOS0.3.72">>)),
    ?assertEqual(true, util_ua:is_version_less_than(<<"HalloApp/iOS0.2.90">>, <<"HalloApp/iOS0.3.72">>)),
    ?assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/iOS0.3.72">>, <<"HalloApp/iOS0.3.72">>)),

    ?assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/Android1.0">>, <<"HalloApp/Android0.93">>)),
    ?assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/Android0.100">>, <<"HalloApp/Android0.93">>)),
    ?assertEqual(true, util_ua:is_version_less_than(<<"HalloApp/Android0.88">>, <<"HalloApp/Android0.93">>)),
    ?assertEqual(true, util_ua:is_version_less_than(<<"HalloApp/Android0.89">>, <<"HalloApp/Android0.93">>)),
    ok.


