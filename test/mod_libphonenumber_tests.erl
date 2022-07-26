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
    ?assertEqual(<<"BG">>, mod_libphonenumber:get_region_id(<<"+35943012345">>)),
    %% Turkey
    ?assertEqual(<<"TR">>, mod_libphonenumber:get_region_id(<<"+905012345678">>)),
    %% Svalbard (SJ) - region metadata is shared with the main country of Norway (NO)
    ?assertEqual(<<"NO">>, mod_libphonenumber:get_region_id(<<"+4741234567">>)),
    ok.


normalize_phone_country_code_test() ->
    setup(),

    %% US
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"+1-470-338-1473">>, ?REGION_US)),
    %% US
    ?assertEqual({ok, <<"16503878455">>}, mod_libphonenumber:normalize(<<"650 387 (8455)">>, ?REGION_US)),
    %% India
    ?assertEqual({ok, <<"919885577163">>}, mod_libphonenumber:normalize(<<"+919885577163">>, ?REGION_US)),
    %% UK
    ?assertEqual({ok, <<"447400123456">>}, mod_libphonenumber:normalize(<<"+447400123456">>, ?REGION_US)),
    %% Ireland
    ?assertEqual({ok, <<"353850123456">>}, mod_libphonenumber:normalize(<<"+353850123456">>, ?REGION_US)),
    %% Italy
    ?assertEqual({ok, <<"393123456789">>}, mod_libphonenumber:normalize(<<"+393123456789">>, ?REGION_US)),
    %% Japan
    ?assertEqual({ok, <<"819012345678">>}, mod_libphonenumber:normalize(<<"+819012345678">>, ?REGION_US)),
    %% Singapore
    ?assertEqual({ok, <<"6581234567">>}, mod_libphonenumber:normalize(<<"+6581234567">>, ?REGION_US)),
    %% Australia
    ?assertEqual({ok, <<"61412345678">>}, mod_libphonenumber:normalize(<<"+61412345678">>, ?REGION_US)),
    %% NewZealand
    ?assertEqual({ok, <<"64211234567">>}, mod_libphonenumber:normalize(<<"+64211234567">>, ?REGION_US)),
    %% Mexico
    ?assertEqual({ok, <<"522221234567">>}, mod_libphonenumber:normalize(<<"+5212221234567">>, ?REGION_US)),
    %% Canada
    ?assertEqual({ok, <<"15062345678">>}, mod_libphonenumber:normalize(<<"+15062345678">>, ?REGION_US)),
    %% Brazil
    ?assertEqual({ok, <<"5511961234567">>}, mod_libphonenumber:normalize(<<"+5511961234567">>, ?REGION_US)),
    %% Russia
    ?assertEqual({ok, <<"79123456789">>}, mod_libphonenumber:normalize(<<"+79123456789">>, ?REGION_US)),
    %% Bulgaria
    ?assertEqual({ok, <<"35943012345">>}, mod_libphonenumber:normalize(<<"+35943012345">>, ?REGION_US)),
    %% Turkey
    ?assertEqual({ok, <<"905012345678">>}, mod_libphonenumber:normalize(<<"+905012345678">>, ?REGION_US)),
    %% Philippines
    ?assertEqual({ok, <<"639912178825">>}, mod_libphonenumber:normalize(<<"+639912178825">>, ?REGION_US)),
    %% Invalid
    ?assertEqual({error, line_type_other}, mod_libphonenumber:normalize(<<"+91 415 412 1848">>, ?REGION_US)),
    %% Invalid
    ?assertEqual({error, too_short}, mod_libphonenumber:normalize(<<"123456">>, ?REGION_US)),
    %% Invalid
    ?assertEqual({error, line_type_other}, mod_libphonenumber:normalize(<<"1254154124">>, ?REGION_US)),
    ok.


