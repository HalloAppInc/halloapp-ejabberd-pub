%%%-----------------------------------------------------------------------------------
%%% File    : mod_friend_recommendations.erl
%%%
%%% Copyright (C) 2022 halloappinc.
%%%-----------------------------------------------------------------------------------

-module(mod_recommendations).
-author('vipin').

-behaviour(gen_mod).

-include("logger.hrl").
-include("ha_types.hrl").
-include("athena_query.hrl").
-include("account.hrl").
-include("groups.hrl").
-include("friend_scoring.hrl").

% -define(SCAN_SIZE, 2500).
-define(DEFAULT_NUM_OUIDS, 10).

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

-export([
    generate_friend_recos/2,
    invite_recos/2,
    invite_recos/3,
    process_invite_recos/1,
    generate_invite_recos/2,
    % all_shared_group_membership/0,
    shared_group_membership/1,
    do_friend_scoring/0,
    do_friend_scoring/1,
    score_all_friends/1
]).

%% Hooks
-export([reassign_jobs/0]).

%% -------------------------------------------- %%
%% gen_mod API functions
%% --------------------------------------------	%%
start(_Host, _Opts) ->
    ?INFO("starting", []),
    ejabberd_hooks:add(reassign_jobs, ?MODULE, reassign_jobs, 10),
    check_and_schedule(),
    ok.

-spec schedule() -> ok.
schedule() ->
    % Runs weekly on Mondays at 3pm PST
    erlcron:cron(do_friend_scoring, {
        {weekly, mon, {10, pm}},
        {?MODULE, do_friend_scoring, []}
    }).


stop(_Host) ->
    ?INFO("stopping", []),
    ejabberd_hooks:delete(reassign_jobs, ?MODULE, reassign_jobs, 10),
    case util:is_main_stest() of
        true -> unschedule();
        false -> ok
    end,
    ok.

-spec unschedule() -> ok.
unschedule() ->
    erlcron:cancel(do_friend_scoring),
    ok.


reload(_Host, _NewOpts, _OldOpts) ->
    ok.


depends(_Host, _Opts) ->
    [].


mod_options(_Host) ->
    [].


%%====================================================================
%% Hooks
%%====================================================================

reassign_jobs() ->
    unschedule(),
    check_and_schedule(),
    ok.


check_and_schedule() ->
    case util:is_main_stest() of
        true -> schedule();
        false -> ok
    end,
    ok.

%% -------------------------------------------- %%
%% Friend Recommendation API 
%% --------------------------------------------	%%

-spec generate_friend_recos(Uid :: uid(), Phone :: binary()) -> 
        {ok, [{string(), integer(), binary(), binary(), integer()}]}.
generate_friend_recos(Uid, Phone) ->
    AppType = util_uid:get_app_type(Uid),
    %% Get list of users that have Phone in their list of contacts.
    {ok, ReverseUids} = model_contacts:get_contact_uids(Phone, AppType),
    ReversePhones = model_accounts:get_phones(ReverseUids),

    %% Get Uid's list of contacts.
    {ok, ContactPhones} = model_contacts:get_contacts(Uid),

    %% Combined list of three represents potential list of friends.
    ContactPhones2 =
        sets:to_list(sets:union([
            sets:from_list(ContactPhones), 
            sets:from_list(ReversePhones)
        ])),
    ContactPhones3 = [Phone2 || Phone2 <- ContactPhones2, Phone2 =/= undefined],
    PhoneToUidMap = model_phone:get_uids(ContactPhones3, halloapp),
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
    invite_recos(Uid, MaxInviteRecommendations, ?DEFAULT_NUM_OUIDS).

-spec invite_recos(Uid :: uid(), MaxInviteRecommendations :: pos_integer(), NumOuids :: pos_integer()) -> ok.
invite_recos(Uid, MaxInviteRecommendations, NumOuids) ->
    case model_accounts:account_exists(Uid) of
        false -> io:format("Uid ~s doesn't have an account.~n", [Uid]);
        true ->
            {ok, Name} = model_accounts:get_name(Uid),
            ?INFO("Generating invite recommendations for ~p (~s)", [Uid, Name]),
            mod_athena_stats:run_query(invite_ouid_query(Uid, MaxInviteRecommendations, NumOuids))
    end,
    ok.


