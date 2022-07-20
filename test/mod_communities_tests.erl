%%%-------------------------------------------------------------------
%%% File: mod_communities_tests.erl
%%% Copyright (C) 2022, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_communities_tests).
-author("luke").

-include_lib("eunit/include/eunit.hrl").
-include("community.hrl").


-define(UID1, <<"1000000000000000001">>).
-define(UID2, <<"1000000000000000002">>).
-define(UID3, <<"1000000000000000003">>).
-define(UID4, <<"1000000000000000004">>).
-define(UID5, <<"1000000000000000005">>).
-define(UID6, <<"1000000000000000006">>).
-define(UID7, <<"1000000000000000007">>). 
-define(UID8, <<"1000000000000000008">>). 

-define(PHONE1, <<"12065550001">>).
-define(PHONE2, <<"12065550002">>).
-define(PHONE3, <<"12065550003">>).
-define(PHONE4, <<"12065550004">>).
-define(PHONE5, <<"12065550005">>).
-define(PHONE6, <<"12065550006">>).
-define(PHONE7, <<"12065550007">>).
-define(PHONE8, <<"12065550008">>).

-define(NAME1, <<"TUser1">>).
-define(NAME2, <<"TUser2">>).
-define(NAME3, <<"TUser3">>).
-define(NAME4, <<"TUser4">>).
-define(NAME5, <<"TUser5">>).
-define(NAME6, <<"TUser6">>).
-define(NAME7, <<"TUser7">>).
-define(NAME8, <<"TUser8">>).

-define(UA, <<"HalloApp/Android1.0">>).

-define(FOR, fun ForLoop({End, End}, _Fun) -> ok; ForLoop({Start, End}, Fun) -> Fun(Start), ForLoop({Start+1, End}, Fun) end).

mod_communities_singleton_test() ->
    setup(),
    Options = [{max_communities_per_node, 2}, {fresh_start, true}],
    model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?UA),
    ?assertEqual(undefined, model_accounts:get_community_label(?UID1)),
    mod_communities:compute_communities(Options),
    ?assertEqual(undefined, model_accounts:get_community_label(?UID1)), %singletons should be ignored
    ok.

mod_communities_small_cluster_test() ->
    setup(),
    Options = [{max_communities_per_node, 2}, {fresh_start, true}, {small_cluster_threshold, 4}],
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?UA),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?UA),
    ok = model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?UA),

    % first test two friends 
    model_friends:add_friend(?UID1, ?UID2),

    {NumIters, Coms} = mod_communities:compute_communities(Options),
    NumComs = maps:size(Coms),
    ?assert(NumIters < 10),
    ?assertEqual(1, NumComs),

    model_friends:add_friend(?UID3, ?UID1),
    model_friends:add_friend(?UID3, ?UID2),

    {NumIters1, Coms1} = mod_communities:compute_communities(Options),
    NumComs1 = maps:size(Coms1),
    ?assert(NumIters1 < 10),
    ?assertEqual(1, NumComs1),

    ok.