normalize_phone_national_prefix_test() ->
    setup(),

    %% US
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"+1-1470-338-1473">>, ?REGION_US)),
    %% US
    ?assertEqual({ok, <<"16503878455">>}, mod_libphonenumber:normalize(<<"1650 387 (8455)">>, ?REGION_US)),
    %% India
    ?assertEqual({ok, <<"919885577163">>}, mod_libphonenumber:normalize(<<"+91-0-9885577163">>, ?REGION_US)),
    %% UK
    ?assertEqual({ok, <<"447400123456">>}, mod_libphonenumber:normalize(<<"+44-0-7400123456">>, ?REGION_US)),
    %% Ireland
    ?assertEqual({ok, <<"353850123456">>}, mod_libphonenumber:normalize(<<"+353-0-850123456">>, ?REGION_US)),
    %% Italy
    %% No National prefix.
    %% Japan
    ?assertEqual({ok, <<"819012345678">>}, mod_libphonenumber:normalize(<<"+81-0-9012345678">>, ?REGION_US)),
    %% Singapore
    %% No National prefix.
    %% Australia
    ?assertEqual({ok, <<"61412345678">>}, mod_libphonenumber:normalize(<<"+61-0-412345678">>, ?REGION_US)),
    %% NewZealand
    ?assertEqual({ok, <<"64211234567">>}, mod_libphonenumber:normalize(<<"+64-0-211234567">>, ?REGION_US)),
    %% Mexico
    ?assertEqual({ok, <<"522221234567">>}, mod_libphonenumber:normalize(<<"+52-01-2221234567">>, ?REGION_US)),
    %% Canada
    ?assertEqual({ok, <<"15062345678">>}, mod_libphonenumber:normalize(<<"+1-1-5062345678">>, ?REGION_US)),
    %% Brazil
    ?assertEqual({ok, <<"5511961234567">>}, mod_libphonenumber:normalize(<<"+55-0-11961234567">>, ?REGION_US)),
    %% Russia
    ?assertEqual({ok, <<"79123456789">>}, mod_libphonenumber:normalize(<<"+7-8-9123456789">>, ?REGION_US)),
    %% Bulgaria
    ?assertEqual({ok, <<"35943012345">>}, mod_libphonenumber:normalize(<<"+359-0-43012345">>, ?REGION_US)),
    %% Turkey
    ?assertEqual({ok, <<"905012345678">>}, mod_libphonenumber:normalize(<<"+90-0-5012345678">>, ?REGION_US)),
    %% Philippines
    ?assertEqual({ok, <<"639912178825">>}, mod_libphonenumber:normalize(<<"+63-0-9912178825">>, ?REGION_US)),
    %% Invalid
    ?assertEqual({error, line_type_other}, mod_libphonenumber:normalize(<<"+91 415 412 1848">>, ?REGION_US)),
    %% Invalid
    ?assertEqual({error, too_short}, mod_libphonenumber:normalize(<<"123456">>, ?REGION_US)),
    %% Invalid
    ?assertEqual({error, line_type_other}, mod_libphonenumber:normalize(<<"1254154124">>, ?REGION_US)),
    ok.


