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
    is_dev_uid/1
]).

%%====================================================================
%% API
%%====================================================================

-spec get_dev_uids() -> [uid()].
get_dev_uids() ->
    [
        <<"1000000000159020147">>,  %% Clark
        <<"1000000000519345762">>,  %% Duygu
        <<"1000000000042689058">>,  %% Duygu test phone
        <<"1000000000349709227">>,  %% Garrett
        <<"1000000000749685963">>,  %% Igor
        <<"1000000000969121797">>,  %% Igor test phone
        <<"1000000000185937915">>,  %% Jack
        <<"1000000000779698879">>,  %% Jack test phone
        <<"1000000000386040322">>,  %% Josh
        <<"1000000000045484920">>,  %% Michael
        <<"1000000000893731049">>,  %% Michael test phone
        <<"1000000000739856658">>,  %% Murali
        <<"1000000000773653288">>,  %% Murali test phone
        <<"1000000000332736727">>,  %% Neeraj
        <<"1000000000162508063">>,  %% Neeraj test phone
        <<"1000000000379188160">>,  %% Nikola
        <<"1000000000118189365">>,  %% Pooja
        <<"1000000000477041210">>,  %% Tony
        <<"1000000000648327036">>,  %% Vipin
        <<"1000000000206299818">>,  %% Vipin test phone
        <<"1000000000561642370">>   %% Yuchao
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

