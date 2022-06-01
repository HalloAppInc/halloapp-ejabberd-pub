%%%-------------------------------------------------------------------
%%% File: mod_libphonenumber_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_libphonenumber_tests).
-author('murali').

-include("xmpp.hrl").
-include("feed.hrl").

-include_lib("eunit/include/eunit.hrl").

-include("phone_number.hrl").

-define(REGION_US, <<"US">>).


setup() ->
    mod_libphonenumber:start(<<>>, <<>>),
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% tests that a + is put in front of phone numbers, if needed
prepend_plus_test() ->
    Number = <<"359 (88) 558 6764">>,
    NumberWithPlus = <<"+359 (88) 558 6764">>,
    ?assertEqual(NumberWithPlus, mod_libphonenumber:prepend_plus(Number)),
    ?assertEqual(NumberWithPlus, mod_libphonenumber:prepend_plus(NumberWithPlus)).


%% TODO(murali@): update these unit tests after we return e164 format number.

get_region_test() ->
    setup(),

    %% US
    ?assertEqual(<<"US">>, mod_libphonenumber:get_region_id(<<"+14703381473">>)),
    %% India
    ?assertEqual(<<"IN">>, mod_libphonenumber:get_region_id(<<"+919885577163">>)),
    %% UK
    ?assertEqual(<<"GB">>, mod_libphonenumber:get_region_id(<<"+447400123456">>)),
    %% Ireland
    ?assertEqual(<<"IE">>, mod_libphonenumber:get_region_id(<<"+353850123456">>)),
    %% Italy
    ?assertEqual(<<"IT">>, mod_libphonenumber:get_region_id(<<"+393123456789">>)),
    %% Japan
    ?assertEqual(<<"JP">>, mod_libphonenumber:get_region_id(<<"+819012345678">>)),
    %% Singapore
    ?assertEqual(<<"SG">>, mod_libphonenumber:get_region_id(<<"+6581234567">>)),
    %% Australia
    ?assertEqual(<<"AU">>, mod_libphonenumber:get_region_id(<<"+61412345678">>)),
    %% NewZealand
    ?assertEqual(<<"NZ">>, mod_libphonenumber:get_region_id(<<"+64211234567">>)),
    %% Mexico
    ?assertEqual(<<"MX">>, mod_libphonenumber:get_region_id(<<"+5212221234567">>)),
    %% Canada
    ?assertEqual(<<"CA">>, mod_libphonenumber:get_region_id(<<"+15062345678">>)),
    %% Brazil
    ?assertEqual(<<"BR">>, mod_libphonenumber:get_region_id(<<"+5511961234567">>)),
    %% Russia
    ?assertEqual(<<"RU">>, mod_libphonenumber:get_region_id(<<"+79123456789">>)),
    %% Bulgaria
    ?assertEqual(<<"BG">>, mod_libphonenumber:get_region_id(<<"+35948123456">>)),
    %% Turkey
    ?assertEqual(<<"TR">>, mod_libphonenumber:get_region_id(<<"+905012345678">>)),
    ok.


