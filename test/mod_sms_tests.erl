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
-include("logger.hrl").

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
    OldResponses = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 10), status = sent}],
    %% Need 30 seconds gap.
    {true, _} = mod_sms:is_too_soon(OldResponses),
    OldResponses1 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 30 * ?SECONDS)}],
    {false, _} = mod_sms:is_too_soon(OldResponses1),
    
    OldResponses2 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 50 * ?SECONDS), status = sent},
                    #gateway_response{method = sms, attempt_ts = util:to_binary(Now - 21 * ?SECONDS), status = sent}],
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


choose_other_gateway_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(twilio, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(twilio_verify, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(mbird, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    {error, _, sms_fail} = mod_sms:smart_send(?PHONE, ?PHONE, <<>>, <<>>, sms, []),
    % check if all gateways were attempted
    ?assert(meck:called(twilio, send_sms, ['_','_','_','_'])),
    ?assert(meck:called(twilio_verify, send_sms, ['_','_','_','_'])),
    ?assert(meck:called(mbird, send_sms, ['_','_','_','_'])),
    meck_finish(mbird),
    meck_finish(twilio),
    meck_finish(twilio_verify),
    % check eventual success if starting at a failed gateway, but other works
    TwilGtwy = #gateway_response{gateway = twilio, method = sms},
    MbirdGtwy = #gateway_response{gateway = mbird, method = sms},
    TVerifyGtwy = #gateway_response{gateway = twilio_verify, method = sms},
    meck_init(mbird, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(twilio, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(twilio_verify, send_sms, fun(_,_,_,_) -> {ok, TVerifyGtwy} end),
    {ok, #gateway_response{gateway = twilio_verify}} =
        mod_sms:smart_send(?PHONE, ?PHONE, <<>>, <<>>, sms, [TwilGtwy, TVerifyGtwy, MbirdGtwy]),
    ?assert(meck:called(twilio, send_sms, ['_','_','_','_']) orelse
            meck:called(mbird, send_sms, ['_','_','_','_']) orelse
            meck:called(twilio_verify, send_sms, ['_','_','_','_'])),
    % Test restricted country gateways
    meck_init(mod_libphonenumber, get_cc, fun(_) -> <<"CN">> end),
    {ok, #gateway_response{gateway = twilio_verify}} =
        mod_sms:smart_send(?PHONE, ?PHONE, <<>>, <<>>, sms, []),
    meck_finish(mod_libphonenumber),
    meck_finish(twilio),
    meck_finish(twilio_verify),
    meck_finish(mbird),
    meck_finish(ejabberd_router).


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_whisper),
    ok.


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod, [passthrough]),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).

