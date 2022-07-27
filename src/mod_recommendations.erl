%%%-----------------------------------------------------------------------------------
%%% File    : mod_friend_recommendations.erl
%%%
%%% Copyright (C) 2022 halloappinc.
%%%-----------------------------------------------------------------------------------

-module(mod_recommendations).
-author('vipin').

-include("logger.hrl").
-include("ha_types.hrl").
-include("athena_query.hrl").
-include("account.hrl").

-export([
    generate_friend_recos/3,
    invite_recos/2,
    process_invite_recos/1,
    generate_invite_recos/2
]).


-spec generate_friend_recos(Uid :: uid(), Phone :: binary(), NumCommunityRecos :: non_neg_integer()) -> 
        {ok, [{string(), integer(), binary(), binary(), integer()}]}.
generate_friend_recos(Uid, Phone, NumCommunityRecos) ->
    %% Get list of users that have Phone in their list of contacts.
    {ok, ReverseUids} = model_contacts:get_contact_uids(Phone),
    ReversePhones = model_accounts:get_phones(ReverseUids),

    %% Get Uid's list of contacts.
    {ok, ContactPhones} = model_contacts:get_contacts(Uid),

    % Get Uid's community-based recommendation list (Currently just getting whole list)
    CommunityUids = lists:sublist(model_friends:get_friend_recommendations(Uid), NumCommunityRecos),
    CommunityPhones = model_accounts:get_phones(CommunityUids),

    %% Combined list of three represents potential list of friends.
    ContactPhones2 =
        sets:to_list(sets:union([
            sets:from_list(ContactPhones), 
            sets:from_list(ReversePhones), 
            sets:from_list(CommunityPhones)
        ])),
    ContactPhones3 = [Phone2 || Phone2 <- ContactPhones2, Phone2 =/= undefined],
    PhoneToUidMap = model_phone:get_uids(ContactPhones3),
    ContactUids = maps:values(PhoneToUidMap),
    {ok, Friends} = model_friends:get_friends(Uid),
    RealFriends = model_accounts:filter_nonexisting_uids(lists:delete(Uid, Friends)),

    %% Set of recommended friends.
    RecoUidsSet = sets:subtract(sets:from_list(ContactUids), sets:from_list(RealFriends)),

    %% Keep map from Phone to Uid only for recommended friends.
    PhoneToUidMap2 = maps:filter(
        fun(_K, V) ->
            sets:is_element(V, RecoUidsSet)
        end, PhoneToUidMap),
    RecoPhones = maps:keys(PhoneToUidMap2), % we can use this to not have to check friendship

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
            _ ->
                case lists:member(CPhone, ContactPhones) of
                    true -> "C";
                    false -> 
                        case lists:member(CPhone, ReversePhones) of
                            true -> "R";
                            false -> "Y" 
                        end
                end
        end,
        binary_to_integer(CPhone),                              % Phone,
        maps:get(CPhone, PhoneToUidMap, ""),                    % Uid,
        maps:get(CPhone, PhoneToNameMap, ""),                   % Name
        maps:get(CPhone, PhoneToNumFriendsMap, 0)               % Num Friends
    } || CPhone <- RecoPhones],
    FriendsRecommendationList =
        [{_CorF, P, _U, _N, _NF} || {_CorF, P, _U, _N, _NF} <- ContactList,
            not util:is_test_number(util:to_binary(P))
            andalso util:to_binary(P) =/= Phone], 
    {ok, FriendsRecommendationList}.


-spec invite_recos(Uid :: uid(), MaxInviteRecommendations :: pos_integer()) -> ok.
invite_recos(Uid, MaxInviteRecommendations) ->
    ?INFO("generating invite recommendations for ~p", [Uid]),
    case model_accounts:account_exists(Uid) of
        false -> io:format("Uid ~s doesn't have an account.~n", [Uid]);
        true ->
            mod_athena_stats:run_query(invite_ouid_query(Uid, MaxInviteRecommendations))
    end,
    ok.


-spec invite_ouid_query(Uid :: uid(), MaxInviteRecommendations :: pos_integer()) -> athena_query().
invite_ouid_query(Uid, MaxInviteRecommendations) ->
    UidInt = binary_to_integer(Uid),
    QueryFormat = "
    SELECT uid, ouid, event_type, cnt from (
      SELECT 
          uid, 
          ouid, 
          event_type, 
          count(*) as cnt 
      FROM
          server_friend_event 
      WHERE 
          (uid = '~p' or ouid = '~p')
      GROUP BY 
          uid, 
          ouid, 
          event_type
    ) where cnt > 1;",
    Query = io_lib:format(QueryFormat, [UidInt, UidInt]),
    #athena_query{
        query_bin = list_to_binary(Query),
        result_fun = {?MODULE, process_invite_recos},
        tags = #{
            uid => Uid, 
            max_recs => MaxInviteRecommendations, 
            max_ouids => 400 % TODO (luke) make this a parameter
        } 
    }.