normalize_phone_country_code_test() ->
    setup(),

    %% US
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"+1-470-338-1473">>, ?REGION_US)),
    %% US
    ?assertEqual(<<"16503878455">>, mod_libphonenumber:normalize(<<"650 387 (8455)">>, ?REGION_US)),
    %% India
    ?assertEqual(<<"919885577163">>, mod_libphonenumber:normalize(<<"+919885577163">>, ?REGION_US)),
    %% UK
    ?assertEqual(<<"447400123456">>, mod_libphonenumber:normalize(<<"+447400123456">>, ?REGION_US)),
    %% Ireland
    ?assertEqual(<<"353850123456">>, mod_libphonenumber:normalize(<<"+353850123456">>, ?REGION_US)),
    %% Italy
    ?assertEqual(<<"393123456789">>, mod_libphonenumber:normalize(<<"+393123456789">>, ?REGION_US)),
    %% Japan
    ?assertEqual(<<"819012345678">>, mod_libphonenumber:normalize(<<"+819012345678">>, ?REGION_US)),
    %% Singapore
    ?assertEqual(<<"6581234567">>, mod_libphonenumber:normalize(<<"+6581234567">>, ?REGION_US)),
    %% Australia
    ?assertEqual(<<"61412345678">>, mod_libphonenumber:normalize(<<"+61412345678">>, ?REGION_US)),
    %% NewZealand
    ?assertEqual(<<"64211234567">>, mod_libphonenumber:normalize(<<"+64211234567">>, ?REGION_US)),
    %% Mexico
    ?assertEqual(<<"522221234567">>, mod_libphonenumber:normalize(<<"+5212221234567">>, ?REGION_US)),
    %% Canada
    ?assertEqual(<<"15062345678">>, mod_libphonenumber:normalize(<<"+15062345678">>, ?REGION_US)),
    %% Brazil
    ?assertEqual(<<"5511961234567">>, mod_libphonenumber:normalize(<<"+5511961234567">>, ?REGION_US)),
    %% Russia
    ?assertEqual(<<"79123456789">>, mod_libphonenumber:normalize(<<"+79123456789">>, ?REGION_US)),
    %% Bulgaria
    ?assertEqual(<<"35948123456">>, mod_libphonenumber:normalize(<<"+35948123456">>, ?REGION_US)),
    %% Turkey
    ?assertEqual(<<"905012345678">>, mod_libphonenumber:normalize(<<"+905012345678">>, ?REGION_US)),
    %% Philippines
    ?assertEqual(<<"639912178825">>, mod_libphonenumber:normalize(<<"+639912178825">>, ?REGION_US)),
    %% Invalid
    ?assertEqual(undefined, mod_libphonenumber:normalize(<<"+91 415 412 1848">>, ?REGION_US)),
    %% Invalid
    ?assertEqual(undefined, mod_libphonenumber:normalize(<<"123456">>, ?REGION_US)),
    %% Invalid
    ?assertEqual(undefined, mod_libphonenumber:normalize(<<"1254154124">>, ?REGION_US)),
    ok.


normalize_phone_national_prefix_test() ->
    setup(),

    %% US
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"+1-1470-338-1473">>, ?REGION_US)),
    %% US
    ?assertEqual(<<"16503878455">>, mod_libphonenumber:normalize(<<"1650 387 (8455)">>, ?REGION_US)),
    %% India
    ?assertEqual(<<"919885577163">>, mod_libphonenumber:normalize(<<"+91-0-9885577163">>, ?REGION_US)),
    %% UK
    ?assertEqual(<<"447400123456">>, mod_libphonenumber:normalize(<<"+44-0-7400123456">>, ?REGION_US)),
    %% Ireland
    ?assertEqual(<<"353850123456">>, mod_libphonenumber:normalize(<<"+353-0-850123456">>, ?REGION_US)),
    %% Italy
    %% No National prefix.
    %% Japan
    ?assertEqual(<<"819012345678">>, mod_libphonenumber:normalize(<<"+81-0-9012345678">>, ?REGION_US)),
    %% Singapore
    %% No National prefix.
    %% Australia
    ?assertEqual(<<"61412345678">>, mod_libphonenumber:normalize(<<"+61-0-412345678">>, ?REGION_US)),
    %% NewZealand
    ?assertEqual(<<"64211234567">>, mod_libphonenumber:normalize(<<"+64-0-211234567">>, ?REGION_US)),
    %% Mexico
    ?assertEqual(<<"522221234567">>, mod_libphonenumber:normalize(<<"+52-01-2221234567">>, ?REGION_US)),
    %% Canada
    ?assertEqual(<<"15062345678">>, mod_libphonenumber:normalize(<<"+1-1-5062345678">>, ?REGION_US)),
    %% Brazil
    ?assertEqual(<<"5511961234567">>, mod_libphonenumber:normalize(<<"+55-0-11961234567">>, ?REGION_US)),
    %% Russia
    ?assertEqual(<<"79123456789">>, mod_libphonenumber:normalize(<<"+7-8-9123456789">>, ?REGION_US)),
    %% Bulgaria
    ?assertEqual(<<"35948123456">>, mod_libphonenumber:normalize(<<"+359-0-48123456">>, ?REGION_US)),
    %% Turkey
    ?assertEqual(<<"905012345678">>, mod_libphonenumber:normalize(<<"+90-0-5012345678">>, ?REGION_US)),
    %% Philippines
    ?assertEqual(<<"639912178825">>, mod_libphonenumber:normalize(<<"+63-0-9912178825">>, ?REGION_US)),
    %% Invalid
    ?assertEqual(undefined, mod_libphonenumber:normalize(<<"+91 415 412 1848">>, ?REGION_US)),
    %% Invalid
    ?assertEqual(undefined, mod_libphonenumber:normalize(<<"123456">>, ?REGION_US)),
    %% Invalid
    ?assertEqual(undefined, mod_libphonenumber:normalize(<<"1254154124">>, ?REGION_US)),
    ok.