-spec invite_ouid_query(uid(), pos_integer(), pos_integer()) -> athena_query().
invite_ouid_query(Uid, MaxInviteRecommendations, NumOuids) ->
    UidInt = util:to_integer(Uid),
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
        query_bin = util:to_binary(Query),
        result_fun = {?MODULE, process_invite_recos},
        tags = #{
            uid => Uid, 
            max_recs => MaxInviteRecommendations, 
            max_ouids => NumOuids
        } 
    }.


-spec process_invite_recos(Query :: athena_query()) -> ok.
process_invite_recos(Query) -> 
    try
        Tags = Query#athena_query.tags,
        Uid = maps:get(uid, Tags, undefined),
        MaxInviteRecommendations = maps:get(max_recs, Tags, 25),
        MaxOuids = maps:get(max_ouids, Tags, 400),

        Result = Query#athena_query.result,
        ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
        [_HeaderRow | ActualResultRows] = ResultRows,
        
        % Calculate amount of communication between Uid and each Ouid
        OuidCommunicationMap = lists:foldl(
            fun (ResultRow, UidAcc) ->
                [FromUidStr, ToUidStr, _EventTypeStr, CntStr | _] = maps:get(<<"Data">>, ResultRow),
                FromUid = util:to_binary(FromUidStr),
                ToUid = util:to_binary(ToUidStr),
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
        OuidCommunicationList = maps:to_list(OuidCommunicationMap),

        UidGroups = model_groups:get_groups(Uid),
        SharedGroupMembership = get_shared_group_membership(UidGroups),
        % Consolidate number of shared groups and friend events into single list
        OuidInfoList = lists:map(
            fun ({Ouid, NumEvents}) ->
                SharedGroups = maps:get(Ouid, SharedGroupMembership, []),
                {Ouid, NumEvents, length(SharedGroups)}
            end,
            OuidCommunicationList),
        % Sort first by number of shared groups with Uid, then by number of friend_events
        SortedOuidInfo = lists:sort( 
            fun ({_Ouid1, NumEvents1, NumGroups1}, {_Ouid2, NumEvents2, NumGroups2}) when NumGroups1 =:= NumGroups2 ->
                    NumEvents1 >= NumEvents2;
                ({_Ouid1, _NumEvents1, NumGroups1}, {_Ouid2, _NumEvents2, NumGroups2}) ->
                    NumGroups1 > NumGroups2
            end,
            OuidInfoList),

        FinalUidInfo = lists:sublist(SortedOuidInfo, MaxOuids),
        {Ouids, _NumEvents, _NumGroups} = lists:unzip3(FinalUidInfo),

        InviteRecommendations = generate_invite_recos(Uid, Ouids),

        NamesMap = model_accounts:get_names(Ouids),
        ?INFO("Top 10 Close Friends Info:"),
        lists:foreach(
            fun ({Ouid, NumEvents, NumCommonGroups}) ->
                ?INFO("  ~s: ~p groups, ~p friend_events", 
                    [maps:get(Ouid, NamesMap, Ouid), NumCommonGroups, NumEvents])
            end,
            lists:sublist(FinalUidInfo, 10)),

        ?INFO("Showing ~p out of ~p invite recommendations:", [MaxInviteRecommendations, length(InviteRecommendations)]),
        NewInvites2 = lists:sublist(InviteRecommendations, MaxInviteRecommendations),
        lists:foreach(
            fun({InvitePh, KnownUids}) ->
                ?INFO("  ~s", [InvitePh]),
                PhonesList = model_accounts:get_phones(KnownUids),
                PhoneUidList = lists:zip(PhonesList, KnownUids),
                [?INFO("    ~s, ~s, ~s",
                    [maps:get(KnownUid, NamesMap, undefined), Phone, KnownUid]) ||
                    {Phone, KnownUid} <- PhoneUidList]
            end, NewInvites2)
    catch
        Class : Reason : Stacktrace  ->
            ?ERROR("Error in process_invite_recos: ~p Stacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})])            
    end,
    ok.


%% -------------------------------------------- %%
%% Invite Recommendation API 
%% --------------------------------------------	%%

-spec generate_invite_recos(Uid :: uid(), Ouids :: [uid()]) -> [{phone(), [uid()]}].
generate_invite_recos(Uid, Ouids) ->
    {ok, [MainContacts | OuidContactList]} = model_contacts:get_contacts([Uid | Ouids]),
    
    OuidEnum = lists:zip(lists:seq(1, length(Ouids)), Ouids),
    CommonContactsMap = lists:foldl(
        fun (Contact, CommonMap) ->
            KnownOuids = lists:foldl(
                fun ({OuidRank, OuidContacts}, KnownAcc) ->
                    case lists:member(Contact, OuidContacts) of
                        true -> [OuidRank | KnownAcc];
                        false -> KnownAcc
                    end
                end,
                [],
                lists:zip(OuidEnum, OuidContactList)),
            CommonMap#{Contact => lists:reverse(KnownOuids)} % display known ids in rank order
        end,
        #{},
        MainContacts),

    CommonContacts = maps:keys(CommonContactsMap),
    CommonUidsMap = model_phone:get_uids(CommonContacts, halloapp),

    NewInvites = [{Ph, maps:get(Ph, CommonContactsMap)} || Ph <- CommonContacts, 
            maps:get(Ph, CommonUidsMap, undefined) =:= undefined andalso 
            not util:is_test_number(Ph)],

    NewInvitesSorted = lists:sort(
        fun ({_Ph1, KnownList1}, {_Ph2, KnownList2}) when length(KnownList1) =:= length(KnownList2) ->
                % Sort recommendations by aggregate closeness rank of common contacts
                Rank1 = lists:foldl(
                    fun ({Rank, _Ouid}, Acc) ->
                        Acc + Rank
                    end, 
                    0, 
                    KnownList1),
                Rank2 = lists:foldl(
                    fun ({Rank, _Ouid}, Acc) ->
                        Acc + Rank
                    end, 
                    0, 
                    KnownList2),
                Rank1 =< Rank2; % lower rank is better (closer to front of best friends list)
            ({_Ph1, KnownList1}, {_Ph2, KnownList2}) ->
                length(KnownList1) > length(KnownList2)
        end, 
        NewInvites),
    Filtered = lists:filter(
        fun ({_Ph, KnownList}) ->
            length(KnownList) > 0
        end,
        NewInvitesSorted),
    lists:map(
        fun ({Ph, KnownList}) ->
            {_Ranks, KnownOuids} = lists:unzip(KnownList),
            {Ph, KnownOuids}
        end,
        Filtered).


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


% -spec all_shared_group_membership() -> ok.
% all_shared_group_membership() ->
%     Nodes = model_accounts:get_node_list(),
%     lists:foreach(fun (Node) -> 
%                         do_all_shared_group_membership(0, Node, false)
%                   end, Nodes),
%     ?INFO("Done with identifying shared group membership"),
%     ok.

% -spec do_all_shared_group_membership(non_neg_integer(), node(), boolean()) -> integer().
% do_all_shared_group_membership(0, _Node, true) ->
%     ok;
% do_all_shared_group_membership(Cursor, Node, _NotFirstScan) ->
%     NumFriendsThreshold = 10,
%     GroupsThreshold = 2,
    
%     {NewCur, BinKeys} = model_accounts:scan(Node, Cursor, ?SCAN_SIZE),
%     Uids = lists:map(
%         fun (BinKey) ->
%             extract_uid(BinKey)
%         end, BinKeys),
%     {ok, FriendMap} = model_friends:get_friends(Uids),
%     case {Uids, Cursor} of 
%         {[], 0} -> ok;
%         _ -> lists:foreach(
%                 fun (Uid) -> 
%                     Friends = maps:get(Uid, FriendMap, []),
%                     case length(Friends) >= NumFriendsThreshold of
%                         true -> 
%                             Groups = model_groups:get_groups(Uid),
%                             case length(Groups) >= GroupsThreshold of
%                                 true -> shared_group_membership(Uid, Groups, Friends);
%                                 false -> ok
%                             end;
%                         false -> ok
%                     end 
%                 end, 
%                 Uids),
%             do_all_shared_group_membership(NewCur, Node, true)
%     end.


-spec shared_group_membership(Uid :: uid()) -> ok.
shared_group_membership(Uid) ->
    Groups = model_groups:get_groups(Uid),
    {ok, Friends} = model_friends:get_friends(Uid),
    shared_group_membership(Uid, Groups, Friends).

shared_group_membership(Uid, Groups, Friends) ->
    % map of Uids -> [shared groups with uid]
    SharedMembership = get_shared_group_membership(Groups),
    
    ONameMap = model_accounts:get_names(maps:keys(SharedMembership)),
    InfoList = maps:fold(
        fun (Ouid, _OName, Acc) when Ouid =:= Uid -> 
                Acc;
            (Ouid, OName, Acc) ->
                CommonGroups = maps:get(Ouid, SharedMembership),
                NumCommonGroups = length(CommonGroups),
                case NumCommonGroups > 1 andalso not dev_users:is_dev_uid(Ouid) of
                    true -> [{OName, Ouid, NumCommonGroups, CommonGroups} | Acc];
                    false -> Acc
                end
        end,
        [],
        ONameMap),
    SortedInfo = lists:reverse(lists:keysort(3, InfoList)),

    print_shared_group_info(Uid, length(Groups), Friends, SortedInfo),
    ok.


-spec get_shared_group_membership(Groups :: [gid()]) -> #{uid() => [gid()]}.
get_shared_group_membership([]) -> #{};
get_shared_group_membership(Groups) ->
    GroupMemberMap = model_groups:get_member_uids(Groups),
    lists:foldl(
        fun (GroupId, MembershipAcc) ->
            Members = maps:get(GroupId, GroupMemberMap, []),
            lists:foldl(
                fun (MemberUid, Acc) ->
                    CurMembership = maps:get(MemberUid, Acc, []),
                    maps:put(MemberUid, [GroupId | CurMembership], Acc)
                end,
                MembershipAcc,
                Members)
        end,
        #{},
        Groups).


print_shared_group_info(Uid, NumGroups, _Friends, []) ->
    {ok, Name} = model_accounts:get_name(Uid),
    ?INFO("~p (~p) has no common group membership out of ~p groups", [Uid, Name, NumGroups]);

print_shared_group_info(Uid, NumGroups, Friends, InfoList) ->
    {ok, Name} = model_accounts:get_name(Uid),
    ?INFO("~p (~p) is a member of ~p groups:", [Uid, Name, NumGroups]),

    FriendSet = sets:from_list(Friends),
    lists:foreach(
        fun ({OName, Ouid, NumCommonGroups, CommonGroups}) ->
            case sets:is_element(Ouid, FriendSet) of 
                true -> ?INFO("  F ~p (~p) is in ~p common groups: ~p", [Ouid, OName, NumCommonGroups, CommonGroups]);
                false -> ?INFO("  N ~p (~p) is in ~p common groups: ~p", [Ouid, OName, NumCommonGroups, CommonGroups])
            end
        end,
        InfoList).


%% -------------------------------------------- %%
%% Friend Scoring API 
%% --------------------------------------------	%%

-spec do_friend_scoring() -> ok.
do_friend_scoring() ->
    mod_athena_stats:run_query(all_friend_events_query(undefined)).

do_friend_scoring(Uid) -> % to allow for smaller-scale testing
    mod_athena_stats:run_query(all_friend_events_query(Uid)).


-spec all_friend_events_query(maybe(uid())) -> athena_query().
all_friend_events_query(Uid) ->
    % Get count of all friend events between users
    QueryMiddle = case Uid of
        undefined -> io_lib:format("~n", []);
        _ when is_binary(Uid) ->
            io_lib:format("~nWHERE (uid = '~s' OR ouid = '~s')~n", [Uid, Uid])
    end,
    Query = "
        SELECT 
            uid, 
            ouid, 
            event_type,
            count(*) AS cnt
        FROM server_friend_event" ++ 
        QueryMiddle ++
        "GROUP BY 
            uid, 
            ouid,
            event_type;",

    #athena_query{
      query_bin = util:to_binary(Query),
      result_fun = {?MODULE, score_all_friends}
    }.


-spec score_all_friends(Query :: athena_query()) -> ok.
score_all_friends(Query) ->
    StartMs = util:now_ms(),
    FriendEventMap = parse_query_results(Query, #{}),
    Uids = maps:keys(FriendEventMap),
    {ok, FriendsListMap} = model_friends:get_friends(Uids),
    GroupMap = model_groups:get_groups(Uids),

    lists:foreach(
        fun (Uid) -> 
            Groups = maps:get(Uid, GroupMap, []),
            Friends = maps:get(Uid, FriendsListMap, []),
            EventMap = maps:get(Uid, FriendEventMap, #{}),
            ?INFO("Ranking Uid ~p's friends: ~p", [Uid, Friends]),
            rank_friends(Uid, Friends, Groups, EventMap)
        end,
        Uids),
    ?INFO("Done ranking friends for ~p uids! Took ~p ms", [length(Uids), util:now_ms() - StartMs]),
    ok.


-spec parse_query_results(athena_query(), CurEventMap :: map()) -> map().
parse_query_results(#athena_query{result = Result, exec_id = ExecutionId}, CurEventMap) ->
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [HeaderRow | NonHeaderRows] = ResultRows,
    FinalResultRows = case lists:member(<<"uid">>, maps:get(<<"Data">>, HeaderRow, [])) of
        false -> ResultRows;
        true -> NonHeaderRows
    end,
    ?INFO("Processing ~p rows", [length(FinalResultRows)]),
    NewEventMap = lists:foldl(
        fun (ResultRow, EventAcc) ->
            [FromUidStr, ToUidStr, EventTypeStr, CntStr | _] = maps:get(<<"Data">>, ResultRow),
            FromUid = util:to_binary(FromUidStr),
            ToUid = util:to_binary(ToUidStr),
            Cnt = util:to_integer(CntStr),
            EventType = util:to_atom(EventTypeStr),

            ScoreInc = get_score_inc(Cnt, EventType),

            FromUidMap = maps:get(FromUid, EventAcc, #{}), 
            CurToScore = maps:get(ToUid, FromUidMap, 0),
            UpdatedFromUidMap = maps:put(ToUid, CurToScore + ScoreInc, FromUidMap),

            ToUidMap = maps:get(ToUid, EventAcc, #{}),
            CurFromScore = maps:get(FromUid, ToUidMap, 0),
            UpdatedToUidMap = maps:put(FromUid, CurFromScore + ScoreInc, ToUidMap), 

            EventAcc#{FromUid => UpdatedFromUidMap, ToUid => UpdatedToUidMap}
        end,
        CurEventMap,
        FinalResultRows),
    
    case maps:get(<<"NextToken">>, Result, undefined) of
        undefined -> NewEventMap;
        NextToken -> 
            {ok, NextResult} = erlcloud_athena:get_query_results(ExecutionId, #{<<"NextToken">> => NextToken}),
            parse_query_results(#athena_query{result = NextResult, exec_id = ExecutionId}, NewEventMap)
    end.


-spec get_score_inc(integer(), atom()) -> integer().
get_score_inc(NumEvents, group_comment_published) -> 
    NumEvents * ?COMMENT_MULT;
get_score_inc(NumEvents, comment_published) ->
    NumEvents * ?COMMENT_MULT;

get_score_inc(NumEvents, group_comment_reaction_published) ->
    NumEvents * ?REACTION_MULT;
get_score_inc(NumEvents, comment_reaction_published) ->
    NumEvents * ?REACTION_MULT;

get_score_inc(NumEvents, post_receive_seen) ->
    NumEvents * ?POST_SEEN_MULT;

get_score_inc(NumEvents, im_receive_seen) ->
    NumEvents * ?IM_MULT;

get_score_inc(NumEvents, EventType) ->
    ?INFO("Processing unknown friend event: ~s", [EventType]),
    NumEvents * ?DEFAULT_MULT.


%% Updates redis with new friend scores
-spec rank_friends(uid(), list(uid()), list(gid()), #{uid() => integer()}) -> ok.
rank_friends(Uid, FriendList, GroupList, FriendEventMap) ->
    SharedGroupMembership = get_shared_group_membership(GroupList),
    FriendScoreMap = lists:foldl(
        fun (Ouid, Acc) ->
            NumSharedGroups = length(maps:get(Ouid, SharedGroupMembership, [])),
            NumFriendEvents = maps:get(Ouid, FriendEventMap, 0),
            FriendScore = case dev_users:is_dev_uid(Uid) andalso dev_users:is_dev_uid(Ouid) of
                true -> 0; %% if both users are devs, score 0
                false -> NumFriendEvents + (NumSharedGroups * ?SHARED_GROUP_MULT)
            end,
            maps:put(Ouid, FriendScore, Acc)
        end,
        #{},
        FriendList),
    
    model_friends:set_friend_scores(Uid, FriendScoreMap).

