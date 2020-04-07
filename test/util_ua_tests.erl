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
    ?assertEqual(false, util_ua:is_android("HalloApp/iPhone")),
    ?assertEqual(false, util_ua:is_android("")),
    ok.

is_hallo_ua_test() ->
    ?assertEqual(true, util_ua:is_hallo_ua("HalloApp/Android1.2.3")),
    ?assertEqual(true, util_ua:is_hallo_ua("HalloApp/Android1.2.3D")),
    ?assertEqual(true, util_ua:is_hallo_ua("HalloApp/iPhone1.2.3")),
    ?assertEqual(true, util_ua:is_hallo_ua("HalloApp/other")),
    ?assertEqual(false, util_ua:is_hallo_ua("Not")),
    ok.
