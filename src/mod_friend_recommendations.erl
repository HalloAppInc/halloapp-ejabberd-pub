%%%-----------------------------------------------------------------------------------
%%% File    : mod_friend_recommendations.erl
%%%
%%% Copyright (C) 2022 halloappinc.
%%%-----------------------------------------------------------------------------------

-module(mod_friend_recommendations).
-author('vipin').

-export([
    generate/2
]).

-include("ha_types.hrl").

-spec generate(Uid :: uid(), Phone :: binary()) -> [{string(), integer(), binary(), binary(), integer()}].
generate(Uid, Phone) ->
    %% Get list of users that have Phone in their list of contacts.
    {ok, ReverseUids} = model_contacts:get_contact_uids(Phone),
    ReversePhones = model_accounts:get_phones(ReverseUids),

    %% Get Uid's list of contacts.
    {ok, ContactPhones} = model_contacts:get_contacts(Uid),

    %% Combined list of two represents potential list of friends.
    ContactPhones2 =
        sets:to_list(sets:union(sets:from_list(ContactPhones), sets:from_list(ReversePhones))),
    ContactPhones3 = [Phone2 || Phone2 <- ContactPhones2, Phone2 =/= undefined],
    PhoneToUidMap = model_phone:get_uids(ContactPhones3),
    ContactUids = maps:values(PhoneToUidMap),
    {ok, Friends} = model_friends:s(Uid),
    RealFriends = model_accounts:filter_nonexisting_uids(lists:delete(Uid, Friends)),

    %% Set of recommended friends.
    RecoUidsSet = sets:subtract(sets:from_list(ContactUids), sets:from_list(RealFriends)),

    %% Keep map from Phone to Uid only for recommended friends.
    PhoneToUidMap2 = maps:filter(
        fun(_K, V) ->
            sets:is_element(V, RecoUidsSet)
        end, PhoneToUidMap),

    UidToNameMap = model_accounts:get_names(maps:values(PhoneToUidMap2)),
    PhoneToNumFriendsMap = maps:fold(
        fun(K, V, Acc) ->
            {ok, Friends2} = model_friends:get_friends(V),
            RealFriends2 = model_accounts:filter_nonexisting_uids(lists:delete(V, Friends2)),
            maps:put(K, length(RealFriends2), Acc)
        end, #{}, PhoneToUidMap2),
    PhoneToNameMap = maps:map(fun(_P, U) -> maps:get(U, UidToNameMap) end, PhoneToUidMap2),
    ContactList = [{
        case maps:get(CPhone, PhoneToUidMap2, undefined) of      % Friend or Contact
            undefined -> "U";
            FUid ->
                case lists:member(FUid, RealFriends) of
                    true -> "F";
                    false ->
                        case lists:member(CPhone, ContactPhones) of
                            true -> "C";
                            false -> "R"
                        end
                end
        end,
        binary_to_integer(CPhone),                              % Phone,
        maps:get(CPhone, PhoneToUidMap, ""),                    % Uid,
        maps:get(CPhone, PhoneToNameMap, ""),                   % Name
        maps:get(CPhone, PhoneToNumFriendsMap, 0)               % Num Friends
    } || CPhone <- ContactPhones3],
    FriendsRecommendationList =
        [{CorF, P, _U, _N, _NF} || {CorF, P, _U, _N, _NF} <- ContactList,
            (CorF =:= "C" orelse CorF =:= "R")
            andalso not util:is_test_number(util:to_binary(P))
            andalso util:to_binary(P) =/= Phone], 
    {ok, FriendsRecommendationList}.