mod_communities_disjoint_to_joined_test() ->
    setup(),
    Options = [{max_communities_per_node, 2}, {fresh_start, true}],

    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?UA),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?UA),
    ok = model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?UA),
    ok = model_accounts:create_account(?UID4, ?PHONE4, ?NAME4, ?UA),
    ok = model_accounts:create_account(?UID5, ?PHONE5, ?NAME5, ?UA),
    ok = model_accounts:create_account(?UID6, ?PHONE6, ?NAME6, ?UA),
    ok = model_accounts:create_account(?UID7, ?PHONE7, ?NAME7, ?UA),
    ok = model_accounts:create_account(?UID8, ?PHONE8, ?NAME8, ?UA),


    % Community 1 (Diamond with vertical line)
    model_friends:add_friend(?UID1, ?UID2),
    model_friends:add_friend(?UID3, ?UID2),
    model_friends:add_friend(?UID4, ?UID2),
    model_friends:add_friend(?UID3, ?UID4),
    model_friends:add_friend(?UID1, ?UID4),
    model_friends:add_friend(?UID1, ?UID1), % also test to make sure self-friend doesn't affect things

    % Community 2 (Diamond with vertical line)
    model_friends:add_friend(?UID5, ?UID6),
    model_friends:add_friend(?UID7, ?UID6),
    model_friends:add_friend(?UID7, ?UID5),
    model_friends:add_friend(?UID7, ?UID8),
    model_friends:add_friend(?UID8, ?UID6),

    {NumIters, Communities} = mod_communities:compute_communities(Options),
    NumComs = maps:size(Communities),
    ?assert(NumIters < 10),
    ?assertEqual(NumComs, 2),

    ComA1 = model_accounts:get_community_label(?UID1),
    ?assertEqual([1.0], maps:values(ComA1)),
    ?assertEqual(ComA1, model_accounts:get_community_label(?UID2)),
    ?assertEqual(ComA1, model_accounts:get_community_label(?UID3)),
    ?assertEqual(ComA1, model_accounts:get_community_label(?UID4)),

    ComB1 = model_accounts:get_community_label(?UID5),
    ?assertEqual([1.0], maps:values(ComB1)),
    ?assertEqual(ComB1, model_accounts:get_community_label(?UID6)),
    ?assertEqual(ComB1, model_accounts:get_community_label(?UID7)),
    ?assertEqual(ComB1, model_accounts:get_community_label(?UID8)),

    % Now join the communities -- should end up with still 2 communities, but UID1 in both
    model_friends:add_friend(?UID1, ?UID5),
    model_friends:add_friend(?UID1, ?UID7),

    {NumIters1, Communities1} = mod_communities:compute_communities(Options),
    NumComs1 = maps:size(Communities1),

    ?assert(NumIters1 < 10),
    ?assertEqual(2, NumComs1),
    ?assertEqual(2, maps:size(model_accounts:get_community_label(?UID1))), % 1 is in both communities


    % Now Fully join them into one community
    model_friends:add_friend(?UID4, ?UID7),
    
    {NumIters2, Communities2} = mod_communities:compute_communities(Options),
    NumComs2 = maps:size(Communities2),
    ?assert(NumIters2 < 10),
    ?assertEqual(1, NumComs2),

    ok.


mod_communities_scale_test() ->
    setup(),
    Options = [{fresh_start, true}],
    NumNodes = 100,
    NumCommunities = 5,
    CommunitySize = NumNodes div NumCommunities,
    MinNumFriends = 3,
    
    % Make all of the nodes
    ?FOR({0, NumNodes}, fun (NodeN) -> gen_test_acc(NodeN) end),

    % Only Link some nodes to each other in each community
    ?FOR({0, NumNodes}, fun (NodeN) -> make_friends(NodeN, MinNumFriends, CommunitySize) end),

    {NumIters, Communities} = mod_communities:compute_communities(Options),
    NumComs = maps:size(Communities),
    ?assert(NumIters < 10),
    ?assertEqual(NumCommunities, NumComs),

    % now fully link up communities 
    ?FOR({0, NumCommunities}, fun(CommunityNum) -> link_community(CommunityNum, CommunitySize) end),

    {NumIters2, Communities2} = mod_communities:compute_communities(Options),
    NumComs2 = maps:size(Communities2),

    ?assert(NumIters2 < 10),
    ?assertEqual(NumCommunities, NumComs2),

    ok.


mod_communities_analysis_test() ->
    setup(),
    Options = [{fresh_start, true}],
    NumSingles = 3,

    NumFiveToTen = 2,
    FiveToTenSize = 6,

    NumOverTen = 1,
    OverTenSize = 12,

    TotalNumNodes = NumSingles + NumFiveToTen * FiveToTenSize + NumOverTen * OverTenSize,
    ?FOR({0, TotalNumNodes+1}, fun (NodeN) -> gen_test_acc(NodeN) end),

    % make 2 communities of 6
    Start1 = NumSingles,
    End1 = NumSingles + FiveToTenSize + 1,
    End2 = End1 + FiveToTenSize + 1,
    link_range(Start1, End1),
    link_range(End1, End2),

    % Now Make 1 Community of 11
    link_range(End2, TotalNumNodes+1),

    {_NumIter, Communities} = mod_communities:compute_communities(Options),
    #{singleton := {NumSingleton, _}, 
        five_to_ten := {NumSizeFiveToTen, _}, 
        more_than_ten := {NumSizeLargerThan10, _}} = mod_communities:analyze_communities(Communities),
    
    ?assertEqual(0, NumSingleton), % singletons should be ignored
    ?assertEqual(NumFiveToTen, NumSizeFiveToTen),
    ?assertEqual(NumOverTen, NumSizeLargerThan10),
    ok.