normalize_without_phone_country_code_test() ->
    setup(),

    %% US
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"4703381473">>, <<"US">>)),
    %% India
    ?assertEqual(<<"919885577163">>, mod_libphonenumber:normalize(<<"9885577163">>, <<"IN">>)),
    %% UK
    ?assertEqual(<<"447400123456">>, mod_libphonenumber:normalize(<<"7400123456">>, <<"GB">>)),
    %% Ireland
    ?assertEqual(<<"353850123456">>, mod_libphonenumber:normalize(<<"850123456">>, <<"IE">>)),
    %% Italy
    ?assertEqual(<<"393123456789">>, mod_libphonenumber:normalize(<<"3123456789">>, <<"IT">>)),
    %% Japan
    ?assertEqual(<<"819012345678">>, mod_libphonenumber:normalize(<<"9012345678">>, <<"JP">>)),
    %% Singapore
    ?assertEqual(<<"6581234567">>, mod_libphonenumber:normalize(<<"81234567">>, <<"SG">>)),
    %% Australia
    ?assertEqual(<<"61412345678">>, mod_libphonenumber:normalize(<<"61412345678">>, <<"AU">>)),
    %% NewZealand
    ?assertEqual(<<"64211234567">>, mod_libphonenumber:normalize(<<"211234567">>, <<"NZ">>)),
    %% Mexico
    ?assertEqual(<<"522221234567">>, mod_libphonenumber:normalize(<<"2221234567">>, <<"MX">>)),
    %% Canada
    ?assertEqual(<<"15062345678">>, mod_libphonenumber:normalize(<<"5062345678">>, <<"CA">>)),
    %% Brazil
    ?assertEqual(<<"5511961234567">>, mod_libphonenumber:normalize(<<"11961234567">>, <<"BR">>)),
    %% Russia
    ?assertEqual(<<"79123456789">>, mod_libphonenumber:normalize(<<"9123456789">>, <<"RU">>)),
    %% Bulgaria
    ?assertEqual(<<"35948123456">>, mod_libphonenumber:normalize(<<"48123456">>, <<"BG">>)),
    %% Turkey
    ?assertEqual(<<"905012345678">>, mod_libphonenumber:normalize(<<"5012345678">>, <<"TR">>)),
    %% Philippines
    ?assertEqual(<<"639912178825">>, mod_libphonenumber:normalize(<<"9912178825">>, <<"PH">>)),
    ok.


normalize_phone_international_code_test() ->
    setup(),

    %% InternationalPrefix: US
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"01114703381473">>, <<"US">>)),
    %% US
    ?assertEqual(<<"919885577163">>, mod_libphonenumber:normalize(<<"011919885577163">>, <<"US">>)),
    %% India
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"0014703381473">>, <<"IN">>)),
    %% UK
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"0014703381473">>, <<"GB">>)),
    %% Italy
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"0014703381473">>, <<"IT">>)),
    %% Japan
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"01014703381473">>, <<"JP">>)),
    %% Singapore
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"02314703381473">>, <<"SG">>)),
    %% Australia
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"001114703381473">>, <<"AU">>)),
    %% NewZealand
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"016114703381473">>, <<"NZ">>)),
    %% Mexico
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"0914703381473">>, <<"MX">>)),
    %% Canada
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"01114703381473">>, <<"CA">>)),
    %% Brazil
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"005514703381473">>, <<"BR">>)),
    %% Russia
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"81014703381473">>, <<"RU">>)),
    %% Bulgaria
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"0014703381473">>, <<"BG">>)),
    %% Turkey
    ?assertEqual(<<"14703381473">>, mod_libphonenumber:normalize(<<"0014703381473">>, <<"TK">>)),
    %% Philippines
    ?assertEqual(<<"639912178825">>, mod_libphonenumber:normalize(<<"00639912178825">>, <<"PH">>)),
    ok.


