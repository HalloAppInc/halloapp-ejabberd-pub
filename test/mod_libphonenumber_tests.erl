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

-define(REGION_US, <<"US">>).


setup() ->
    mod_libphonenumber:start(<<>>, <<>>),
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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
    %% Invalid
    ?assertEqual(undefined, mod_libphonenumber:normalize(<<"+91 415 412 1848">>, ?REGION_US)),
    %% Invalid
    ?assertEqual(undefined, mod_libphonenumber:normalize(<<"123456">>, ?REGION_US)),
    %% Invalid
    ?assertEqual(undefined, mod_libphonenumber:normalize(<<"1254154124">>, ?REGION_US)),
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
    ok.


