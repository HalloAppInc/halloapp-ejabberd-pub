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


test_is_android_debug(_) ->
    {inparallel, [
        ?_assertEqual(true, util_ua:is_android_debug("HalloApp/Android1.0.0D")),
        ?_assertEqual(false, util_ua:is_android_debug("HalloApp/Android1.0.0")),
        ?_assertEqual(false, util_ua:is_android_debug("Katchup/Android1.0.0D")),
        ?_assertEqual(false, util_ua:is_android_debug("Katchup/Android1.0.0")),
        ?_assertEqual(false, util_ua:is_android_debug("Random")),
        ?_assertEqual(false, util_ua:is_android_debug(""))
    ]}.

test_is_android_release(_) ->
    {inparallel, [
        ?_assertEqual(false, util_ua:is_android_release("HalloApp/Android1.0.0D")),
        ?_assertEqual(true, util_ua:is_android_release("HalloApp/Android1.0.0")),
        ?_assertEqual(false, util_ua:is_android_release("Katchup/Android1.0.0D")),
        ?_assertEqual(false, util_ua:is_android_release("Katchup/Android1.0.0")),
        ?_assertEqual(false, util_ua:is_android_release("Random")),
        ?_assertEqual(false, util_ua:is_android_release(""))
    ]}.

test_is_android(_) ->
    {inparallel, [
        ?_assertEqual(true, util_ua:is_android("HalloApp/Android1.2.3")),
        ?_assertEqual(false, util_ua:is_android("HalloApp/iOS")),
        ?_assertEqual(false, util_ua:is_android("Katchup/Android1.2.3")),
        ?_assertEqual(false, util_ua:is_android("Katchup/iOS")),
        ?_assertEqual(false, util_ua:is_android(""))
    ]}.

test_is_valid_ua(_) ->
    {inparallel, [
        ?_assertEqual(true, util_ua:is_valid_ua("HalloApp/Android1.2.3")),
        ?_assertEqual(true, util_ua:is_valid_ua("HalloApp/Android1.2.3D")),
        ?_assertEqual(true, util_ua:is_valid_ua("HalloApp/iOS1.2.3")),
        ?_assertEqual(false, util_ua:is_valid_ua("Katchup/Android1.2.3")),
        ?_assertEqual(false, util_ua:is_valid_ua("Katchup/Android1.2.3D")),
        ?_assertEqual(false, util_ua:is_valid_ua("Katchup/iOS1.2.3")),
        ?_assertEqual(false, util_ua:is_valid_ua("HalloApp/other")),
        ?_assertEqual(false, util_ua:is_valid_ua("Katchup/other")),
        ?_assertEqual(false, util_ua:is_valid_ua("Not")),
        ?_assertEqual(false, util_ua:is_valid_ua("something HalloApp/Android1.2.3")),
        ?_assertEqual(false, util_ua:is_valid_ua("something Katchup/Android1.2.3"))
    ]}.

test_get_client_type(_) ->
    {inparallel, [
        ?_assertEqual(android, util_ua:get_client_type(<<"HalloApp/Android1.0">>)),
        ?_assertEqual(ios, util_ua:get_client_type(<<"HalloApp/iOS1.0">>)),
        ?_assertEqual(undefined, util_ua:get_client_type(<<"HalloApp/other">>)),
        ?_assertEqual(undefined, util_ua:get_client_type(<<"Katchup/Android1.0">>)),
        ?_assertEqual(undefined, util_ua:get_client_type(<<"Katchup/iOS1.0">>)),
        ?_assertEqual(undefined, util_ua:get_client_type(<<"Katchup/other">>))
    ]}.


test_is_version_greater_than(_) ->
    {inparallel, [
        ?_assertEqual(true, util_ua:is_version_greater_than(<<"HalloApp/iOS1.0.0">>, <<"HalloApp/iOS0.3.65">>)),
        ?_assertEqual(true, util_ua:is_version_greater_than(<<"HalloApp/iOS0.3.73">>, <<"HalloApp/iOS0.3.65">>)),
        ?_assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/iOS0.3.62">>, <<"HalloApp/iOS0.3.65">>)),
        ?_assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/iOS0.2.90">>, <<"HalloApp/iOS0.3.65">>)),
        ?_assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/iOS0.3.65">>, <<"HalloApp/iOS0.3.65">>)),

        ?_assertEqual(true, util_ua:is_version_greater_than(<<"HalloApp/Android1.0">>, <<"HalloApp/Android0.89">>)),
        ?_assertEqual(true, util_ua:is_version_greater_than(<<"HalloApp/Android0.100">>, <<"HalloApp/Android0.89">>)),
        ?_assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/Android0.88">>, <<"HalloApp/Android0.89">>)),
        ?_assertEqual(false, util_ua:is_version_greater_than(<<"HalloApp/Android0.89">>, <<"HalloApp/Android0.89">>))
    ]}.


test_is_version_less_than(_) ->
    {inparallel, [
        ?_assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/iOS1.0.0">>, <<"HalloApp/iOS0.3.72">>)),
        ?_assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/iOS0.3.73">>, <<"HalloApp/iOS0.3.72">>)),
        ?_assertEqual(true, util_ua:is_version_less_than(<<"HalloApp/iOS0.3.62">>, <<"HalloApp/iOS0.3.72">>)),
        ?_assertEqual(true, util_ua:is_version_less_than(<<"HalloApp/iOS0.2.90">>, <<"HalloApp/iOS0.3.72">>)),
        ?_assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/iOS0.3.72">>, <<"HalloApp/iOS0.3.72">>)),

        ?_assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/Android1.0">>, <<"HalloApp/Android0.93">>)),
        ?_assertEqual(false, util_ua:is_version_less_than(<<"HalloApp/Android0.100">>, <<"HalloApp/Android0.93">>)),
        ?_assertEqual(true, util_ua:is_version_less_than(<<"HalloApp/Android0.88">>, <<"HalloApp/Android0.93">>)),
        ?_assertEqual(true, util_ua:is_version_less_than(<<"HalloApp/Android0.89">>, <<"HalloApp/Android0.93">>))
    ]}.


do_util_ua_test_() ->
    % Note, this is an unnecessary amount of complexity -- all of these test functions could just end
    % in _test_() and work great. It's just fun to parallelize to go super duper fast
    tutil:true_parallel([
       fun test_is_android_debug/1,
       fun test_is_android_release/1,
       fun test_is_android/1,
       fun test_is_valid_ua/1,
       fun test_get_client_type/1,
       fun test_is_version_greater_than/1,
       fun test_is_version_less_than/1
    ]).