get_555_number_region_test() ->
    setup(),

    ?assertEqual(<<"US">>, mod_libphonenumber:get_region_id(<<"18885552222">>)),
    ?assertEqual(<<"US">>, mod_libphonenumber:get_region_id(<<"14705551473">>)),
    ok.


normalize_argentina_test() ->
    setup(),

    %% Argentina - with country code.
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"+5491123456789">>, <<"AR">>)),
    %% Argentina - with country code.
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"5491123456789">>, <<"AR">>)),
    %% Argentina - with country code.
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"+541123456789">>, <<"AR">>)),
    %% Argentina - with country code.
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"541123456789">>, <<"AR">>)),
    %% Argentina
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"91123456789">>, <<"AR">>)),
    %% Argentina
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"1123456789">>, <<"AR">>)),

    %% Numbers with country code and with/without 9 should still normalize fine from other places.
    %% Argentina - with country code.
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"+5491123456789">>, <<"US">>)),
    %% Argentina - with country code.
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"+541123456789">>, <<"US">>)),
    %% Argentina - with country code.
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"+5491123456789">>, <<"IN">>)),
    %% Argentina - with country code.
    ?assertEqual(<<"5491123456789">>, mod_libphonenumber:normalize(<<"+541123456789">>, <<"IN">>)),
    ok.


normalize_mexico_test() ->
    setup(),

    %% Mexico - with country code.
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"+5216182602005">>, <<"MX">>)),
    %% Mexico - with country code.
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"5216182602005">>, <<"MX">>)),
    %% Mexico - with country code.
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"+526182602005">>, <<"MX">>)),
    %% Mexico - with country code.
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"5216182602005">>, <<"MX">>)),
    %% Mexico
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"16182602005">>, <<"MX">>)),
    %% Mexico
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"6182602005">>, <<"MX">>)),

    %% Numbers with country code and with/without 1 should still normalize fine from other places.
    %% Mexico - with country code.
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"+5216182602005">>, <<"US">>)),
    %% Mexico - with country code.
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"+5216182602005">>, <<"US">>)),
    %% Mexico - with country code.
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"+526182602005">>, <<"IN">>)),
    %% Mexico - with country code.
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalize(<<"+526182602005">>, <<"IN">>)),
    ok.


normalize_error_test() ->
    setup(),
    % voip number (pulled from xml file)
    {ok, PhoneNumberState} = phone_number_util:parse_phone_number(<<"354 4921234">>, <<"IS">>),
    ?assertEqual(not_mobile_num, PhoneNumberState#phone_number_state.error_msg ),
    % fixed line number (pulled from xml file)
    {ok, PhoneNumberState2} = phone_number_util:parse_phone_number(<<"4101234">>, <<"IS">>),
     ?assertEqual(not_mobile_num, PhoneNumberState2#phone_number_state.error_msg ),
    % no valid region
    {ok, PhoneNumberState3} = phone_number_util:parse_phone_number(<<"395512345678">>, <<"IT">>),
    ?assertEqual(no_valid_region, PhoneNumberState3#phone_number_state.error_msg ),
    % invalid lengths - long & short
    {ok, PhoneNumberState4} = phone_number_util:parse_phone_number(<<"1111111111">>, <<"IS">>),
     ?assertEqual(too_long, PhoneNumberState4#phone_number_state.error_msg ),
    {ok, PhoneNumberState5} = phone_number_util:parse_phone_number(<<"11">>, <<"IS">>),
    ?assertEqual(too_short, PhoneNumberState5#phone_number_state.error_msg ),
    % invalid length - 001 is a region with no mobile desc
    {ok, PhoneNumberState6} = phone_number_util:parse_phone_number(<<"1111111">>, <<"001">>),
    ?assertEqual(invalid_length, PhoneNumberState6#phone_number_state.error_msg),
    ok.

