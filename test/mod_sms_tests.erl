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
-define(CODE1, <<"041200">>).
-define(CODE2, <<"084752">>).
-define(SID1, <<"sid1">>).
-define(SID2, <<"sid2">>).


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
    meck_init(mbird_verify, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(telesign, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(clickatell, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    {error, _, sms_fail} = mod_sms:smart_send(?PHONE, ?PHONE, <<>>, <<>>, sms, <<>>, []),
    % check if all gateways were attempted
    ?assert(meck:called(twilio, send_sms, ['_','_','_','_'])),
    ?assert(meck:called(twilio_verify, send_sms, ['_','_','_','_'])),
    ?assert(meck:called(mbird, send_sms, ['_','_','_','_'])),
    meck_finish(clickatell),
    meck_finish(telesign),
    meck_finish(mbird),
    meck_finish(twilio),
    meck_finish(twilio_verify),
    meck_finish(mbird_verify),
    % check eventual success if starting at a failed gateway, but other works
    TwilGtwy = #gateway_response{gateway = twilio, method = sms},
    MbirdGtwy = #gateway_response{gateway = mbird, method = sms},
    MbirdVerifyGtwy = #gateway_response{gateway = mbird_verify, method = sms},
    TVerifyGtwy = #gateway_response{gateway = twilio_verify, method = sms},
    TelesignGtwy = #gateway_response{gateway = telesign, method = sms},
    ClickatellGtwy = #gateway_response{gateway = clickatell, method = sms},
    meck_init(mbird, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(mbird_verify, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(twilio, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(twilio_verify, send_sms, fun(_,_,_,_) -> {ok, TVerifyGtwy} end),
    meck_init(telesign, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    meck_init(clickatell, send_sms, fun(_,_,_,_) -> {error, sms_fail, retry} end),
    {ok, #gateway_response{gateway = twilio_verify}} =
        mod_sms:smart_send(?PHONE, ?PHONE, <<>>, <<>>, sms, <<>>, [TwilGtwy, TVerifyGtwy, MbirdGtwy, MbirdVerifyGtwy, TelesignGtwy, ClickatellGtwy]),
    ?assert(meck:called(twilio, send_sms, ['_','_','_','_']) orelse
            meck:called(mbird, send_sms, ['_','_','_','_']) orelse
            meck:called(mbird_verify, send_sms, ['_','_','_','_']) orelse
            meck:called(telesign, send_sms, ['_','_','_','_']) orelse
            meck:called(clickatell, send_sms, ['_','_','_','_']) orelse
            meck:called(twilio_verify, send_sms, ['_','_','_','_'])),
    % Test restricted country gateways
    meck_init(mod_libphonenumber, get_cc, fun(_) -> <<"CN">> end),
    {ok, #gateway_response{gateway = twilio_verify}} =
        mod_sms:smart_send(?PHONE, ?PHONE, <<>>, <<>>, sms, <<>>, []),
    meck_finish(mod_libphonenumber),
    meck_finish(clickatell),
    meck_finish(telesign),
    meck_finish(twilio),
    meck_finish(twilio_verify),
    meck_finish(mbird),
    meck_finish(mbird_verify),
    meck_finish(ejabberd_router).


disable_otp_after_success_test() ->
    {ok, AttemptId1, _} = model_phone:add_sms_code2(?PHONE, ?CODE1),
    ok = model_phone:add_gateway_response(?PHONE, AttemptId1,
        #gateway_response{gateway = twilio, gateway_id = ?SID1, status = sent}),
    %% Sleep for 1 seconds so the timestamp for Attempt1 and Attempt2 is different.
    timer:sleep(timer:seconds(1)),
    {ok, AttemptId2, _} = model_phone:add_sms_code2(?PHONE, ?CODE2),
    ok = model_phone:add_gateway_response(?PHONE, AttemptId2,
        #gateway_response{gateway = twilio, gateway_id = ?SID2, status = sent}),
    ?assertEqual(match, mod_sms:verify_sms(?PHONE, ?CODE1)),
    ?assertEqual(match, mod_sms:verify_sms(?PHONE, ?CODE1)),
    ?assertEqual(match, mod_sms:verify_sms(?PHONE, ?CODE2)),

    %% Invalidate old codes.
    ok = model_phone:invalidate_old_attempts(?PHONE),
    ?assertEqual(nomatch, mod_sms:verify_sms(?PHONE, ?CODE1)),
    ?assertEqual(nomatch, mod_sms:verify_sms(?PHONE, ?CODE2)),
    ok.

max_weight_selection_test() ->
    ?assertEqual(mbird, mod_sms:max_weight_selection(#{twilio => 0.2, mbird => 0.5, vonage => 0.3})),
    Picked = mod_sms:max_weight_selection(#{twilio => 0.2, mbird => 0.4, vonage => 0.4}),
    ?assert(Picked =:= mbird orelse Picked =:= vonage),
    ?assertEqual(twilio, mod_sms:max_weight_selection(#{twilio => 1})),
    ?assertEqual(undefined, mod_sms:max_weight_selection(#{})),
    ok.

% We call the rand_weighted selection 10 times, starting with 0.05 and adding 0.1 every time.catch
% Then we count how many times each gateway got picked, we expect the numbers to be the selection
% weights times 10.
rand_weighted_selection_test() ->
    M = #{twilio => 0.2, mbird => 0.5, vonage => 0.3},
    % generates [0.05, 0.15, ... 0.95] numbers so we can makes sure everything is picked
    % the expected number of times
    Points = [X/10 + 0.05 || X <- lists:seq(0, 9)],
    Picked = lists:map(
        fun (Point) ->
            mod_sms:rand_weighted_selection(Point, M)
        end, Points),
    Counters = lists:foldl(
        fun (Gateway, AccMap) ->
            maps:put(Gateway, maps:get(Gateway, AccMap, 0) + 1, AccMap)
        end, #{}, Picked),
    ?assertEqual(#{twilio => 2, mbird => 5, vonage => 3}, Counters),
    ok.


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