normalize_without_phone_country_code_test() ->
    setup(),

    %% US
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"4703381473">>, <<"US">>)),
    %% India
    ?assertEqual({ok, <<"919885577163">>}, mod_libphonenumber:normalize(<<"9885577163">>, <<"IN">>)),
    %% UK
    ?assertEqual({ok, <<"447400123456">>}, mod_libphonenumber:normalize(<<"7400123456">>, <<"GB">>)),
    %% Ireland
    ?assertEqual({ok, <<"353850123456">>}, mod_libphonenumber:normalize(<<"850123456">>, <<"IE">>)),
    %% Italy
    ?assertEqual({ok, <<"393123456789">>}, mod_libphonenumber:normalize(<<"3123456789">>, <<"IT">>)),
    %% Japan
    ?assertEqual({ok, <<"819012345678">>}, mod_libphonenumber:normalize(<<"9012345678">>, <<"JP">>)),
    %% Singapore
    ?assertEqual({ok, <<"6581234567">>}, mod_libphonenumber:normalize(<<"81234567">>, <<"SG">>)),
    %% Australia
    ?assertEqual({ok, <<"61412345678">>}, mod_libphonenumber:normalize(<<"61412345678">>, <<"AU">>)),
    %% NewZealand
    ?assertEqual({ok, <<"64211234567">>}, mod_libphonenumber:normalize(<<"211234567">>, <<"NZ">>)),
    %% Mexico
    ?assertEqual({ok, <<"522221234567">>}, mod_libphonenumber:normalize(<<"2221234567">>, <<"MX">>)),
    %% Canada
    ?assertEqual({ok, <<"15062345678">>}, mod_libphonenumber:normalize(<<"5062345678">>, <<"CA">>)),
    %% Brazil
    ?assertEqual({ok, <<"5511961234567">>}, mod_libphonenumber:normalize(<<"11961234567">>, <<"BR">>)),
    %% Russia
    ?assertEqual({ok, <<"79123456789">>}, mod_libphonenumber:normalize(<<"9123456789">>, <<"RU">>)),
    %% Bulgaria
    ?assertEqual({ok, <<"35943012345">>}, mod_libphonenumber:normalize(<<"43012345">>, <<"BG">>)),
    %% Turkey
    ?assertEqual({ok, <<"905012345678">>}, mod_libphonenumber:normalize(<<"5012345678">>, <<"TR">>)),
    %% Philippines
    ?assertEqual({ok, <<"639912178825">>}, mod_libphonenumber:normalize(<<"9912178825">>, <<"PH">>)),
    ok.


normalize_phone_international_code_test() ->
    setup(),

    %% InternationalPrefix: US
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"01114703381473">>, <<"US">>)),
    %% US
    ?assertEqual({ok, <<"919885577163">>}, mod_libphonenumber:normalize(<<"011919885577163">>, <<"US">>)),
    %% India
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"0014703381473">>, <<"IN">>)),
    %% UK
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"0014703381473">>, <<"GB">>)),
    %% Italy
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"0014703381473">>, <<"IT">>)),
    %% Japan
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"01014703381473">>, <<"JP">>)),
    %% Singapore
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"02314703381473">>, <<"SG">>)),
    %% Australia
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"001114703381473">>, <<"AU">>)),
    %% NewZealand
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"016114703381473">>, <<"NZ">>)),
    %% Mexico
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"0914703381473">>, <<"MX">>)),
    %% Canada
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"01114703381473">>, <<"CA">>)),
    %% Brazil
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"005514703381473">>, <<"BR">>)),
    %% Russia
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"81014703381473">>, <<"RU">>)),
    %% Bulgaria
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"0014703381473">>, <<"BG">>)),
    %% Turkey
    ?assertEqual({ok, <<"14703381473">>}, mod_libphonenumber:normalize(<<"0014703381473">>, <<"TK">>)),
    %% Philippines
    ?assertEqual({ok, <<"639912178825">>}, mod_libphonenumber:normalize(<<"00639912178825">>, <<"PH">>)),
    ok.


get_555_number_region_test() ->
    setup(),

    ?assertEqual(<<"US">>, mod_libphonenumber:get_region_id(<<"18885552222">>)),
    ?assertEqual(<<"US">>, mod_libphonenumber:get_region_id(<<"14705551473">>)),
    ok.


normalize_argentina_test() ->
    setup(),

    %% Argentina - with country code.
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"+5491123456789">>, <<"AR">>)),
    %% Argentina - with country code.
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"5491123456789">>, <<"AR">>)),
    %% Argentina - with country code.
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"+541123456789">>, <<"AR">>)),
    %% Argentina - with country code.
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"541123456789">>, <<"AR">>)),
    %% Argentina
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"91123456789">>, <<"AR">>)),
    %% Argentina
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"1123456789">>, <<"AR">>)),

    %% Numbers with country code and with/without 9 should still normalize fine from other places.
    %% Argentina - with country code.
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"+5491123456789">>, <<"US">>)),
    %% Argentina - with country code.
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"+541123456789">>, <<"US">>)),
    %% Argentina - with country code.
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"+5491123456789">>, <<"IN">>)),
    %% Argentina - with country code.
    ?assertEqual({ok, <<"5491123456789">>}, mod_libphonenumber:normalize(<<"+541123456789">>, <<"IN">>)),
    ok.


