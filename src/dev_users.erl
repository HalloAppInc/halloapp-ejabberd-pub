%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Aug 2020 8:54 PM
%%%-------------------------------------------------------------------
-module(dev_users).
-author("josh").

-include("ha_types.hrl").

-define(NOISE_CHECKER_PHONE, <<"16175552222">>).

%% API
-export([
    get_katchup_ambassador_phones/0,
    get_dev_uids/0,
    get_dev_phones/0,
    show_on_public_feed/1,
    is_katchup_ambassador_phone/1,
    is_dev_uid/1,
    is_murali/1,
    is_psa_admin/1
]).

%%====================================================================
%% API
%%====================================================================

-spec get_katchup_ambassador_phones() -> [phone()].
get_katchup_ambassador_phones() ->
    [
        <<"918766261787">>,  %% Jhanvee (ashoka)
        <<"917508360359">>   %% Saher (ashoka)
    ].


-spec get_dev_uids() -> [uid()].
get_dev_uids() ->
    [
        %%%%%%%%%%%%%%%% employees %%%%%%%%%%%%%%%%
        <<"1000000000557110158">>,  %% Chris
        <<"1001000000894131468">>,
        <<"1000000000349709227">>,  %% Garrett
        <<"1001000000677582000">>,
        <<"1000000000185937915">>,  %% Jack
        <<"1001000000422466935">>,
        <<"1000000000045484920">>,  %% Michael
        <<"1001000000911343310">>,
        <<"1000000000893731049">>,  %% Michael test phone
        <<"1001000000358497701">>,
        <<"1000000000739856658">>,  %% Murali
        <<"1001000000447424843">>,
        <<"1000000000773653288">>,  %% Murali test phone
        <<"1001000000988079030">>,
        <<"1000000000212763494">>,  %% Murali test phone2
        <<"1001000000235714298">>,  %% Murali iphone2
        <<"1000000000332736727">>,  %% Neeraj
        <<"1001000000310131738">>,
        <<"1000000000954838380">>,  %% Neeraj test phone
        <<"1000000000244183554">>,  %% Nandini
        <<"1001000000909851281">>,
        <<"1000000000009202844">>,  %% Nandini test phone
        <<"1001000000442193020">>,
        <<"1000000000773991293">>,  %% Nandini test phone-2
        <<"1000000000619182623">>,  %% Alisa
        <<"1001000000929171042">>,
        <<"1000000000709916195">>,  %% Alisa android
        <<"1001000000206916140">>,
        <<"1000000000018120857">>,  %% Catrina
        <<"1001000000777872208">>,
        <<"1000000000000561792">>,  %% Tanveer
        <<"1001000000267927389">>,
        <<"1000000000949268264">>,  %% Tanveer test phone
        <<"1001000000077584648">>,
        <<"1000000000386040322">>,  %% Josh
        <<"1001000000376906648">>,
        %%%%%%%%%%%%%%%%% interns %%%%%%%%%%%%%%%%%%%%
        %%%%%%%%%%%%%%%% contractors %%%%%%%%%%%%%%%%%
        <<"1000000000877204287">>,  %% Vasil
        <<"1000000000961054658">>,  %% Vasil test ios
        <<"1000000000186868017">>,  %% Stefan
        <<"1000000000995388494">>   %% Yelena - translator
    ].


-spec get_dev_phones() -> [phone()].
get_dev_phones() ->
    [
        <<"16503916245">>,   %% Alisa
        <<"13472558058">>,   %% Michelle
        <<"16505125376">>,   %% Josh test phone
        <<"17143529211">>,   %% Kayla
        <<"16503530067">>,   %% Nandini android
        <<"16504508196">>,   %% Neeraj test phone
        <<"359884199917">>,  %% Vasil
        <<"359877713791">>,  %% Vasil iOS
        <<"359888257524">>,  %% Stefan
        <<"359885314177">>,  %% Stefan iOS
        <<"16504173810">>    %% Tanveer
    ].


-spec get_public_feed_blocked_phones_list() -> [uid()].
get_public_feed_blocked_phones_list() ->
    [
        <<"16504992804">>,  %% Google tester
        <<"16503874384">>   %% Jack test phone
    ].


is_katchup_ambassador_phone(Phone) ->
    lists:member(Phone, get_katchup_ambassador_phones()).


-spec is_dev_uid(Uid :: uid()) -> boolean().
is_dev_uid(Uid) ->
    IsUIDDev = lists:member(Uid, get_dev_uids()),
    case model_accounts:get_phone(Uid) of
        {error, missing} ->
            IsUIDDev;
        {ok, ?NOISE_CHECKER_PHONE} ->
            false;
        {ok, Phone} ->
            util:is_test_number(Phone) orelse IsUIDDev orelse lists:member(Phone, get_dev_phones())
    end.


-spec show_on_public_feed(Uid :: uid()) -> boolean().
show_on_public_feed(Uid) ->
    case model_accounts:get_phone(Uid) of
        {error, missing} ->
            false;
        {ok, Phone} ->
            IsDevUid = lists:member(Uid, get_dev_uids()),
            IsDevPhone = lists:member(Phone, get_dev_phones()),
            IsTestPhone = util:is_test_number(Phone),
            IsBlockedPhone = lists:member(Phone, get_public_feed_blocked_phones_list()),
            IsAllowedOnPublicFeed = lists:member(Uid, get_katchup_public_feed_allowed_uids()),

            IsAllowedOnPublicFeed orelse not (IsBlockedPhone orelse IsTestPhone orelse IsDevPhone orelse IsDevUid)
    end .


get_katchup_public_feed_allowed_uids() ->
    [
        <<"1001000000929171042">>  %% Alisa
    ].


is_murali(<<"1000000000739856658">>) -> true;  %% Murali
is_murali(<<"1000000000773653288">>) -> true;  %% Murali android
is_murali(<<"1000000000212763494">>) -> true;  %% Murali Iphone
is_murali(<<"1000000000490675850">>) -> true;  %% Murali Iphone2
is_murali(_) -> false.

is_psa_admin(<<"1000000000893731049">>) -> true;  %% Michael test phone
is_psa_admin(<<"1000000000162508063">>) -> true;  %% Neeraj test phone
is_psa_admin(_) -> false.

