%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 31. Mar 2020 2:53 PM
%%%-------------------------------------------------------------------
-module(mod_sms_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").
-include("sms.hrl").

-compile(export_all).

simple_test() ->
    ?assert(true).

get_app_hash_test() ->
    ?assertEqual(?ANDROID_DEBUG_HASH, mod_sms:get_app_hash("HalloApp/Android1.0.0D")),
    ?assertEqual(?ANDROID_RELEASE_HASH, mod_sms:get_app_hash("HalloApp/Android1.0.0")),
    ?assertEqual(<<"">>, mod_sms:get_app_hash("HalloApp/random")),
    ok.

generate_code_test() ->
    CodeBin = mod_sms:generate_code(false),
    Code = binary_to_integer(CodeBin),
    ?assert(Code >= 0),
    ?assert(Code =< 999999),
    ?assertEqual(<<"111111">>, mod_sms:generate_code(true)),
    ok.

twilio_test() ->
    State = mod_sms:make_state(),
    Body = mod_sms:compose_twilio_body("123", "test"),
    ?assertEqual("To=%2B123&From=%2B" ++ string:slice(?FROM_PHONE, 1) ++ "&Body=test", Body),
    ?assertNotEqual("", mod_sms:get_twilio_account_sid(State)),
    ?assertNotEqual("", mod_sms:get_twilio_auth_token(State)),
%%    ?debugVal(Body),
    ok.