normalize_mexico_test() ->
    setup(),

    %% Mexico - with country code.
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"+5216182602005">>, <<"MX">>)),
    %% Mexico - with country code.
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"5216182602005">>, <<"MX">>)),
    %% Mexico - with country code.
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"+526182602005">>, <<"MX">>)),
    %% Mexico - with country code.
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"5216182602005">>, <<"MX">>)),
    %% Mexico
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"16182602005">>, <<"MX">>)),
    %% Mexico
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"6182602005">>, <<"MX">>)),

    %% Numbers with country code and with/without 1 should still normalize fine from other places.
    %% Mexico - with country code.
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"+5216182602005">>, <<"US">>)),
    %% Mexico - with country code.
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"+5216182602005">>, <<"US">>)),
    %% Mexico - with country code.
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"+526182602005">>, <<"IN">>)),
    %% Mexico - with country code.
    ?assertEqual({ok, <<"526182602005">>}, mod_libphonenumber:normalize(<<"+526182602005">>, <<"IN">>)),
    ok.


normalize_error_test() ->
    setup(),
    % voip number (pulled from xml file)
    {ok, PhoneNumberState} = phone_number_util:parse_phone_number(<<"354 4921234">>, <<"IS">>),
    ?assertEqual(line_type_voip, PhoneNumberState#phone_number_state.error_msg ),
    % fixed line number (pulled from xml file)
    {ok, PhoneNumberState2} = phone_number_util:parse_phone_number(<<"4101234">>, <<"IS">>),
    ?assertEqual(line_type_fixed, PhoneNumberState2#phone_number_state.error_msg ),
    % pager number (pulled from xml file)
    {ok, PhoneNumberState3} = phone_number_util:parse_phone_number(<<"740123456">>, <<"CH">>),
    ?assertEqual(line_type_other, PhoneNumberState3#phone_number_state.error_msg ),
    % match last error if multiple regions (number matches VA and IT region)
    {ok, PhoneNumberState4} = phone_number_util:parse_phone_number(<<"395512345678">>, <<"IT">>),
    ?assertEqual(line_type_voip, PhoneNumberState4#phone_number_state.error_msg ),
    % invalid lengths - long & short
    {ok, PhoneNumberState5} = phone_number_util:parse_phone_number(<<"1111111111">>, <<"IS">>),
    ?assertEqual(too_long, PhoneNumberState5#phone_number_state.error_msg ),
    {ok, PhoneNumberState6} = phone_number_util:parse_phone_number(<<"11">>, <<"IS">>),
    ?assertEqual(too_short, PhoneNumberState6#phone_number_state.error_msg ),
    % invalid length - 001 is a region with no mobile desc
    {ok, PhoneNumberState7} = phone_number_util:parse_phone_number(<<"1111111">>, <<"001">>),
    ?assertEqual(invalid_length, PhoneNumberState7#phone_number_state.error_msg),
    ok.


normalized_number_test() ->
    setup(),
    ?assertEqual(undefined, mod_libphonenumber:normalized_number(<<"+91 415 412 1848">>, <<"US">>)),
    ?assertEqual(undefined, mod_libphonenumber:normalized_number(<<"123456">>, <<"US">>)),
    ?assertEqual(<<"12015550123">>, mod_libphonenumber:normalized_number(<<"2015550123">>, <<"US">>)),
    ?assertEqual(<<"526182602005">>, mod_libphonenumber:normalized_number(<<"+5216182602005">>, <<"US">>)),
    ok.

