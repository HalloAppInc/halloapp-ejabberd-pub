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

%% API
-export([
    get_dev_uids/0,
    is_dev_uid/1,
    is_murali/1
]).

%%====================================================================
%% API
%%====================================================================

-spec get_dev_uids() -> [uid()].
get_dev_uids() ->
    [
        %%%%%%%%%%%%%%%% employees %%%%%%%%%%%%%%%%
        <<"1000000000159020147">>,  %% Clark
        <<"1000000000519345762">>,  %% Duygu
        <<"1000000000042689058">>,  %% Duygu test phone
        <<"1000000000349709227">>,  %% Garrett
        <<"1000000000185937915">>,  %% Jack
        <<"1000000000779698879">>,  %% Jack test phone
        <<"1000000000045484920">>,  %% Michael
        <<"1000000000893731049">>,  %% Michael test phone
        <<"1000000000739856658">>,  %% Murali
        <<"1000000000773653288">>,  %% Murali test phone
        <<"1000000000291212306">>,  %% Murali test phone2
        <<"1000000000332736727">>,  %% Neeraj
        <<"1000000000162508063">>,  %% Neeraj test phone
        <<"1000000000379188160">>,  %% Nikola
        <<"1000000000118189365">>,  %% Pooja
        <<"1000000000477041210">>,  %% Tony
        <<"1000000000648327036">>,  %% Vipin
        <<"1000000000244183554">>,  %% Nandini
        <<"1000000000009202844">>,  %% Nandini test phone
        <<"1000000000619182623">>,  %% Alisa
        %%%%%%%%%%%%%%%% contractors %%%%%%%%%%%%%%%%%
        <<"1000000000877204287">>,  %% Vasil
        <<"1000000000186868017">>,  %% Stefan
        <<"1000000000121562547">>,  %% Stefan test phone
        <<"1000000000794464373">>   %% Sandra Kremmeicke - german translator
    ].


-spec is_dev_uid(Uid :: uid()) -> boolean().
is_dev_uid(Uid) ->
    IsUIDDev = lists:member(Uid, get_dev_uids()),
    case model_accounts:get_phone(Uid) of
        {error, missing} ->
            IsUIDDev;
        {ok, Phone} ->
            util:is_test_number(Phone) orelse IsUIDDev
    end.

is_murali(<<"1000000000739856658">>) -> true;  %% Murali
is_murali(<<"1000000000773653288">>) -> true;  %% Murali android
is_murali(<<"1000000000291212306">>) -> true;  %% Murali Iphone
is_murali(_) -> false.