-spec process_invite_recos(Query :: athena_query()) -> ok.
process_invite_recos(Query) -> 
    Tags = Query#athena_query.tags,
    Uid = maps:get(uid, Tags, undefined),
    MaxInviteRecommendations = maps:get(max_recs, Tags, 25),
    MaxOuids = maps:get(max_ouids, Tags, 400),

    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    
    % Calculate amount of communication between Uid and each Ouid for future use
    OuidMap = lists:foldl(
        fun (ResultRow, UidAcc) ->
            [FromUidStr, ToUidStr, _EventTypeStr, CntStr | _] = maps:get(<<"Data">>, ResultRow),
            FromUid = integer_to_binary(util:to_integer(FromUidStr)),
            ToUid = integer_to_binary(util:to_integer(ToUidStr)),
            Cnt = util:to_integer(CntStr),
            case {FromUid =:= Uid, ToUid =:= Uid} of
                {true, false} -> 
                    update_ouid_map(ToUid, Cnt, UidAcc);
                {false, true} -> 
                    update_ouid_map(FromUid, Cnt, UidAcc)
            end
        end,
        #{},
        ActualResultRows),
    Ouids = lists:sublist(maps:keys(OuidMap), MaxOuids),
    ?INFO("Ouids: ~p", [Ouids]),

    % % print info about all uids
    % lists:foreach(
    %     fun ({Idx, Uid1}) ->
    %         {ok, #account{phone = Phone, name = Name, signup_user_agent = UserAgent,
    %             creation_ts_ms = CreationTs, last_activity_ts_ms = LastActivityTs} = Account} =
    %             model_accounts:get_account(Uid1),
    %         {CreationDate, CreationTime} = util:ms_to_datetime_string(CreationTs),
    %         {LastActiveDate, LastActiveTime} = util:ms_to_datetime_string(LastActivityTs),
    %         ?INFO("Uid~p: ~s, Name: ~s, Phone: ~s~n", [Idx, Uid1, Name, Phone]),
    %         io:format("Uid~p: ~s~nName: ~s~nPhone: ~s~n", [Idx, Uid1, Name, Phone]),
    %         io:format("Account created on ~s at ~s ua: ~s~n",
    %             [CreationDate, CreationTime, UserAgent]),
    %         io:format("Last activity on ~s at ~s~n",
    %             [LastActiveDate, LastActiveTime]),
    %         io:format("Current Version: ~s Lang: ~s~n", [Account#account.client_version, Account#account.lang_id])
    %     end,
    %     lists:zip(lists:seq(1, length(Ouids) + 1), [Uid | Ouids])),

    InviteRecommendations = generate_invite_recos(Uid, Ouids),

    ?INFO("(~p invite recommendations):", [length(InviteRecommendations)]),
    NewInvites2 = lists:sublist(InviteRecommendations, MaxInviteRecommendations),
    lists:foreach(
        fun({InvitePh, KnownUids}) ->
            ?INFO("  ~s", [InvitePh]),
            NamesMap = model_accounts:get_names(KnownUids),
            PhonesList = model_accounts:get_phones(KnownUids),
            PhoneUidList = lists:zip(PhonesList, KnownUids),
            [?INFO("    ~s, ~s, ~s",
                [maps:get(KnownUid, NamesMap, undefined), Phone, KnownUid]) ||
                {Phone, KnownUid} <- PhoneUidList]
        end, NewInvites2),
    ok.


-spec generate_invite_recos(Uid :: uid(), Ouids :: [uid()]) -> [{phone(), [uid()]}].
generate_invite_recos(Uid, Ouids) ->
    {ok, [MainContacts | OuidContactList]} = model_contacts:get_contacts([Uid | Ouids]),
    
    CommonContactsMap = lists:foldl(
        fun (Contact, CommonMap) ->
            KnownOuids = lists:foldl(
                fun ({Ouid, OuidContacts}, KnownAcc) ->
                    case lists:member(Contact, OuidContacts) of
                        true -> [Ouid | KnownAcc];
                        false -> KnownAcc
                    end
                end,
                [],
                lists:zip(Ouids, OuidContactList)),
            CommonMap#{Contact => KnownOuids}
        end,
        #{},
        MainContacts),

    CommonContacts = maps:keys(CommonContactsMap),
    CommonUidsMap = model_phone:get_uids(CommonContacts),

    NewInvites = [{Ph, maps:get(Ph, CommonContactsMap)} || Ph <- CommonContacts, 
            maps:get(Ph, CommonUidsMap, undefined) =:= undefined andalso 
            not util:is_test_number(Ph)],
    NewInvitesSorted = lists:reverse(lists:sort(
        fun ({_Ph1, KnownList1}, {_Ph2, KnownList2}) ->
            length(KnownList1) =< length(KnownList2)
        end, 
        NewInvites)),
    lists:filter(
        fun ({_Ph, KnownList}) ->
            length(KnownList) > 0
        end,
        NewInvitesSorted).


-spec update_ouid_map(Ouid :: uid(), Cnt :: pos_integer(), Map :: map()) -> map().
update_ouid_map(Ouid, Cnt, Map) ->
    {ok, FriendsList} = model_friends:get_friends(Ouid), 
    case dev_users:is_dev_uid(Ouid) orelse length(FriendsList) >= 15 of
        true -> 
            Map;
        false ->
            NewCnt = Cnt + maps:get(Ouid, Map, 0),
            maps:put(Ouid, NewCnt, Map)
    end.

