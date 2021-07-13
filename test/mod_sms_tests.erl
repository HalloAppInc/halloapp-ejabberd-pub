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
-include("time.hrl").

-define(PHONE, <<"14703381473">>).
-define(TEST_PHONE, <<"16175550000">>).


simple_test() ->
    ?assert(true).

get_app_hash_test() ->
    ?assertEqual(?ANDROID_DEBUG_HASH, util_ua:get_app_hash("HalloApp/Android1.0.0D")),
    ?assertEqual(?ANDROID_RELEASE_HASH, util_ua:get_app_hash("HalloApp/Android1.0.0")),
    ?assertEqual(<<"">>, util_ua:get_app_hash("HalloApp/iOS1.2.93")),
    ?assertEqual(<<"">>, util_ua:get_app_hash("HalloApp/random")),
    ok.

generate_code_test() ->
    CodeBin = mod_sms:generate_code(?PHONE),
    Code = binary_to_integer(CodeBin),
    ?assert(Code >= 0),
    ?assert(Code =< 999999),
    ?assertEqual(<<"111111">>, mod_sms:generate_code(?TEST_PHONE)),
    ok.


is_too_soon_test() ->
    Now = util:now(),
    
    {false, _} = mod_sms:is_too_soon([]),
    OldResponses = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 10)}],
    %% Need 30 seconds gap.
    {true, _} = mod_sms:is_too_soon(OldResponses),
    OldResponses1 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 30 * ?SECONDS)}],
    {false, _} = mod_sms:is_too_soon(OldResponses1),
    
    OldResponses2 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 50 * ?SECONDS)},
                    #gateway_response{method = sms, attempt_ts = util:to_binary(Now - 21 * ?SECONDS)}],
    %% Need 60 seconds gap.
    {true, _} = mod_sms:is_too_soon(OldResponses2),
    OldResponses3 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 120 * ?SECONDS)},
                    #gateway_response{method = sms, attempt_ts = util:to_binary(Now - 60 * ?SECONDS)}],
    {false, _} = mod_sms:is_too_soon(OldResponses3).


% twilio_test() ->
%     State = mod_sms:make_state(),
%     Body = mod_sms:compose_twilio_body(<<"123">>, "test"),
%     ?assertEqual("To=%2B123&From=%2B" ++ string:slice(?FROM_PHONE, 1) ++ "&Body=test", Body),
%     ?assertNotEqual("", mod_sms:get_twilio_account_sid(State)),
%     ?assertNotEqual("", mod_sms:get_twilio_auth_token(State)),
% %%    ?debugVal(Body),
%     ok.