friend_recommendation_test() ->
    setup(),
    Options = [{max_communities_per_node, 2}, {fresh_start, true}],
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?UA),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?UA),
    ok = model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?UA),
    ok = model_accounts:create_account(?UID4, ?PHONE4, ?NAME4, ?UA),
    ok = model_accounts:create_account(?UID5, ?PHONE5, ?NAME5, ?UA),


    model_friends:add_friend(?UID1, ?UID2),
    model_friends:add_friend(?UID3, ?UID2),
    model_friends:add_friend(?UID4, ?UID2),
    model_friends:add_friend(?UID3, ?UID4),
    model_friends:add_friend(?UID1, ?UID4),
    model_friends:add_friend(?UID5, ?UID3),
    model_friends:add_friend(?UID5, ?UID4),


    {_NumIters, _Communities} = mod_communities:compute_communities(Options),

    ?assertEqual(
        #{?UID1 => [?UID3, ?UID5], ?UID2 => [?UID5], ?UID3 => [?UID1], ?UID4 => []},
        model_friends:get_friend_recommendations([?UID1, ?UID2, ?UID3, ?UID4])
    ),


    ok.
    


%%===========================================================================
%% Internal Functions
%%===========================================================================

-spec gen_test_acc(pos_integer()) -> uid().
gen_test_acc(N) -> 
    % generates a test account s.t. Uid = <<"100000...N">>
    % Phone =  <<"12065550...N">>, Name = <<"TUserN">>
    NBin = integer_to_binary(N),
    NSize = byte_size(NBin),
    UidPadSize = util_uid:uid_size() - NSize - 1,
    UidPadding = binary:copy(<<"0">>, UidPadSize),
    Uid = <<<<"1">>/binary, UidPadding/binary, NBin/binary>>,
    
    PhonePadSize = 4 - NSize, %only pads last 4 digits,
    PhonePadding = binary:copy(<<"0">>, PhonePadSize),
    Phone =  <<<<"1206555">>/binary, PhonePadding/binary, NBin/binary>>,

    Name = <<<<"TUser">>/binary, NBin/binary>>,

    model_accounts:create_account(Uid, Phone, Name, ?UA),
    Uid.

get_test_uid(N) ->
    NBin = integer_to_binary(N),
    NSize = byte_size(NBin),
    UidPadSize = util_uid:uid_size() - NSize - 1,
    UidPadding = case UidPadSize < 0 of
        true -> <<"">>;
        false -> binary:copy(<<"0">>, UidPadSize)
    end,
    <<<<"1">>/binary, UidPadding/binary, NBin/binary>>.

link_community(CommunityNum, CommunitySize) ->
    CommunityStart = CommunityNum * CommunitySize,
    CommunityEnd = CommunityStart + CommunitySize,
    link_range(CommunityStart, CommunityEnd),

    ok.

make_friends(NodeN, MinNumFriends, CommunitySize) ->
    CommunityNum = NodeN div CommunitySize,
    MyCommunityIdx = NodeN - (CommunityNum * CommunitySize),
    MyUid = get_test_uid(NodeN),
    ?FOR({1, MinNumFriends + 1}, fun(I) ->
        BCommunityIdx = (MyCommunityIdx + I) rem CommunitySize,
        Buid = get_test_uid(BCommunityIdx + (CommunityNum * CommunitySize)),
        model_friends:add_friend(MyUid, Buid)
    end),
    ok.

link_range(ComStart, ComEnd) ->
    % ?debugFmt("Linking ~p-~p", [ComStart, ComEnd]),
    ?FOR({ComStart, ComEnd}, fun (N) -> 
        MyUid = get_test_uid(N),
        ?FOR({N+1, ComEnd}, fun (BNum) -> 
            Buid = get_test_uid(BNum),
            model_friends:add_friend(MyUid, Buid) 
        end)    
    end).


setup() ->
    tutil:setup(),
    ha_redis:start(),
    wpool:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_friends).
