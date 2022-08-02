%%%-------------------------------------------------------------------
%%% @author luke
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 16. Jun 2022 12:44 PM
%%%-------------------------------------------------------------------

%%%-------------------------------------------------------------------
%% This module implements a community detection algorithm using label propagation following 
%% Steve Gregory's 2010 paper (doi: https://doi.org/10.1088/1367-2630/12/10/103018) 
%% The basic idea is to start with each node in its own community, and then iteratively assign it 
%% the communities held by the majority of its neighbors (i.e. if 4 of node 1's friends are in 
%% community 7 and 3 friends are in community 6, then node 1 will join community 7). This specific 
%% version of the algorithm was chosen because it allows for nodes to be a part of multiple 
%% communities, which often occurs in social networks. The specific number of communities a node is 
%% able to be a part of is configurable using the DEFAULT_MAX_COMMUNITIES macro in community.hrl or 
%% as the input to compute_communities/1.
%%%-------------------------------------------------------------------

-module(mod_communities).
-author(luke).

-behaviour(gen_mod).

-include("logger.hrl").
-include("ha_types.hrl").
-include("redis_keys.hrl").
-include("community.hrl").
-include("athena_query.hrl").

-ifdef(TEST).
%% debugging purposes
-include_lib("eunit/include/eunit.hrl").
-define(dbg(S, As), io:fwrite(user, <<"~ts\n">>, [io_lib:format((S), (As))])).
-else.
-define(dbg(S, As), ok).
-endif.


%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).


% API
-export([
    schedule/0,
    unschedule/0,
    analyze_communities/1,
    compute_communities/0,
    compute_communities/1
]).

% parallel processing functions
-export([
    batch_propagate/3,
    batch_combine_small_clusters/3,
    batch_set_labels/2
]).

% For debugging single step purposes
-export([
    setup_community_detection/2,
    identify_communities/4,
    single_step_label_propagation/3,
    apply_single_step_labels/0,
    finish_community_detection/2,
    generate_friend_recommendations/2,
    cleanup_community_detection/0,
    is_not_isolated/4
]).

start(_Host, _Opts) ->
    % ?INFO("starting", []),
    % case util:get_machine_name() of
    %     <<"s-test">> ->
    %         schedule();
    %     _ -> ok
    % end,
    ok.

-spec schedule() -> ok.
schedule() ->
    % %% Updates community labels once a week
    % erlcron:cron(weekly_community, {
    %     {weekly, wed, {03, am}},
    %     {?MODULE, compute_communities, []}
    % }),

    % %% Files written by dump_accounts on Tuesday at 10pm will be sent to S3 the next day.
    % %% Glue crawler run at 2am. We need to run computation after that.

    ok.

stop(_Host) ->
    % ?INFO("stopping", []),
    % case util:get_machine_name() of
    %     <<"s-test">> ->
    %         unschedule();
    %     _ -> ok
    % end,
    ok.

-spec unschedule() -> ok.
unschedule() ->
    % erlcron:cancel(weekly_community),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

depends(_Host, _Opts) ->
    [].

%%====================================================================
%% Community Analysis API
%%====================================================================

% Takes in a map returned by the label propagation algorithm of community_ids to members
% (that is, #{community_id => {members => belong_coeff}})
-spec analyze_communities(#{uid() => community_label()}) -> map().
analyze_communities(CommunitiesMap) ->
    ?INFO("Analyzing Communities"),
    Communities = maps:map(
        fun (_CommunityId, Members) -> 
            maps:keys(Members) 
        end, 
        CommunitiesMap),
    SizesList = lists:sort(maps:fold(
        fun (_CommunityId, Members, AccList) ->
            [length(Members) | AccList]
        end,
        [],
        Communities)),
    MiddleIdx = length(SizesList) div 2,
    MedianSize = case length(SizesList) rem 2 of
        0 -> (lists:nth(MiddleIdx, SizesList) + lists:nth(MiddleIdx + 1, SizesList)) div 2;
        _ -> lists:nth(MiddleIdx + 1, SizesList)
    end,
    AvgSize = lists:foldl(
        fun (CommunitySize, SizeAcc) ->
            SizeAcc + CommunitySize
        end,
        0,
        SizesList) div length(SizesList),
    %% Acc has format #{singleton => {NumSingleton, SingletonList}, 
    %%                  five_to_ten => {NumSizeFiveToTen, SizeFiveToTenList}, 
    %%                  more_than_ten => {NumSizeLargerThan10, SizeLargerThan10List}}
    AccInit = #{singleton => {0, []}, five_to_ten => {0, []}, more_than_ten => {0, []}},
    Res = maps:fold(
        fun community_fold_fun/3, 
        AccInit, 
        Communities),
    Res#{median => MedianSize, average => AvgSize}.


community_fold_fun(CommunityId, [_SingleMember], 
        #{singleton := {NumSingleton, SingletonList}} = AccIn) ->
    AccIn#{singleton := {NumSingleton + 1, [CommunityId | SingletonList]}};

community_fold_fun(_CommunityId, MemberList, AccIn) when length(MemberList) < 5 ->
    AccIn;

community_fold_fun(CommunityId, MemberList, 
        #{five_to_ten := {NumSizeFiveToTen, SizeFiveToTenList}} = AccIn) 
        when length(MemberList) < 10 ->
    AccIn#{five_to_ten := {NumSizeFiveToTen + 1, [CommunityId | SizeFiveToTenList]}};

community_fold_fun(CommunityId, _MemberList, 
        #{more_than_ten := {NumSizeLargerThan10, SizeLargerThan10List}} = AccIn) ->
    AccIn#{more_than_ten := {NumSizeLargerThan10 + 1, [CommunityId | SizeLargerThan10List]}}.


%%====================================================================
%% Community Detection API
%%====================================================================

-spec get_option(Option :: atom(), Default :: term(), OptList :: [propagation_option()]) -> term().
get_option(Option, Default, OptList) ->
    case lists:keyfind(Option, 1, OptList) of
        {Option, Val} -> Val;
        false -> Default
    end.

% * Automatically performs full label propagation and stores results in Redis
-spec compute_communities() -> {non_neg_integer(), map()}.
compute_communities() -> compute_communities([]). % use default values

-spec compute_communities(RunOpts :: [propagation_option()]) -> 
    {non_neg_integer(), map()}.
compute_communities(RunOpts) ->
    Start = util:now_ms(),
    NumWorkers = get_option(num_workers, ?COMMUNITY_DEFAULT_NUM_WORKERS, RunOpts),
    FreshStart = get_option(fresh_start, false, RunOpts),
    MaxNumCommunities = get_option(max_communities_per_node, ?DEFAULT_MAX_COMMUNITIES, RunOpts),
    MaxIters = get_option(max_iters, ?DEFAULT_MAXIMUM_ITERATIONS, RunOpts),
    BatchSize = get_option(batch_size, ?MATCH_CHUNK_SIZE, RunOpts),
    SmallClusterThreshold = get_option(small_cluster_threshold, ?DEFAULT_SMALL_CLUSTER_THRESHOLD, RunOpts),
    MaxRecommendations = get_option(max_recommendations, ?DEFAULT_MAX_RECOMMEND_SIZE, RunOpts),
    
    % setup ets table 
    setup_community_detection(NumWorkers, FreshStart),

    % Next, run the community detection algorithm
    {PrevMin, NumIters} = identify_communities(#{}, MaxNumCommunities, BatchSize, {0, MaxIters}),

    Success = PrevMin =:= #{},
    % post-process communities and clean up ets
    Communities = finish_community_detection(BatchSize, SmallClusterThreshold),

    generate_friend_recommendations(Communities, MaxRecommendations),

    cleanup_community_detection(),

    case Success of 
        true ->
            ?INFO("-----Community detection finished in ~p iterations (~p ms), finding ~p unique communities-----",
                [NumIters, util:now_ms() - Start, maps:size(Communities)]);
        false ->
            ?INFO("Community Detection was unsuccessful, ending at ~p iterations (~p ms) with ~p unique communities",
                [NumIters, util:now_ms() - Start, maps:size(Communities)])
    end,

    {NumIters, Communities}.


% * Initialize Ets table for label propagation
-spec setup_community_detection(pos_integer(), boolean()) -> ok.
setup_community_detection(NumWorkers, FreshStart) -> 
    ?INFO("Setting up for community detection using ~p workers. Starting fresh: ~p", [NumWorkers, FreshStart]),
    Start = util:now_ms(),

    WorkerPoolOptions = [{workers, NumWorkers}],
    wpool:start_sup_pool(?COMMUNITY_WORKER_POOL, WorkerPoolOptions),
    % Make a new table for storing node information
    % Elem structure is {{labelinfo,f Uid}, Old_Label, New_Label}
    ets:new(?COMMUNITY_DATA_TABLE, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),

    % first, dump information from Redis into ets
    Nodes = model_accounts:get_node_list(),
    lists:foreach(fun (Node) -> 
                        load_keys(0, 0, Node, FreshStart)
                  end, Nodes),

    ?INFO("CommunityDetection Initialization took ~p ms", [util:now_ms() - Start]),
    ok.


% * Main loop of label propagation algorithm:
% * Propagates new labels and then checks termination condition
-spec identify_communities(PrevMin :: map(), MaxNumCommunities :: pos_integer(), BatchSize :: pos_integer(),
        {IterNum :: non_neg_integer(), MaxIters :: non_neg_integer()}) -> non_neg_integer().
identify_communities(PrevMin, _MaxNumCommunities, _BatchSize, {MaxIters, MaxIters}) ->
    ?INFO("Community identification reached maximum iteration limit of ~p", [MaxIters]),
    % ?dbg("Community identification reached maximum iteration limit of ~p", [MaxIters]),
    {PrevMin, MaxIters}; % return map that can be used to continue computation
identify_communities(PrevMin, MaxNumCommunities, BatchSize, {IterNum, MaxIters}) ->
    % Do an iteration of label propagation
    ?INFO("Iteration ~p/~p", [IterNum + 1, MaxIters]),
    % ?dbg("_________Iteration ~p/~p __________", [IterNum + 1, MaxIters]),
    {MinCommunityIdCounts, Continue} = single_step_label_propagation(PrevMin, MaxNumCommunities, BatchSize),

    case Continue of 
        true -> 
                % If we should continue, apply the labels we just calculated and go again
                apply_single_step_labels(),
                identify_communities(MinCommunityIdCounts, MaxNumCommunities, BatchSize, 
                    {IterNum + 1, MaxIters});
        false -> 
            ?INFO("Label Propagation Finished!!"),
            {#{}, IterNum + 1} % count this iteration, return empty map to indicate success
    end.


% * Do a single round of calculating new labels
-spec single_step_label_propagation(PrevMin :: map(), MaxNumCommunities :: pos_integer(), 
        BatchSize :: pos_integer()) -> {map(), boolean()}.
single_step_label_propagation(PrevMin, MaxNumCommunities, BatchSize) ->
    % ?INFO("Starting Label Propagation iteration over ~p uids", [ets:info(?COMMUNITY_DATA_TABLE, size)]),
    Start = util:now_ms(),
    % ?dbg("----------", []),
    % calculate new labels for each node in parallel batches of size ?MATCH_CHUNK_SIZE
    foreach_uid_batch(batch_propagate, [MaxNumCommunities], BatchSize),

    % check termination condition -- essentially: are the sizes of communities meaningfully changing?
    {OldCommunityIdCounts, NewCommunityIdCounts} = get_community_membership_counts(),
    CombinedCommunityIds = maps:merge(OldCommunityIdCounts, NewCommunityIdCounts),

    % The number of CommunityIds in use decreases monotonically, so this reflects 
    % OldCommunityIdCounts != NewCommunityIdCounts
    MinCommunityIdCounts = case maps:size(CombinedCommunityIds) > maps:size(NewCommunityIdCounts) of 
        true -> NewCommunityIdCounts;
        false -> min_counts(PrevMin, NewCommunityIdCounts)
    end,
    % ?dbg("ComboCids: ~p~nNewComIds ~p", [CombinedCommunityIds, NewCommunityIdCounts]),
    Continue = MinCommunityIdCounts =/= PrevMin,
    % ?dbg("Continue? ~p -- Min ~p , PrevMin ~p", [Continue, MinCommunityIdCounts, PrevMin]),
    ?INFO("CommunityDetection single iteration found ~p new communities in ~p ms", 
        [maps:size(MinCommunityIdCounts), util:now_ms() - Start]),
    {MinCommunityIdCounts, Continue}.


% * Apply each uid's new label to be it's current label
-spec apply_single_step_labels() -> ok.
apply_single_step_labels() ->
    Start = util:now_ms(),
    foreach_uid(
            fun (Uid, _, NewLabel) -> 
                apply_new_label(Uid, NewLabel) 
            end),
    ?INFO("CommunityDetection applying labels took ~p ms", [util:now_ms() - Start]).


% * finalize list of non-subset communities, store in redis, and cleanup resources
-spec finish_community_detection(pos_integer(), pos_integer()) -> map().
finish_community_detection(BatchSize, SmallClusterThreshold) ->
    Start = util:now_ms(),
    % Now post processing to clean up the community set and remove communities that are subsets of others
    
    % First, combine any small disjoint clusters of users, as they aren't handled very well by the 
    % label propagation algorithm
    foreach_uid_batch(batch_combine_small_clusters, [SmallClusterThreshold], BatchSize),
    
    % Now filter out any communities that are just subsets of other communities
    {DirtyCommunities, SubsetMap} = fold_all_uids(
        fun (Uid, CurLabel, _NewLabel, Acc) -> 
            identify_community_subsets(Uid, CurLabel, Acc) 
        end, {#{}, #{}}),
    
    CommunitySubsetMap = maps:filter(
        fun  (_, CommunityIds) -> 
            not sets:is_empty(CommunityIds)
        end, SubsetMap),
    SubsetCommunities = maps:keys(CommunitySubsetMap),
    
    % The above subset detection approach counts duplicate communities as subsets of each other, so 
    % if we naively remove all subsets we'll eliminate duplicate communities. So, we need to filter 
    % out a single copy of any duplicate communities that are not subsets of anything else (i.e. all
    % of their supersets are just duplicates). 
    UniqueDuplicateCommunities = maps:fold(
        fun (SubsetCommunityId, SuperSetCommunities, UniqueCommunityList) ->
            % is this community a subset of one we have already locked in?
            AlreadyFound = lists:any(
                fun (UniqueCommunityId) ->
                    sets:is_element(UniqueCommunityId, SuperSetCommunities) 
                end,
                UniqueCommunityList),

            % are all of this community's supersets also subsets?
            IsJustDuplicate = not lists:any(
                fun (SuperSetCommunityId) ->
                    not sets:is_element(SubsetCommunityId, maps:get(SuperSetCommunityId, CommunitySubsetMap, sets:new()))
                end,
                sets:to_list(SuperSetCommunities)),
            
            case {AlreadyFound, IsJustDuplicate} of
                {true, _} -> UniqueCommunityList;
                {false, false} -> UniqueCommunityList;
                {false, true} -> [SubsetCommunityId | UniqueCommunityList]
            end
        end,
        [],
        CommunitySubsetMap),

    CleanSubsetCommunities = lists:subtract(SubsetCommunities, UniqueDuplicateCommunities),
    % ?dbg("DirtyCommunities: ~p~n SubsetIds ~p", [DirtyCommunities, SubsetCommunities]),
    ?INFO("After combining, ~p/~p communities are true subsets", [length(CleanSubsetCommunities), maps:size(DirtyCommunities)]),
    
    % final map of #{CommunityId => #{members => belonging}} with no subsets
    % If all are subsets, then just take random
    Communities = case length(CleanSubsetCommunities) =:= maps:size(DirtyCommunities) of
        true when length(CleanSubsetCommunities) > 1 -> 
            % ?dbg("before guess", []),
            [_ | TailSubsets] = CleanSubsetCommunities,
            % ?dbg("after guess", []),
            maps:without(TailSubsets, DirtyCommunities);
        true -> 
            DirtyCommunities;
        false ->
            maps:without(CleanSubsetCommunities, DirtyCommunities)
    end,

    % only include proper communities in final Uid labels
    ok = foreach_uid(fun (Uid, CurLabel, _) -> 
            finalize_label(Uid, CurLabel, Communities) 
        end), 

    % Now apply the updated community labels back into redis
    ok = foreach_uid_batch(batch_set_labels, [], BatchSize),
    ?INFO("CommunityDetection finalizing took ~p ms", [util:now_ms() - Start]),
    ?INFO("CommunityDetection resulted in ~p unique communities", 
        [maps:size(Communities)]),
    Communities.


-spec generate_friend_recommendations(Communities :: map(), non_neg_integer()) -> ok.
generate_friend_recommendations(_Communities, 0) -> ok;
generate_friend_recommendations(Communities, MaxNumRecs) ->
    Start = util:now_ms(),
    CommunityIdList = maps:keys(Communities),
    % Map of {uid => recommendationlist} where recommendations are sorted low to high
    RecommendationsMap = lists:foldl(
        fun (CommunityId, RecAcc) ->
            CommunityUids = maps:keys(maps:get(CommunityId, Communities)),
            CommunityRecommendations = find_community_friend_recommendations(CommunityUids),
            util:map_merge_with(
                fun (_Key, V1, V2) ->
                    lists:ukeymerge(2, V1, V2)
                end,
                RecAcc, CommunityRecommendations)
        end,
        #{},
        CommunityIdList),

    % Trim each uid's recommendation list to be no longer than MaxNumRecs
    RecommendationList = maps:fold(
        fun (Uid, Recommendations, Acc) ->
            RecommendationsInOrder = lists:reverse(Recommendations),
            TrimmedRecTuples = lists:sublist(RecommendationsInOrder, MaxNumRecs),
            TrimmedRecs = lists:map(
                fun ({OUid, _Strength}) ->
                    OUid
                end,
                TrimmedRecTuples),
            % Convert map into list of {Uid, Recommendations} tuples for storage in redis
            [{Uid, TrimmedRecs} | Acc]
        end,
        [],
        RecommendationsMap),
    
    % Store the recommendations in redis
    model_friends:set_friend_recommendations(RecommendationList),
    ?INFO("Community Friend Recommendations took ~p ms", [util:now_ms() - Start]),
    ok. 

-spec cleanup_community_detection() -> ok.
cleanup_community_detection() ->
    ?INFO("Starting CommunityDetectionCleanup"),
    ets:delete(?COMMUNITY_DATA_TABLE),
    wpool:stop_sup_pool(?COMMUNITY_WORKER_POOL),
    ?INFO("CommunityDetection cleanup successful"),
    ok.


%%====================================================================
%% Redis Helpers
%%====================================================================

-spec load_keys(non_neg_integer(), non_neg_integer(), node(), boolean()) -> integer().
load_keys(0, N, Node, _FreshStart) when N > 0 orelse Node == -1 -> 
    ?INFO("Done loading keys from Node ~p!", [Node]),
    N;
load_keys(Cursor, N, Node, FreshStart) ->
    {NewCur, BinKeys} = model_accounts:scan(Node, Cursor, ?SCAN_BLOCK_SIZE),
    Uids = lists:map(
        fun (BinKey) ->
            extract_uid(BinKey)
        end, BinKeys),
    {ok, FriendMap} = model_friends:get_friends(Uids),
    case {Uids, Cursor} of 
        {[], 0} -> N;
        _ -> lists:foreach(
                fun (Uid) -> 
                    Friends = remove_self_friend(Uid, maps:get(Uid, FriendMap)),
                    load_key(Uid, Friends, FreshStart) 
                end, 
                Uids),
            load_keys(NewCur, N+length(Uids), Node, FreshStart)
    end.

% * Called on each Uid -- Used to load Uid data from Redis into ETS
-spec load_key(binary(), [uid()], boolean())  -> boolean().
load_key(_Uid, [], _FreshStart) -> 
    false; %if no friends, don't add
load_key(Uid, _Friends, FreshStart) ->
    StartingLabel = case {Uid, FreshStart} of 
        {undefined, _} -> {error, "undefined Uid"};
        {_, true} -> #{Uid => 1.0};
        {_, false} -> model_accounts:get_community_label(Uid)
    end,
    case StartingLabel of
        {error, Info} -> ?INFO("Warning: Not adding ~p; Info: ~p", [Uid, Info]), false;
        undefined -> 
            ?INFO("Warning: undefined starting label for uid ~p; giving self-label", [Uid]),
            ets:insert_new(?COMMUNITY_DATA_TABLE, {label_key(Uid), #{Uid => 1.0}, #{}}); %idempotent
        _ -> ets:insert_new(?COMMUNITY_DATA_TABLE, {label_key(Uid), StartingLabel, #{}}) %idempotent
    end.

extract_uid(BinKey) ->
    Result = re:run(BinKey, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            Uid;
        _ -> <<"">>
    end.

-spec batch_set_labels(pid(), [list()]) -> ok | {error | any()}.
batch_set_labels(ParentPid, MatchList) ->
    UidLabelTuples = lists:map(
        fun ([Uid, CurLabel, _NewLabel]) ->
            {Uid, CurLabel}
        end,
        MatchList),
    model_accounts:set_community_labels(UidLabelTuples),
    ParentPid ! {done, self()},
    ok.

-spec get_all_friends(FriendList :: [uid()]) -> #{uid() => atom()}.
get_all_friends(FriendList) ->
    % in this case don't care about deleted or self friends because only checking existence of 
    % specific uid
    {ok, FoFMap} = model_friends:get_friends(FriendList),
    % TODO (luke, erl24) Just use from_keys on a combined FriendofFriend list
    maps:fold(
        fun (Buid, BuidFriends, AccMap) ->
            BuidFriendMap = lists:foldl(
                fun (Buid2, AccMap2) ->
                    maps:update_with(
                        Buid2, 
                        fun (N) ->
                            N + 1
                        end, 
                        1, 
                        AccMap2)
                end,
                #{},
                BuidFriends),
            AddBuid = maps:update_with(
                Buid, 
                fun (N) ->
                    N + 1
                end, 
                1, 
                AccMap),
            maps:merge(BuidFriendMap, AddBuid) 
        end,
        #{},
        FoFMap).


%%====================================================================
%% Label Propagation Functions
%%====================================================================

% Calls propagate/3 for all uids in a batch (to limit redis calls)
-spec batch_propagate(ParentPid :: pid(), MatchList :: list(), MaxNumCommunities :: pos_integer()) -> ok | {error, any()}.
batch_propagate(ParentPid, MatchList, MaxNumCommunities) ->
    Uids = lists:map(
        fun ([Uid, _CurLabel, _NewLabel]) -> 
            Uid 
        end, 
        MatchList),
    {ok, Friends} = model_friends:get_friends(Uids),
    % ?dbg("Got batch for ~p -> ~p", [Uids, Friends]),

    % Propagate labels for all uids
    lists:foreach(
        fun (Uid) -> 
            RealFriends = remove_self_friend(Uid, maps:get(Uid, Friends)), %if undefined return []
            propagate(Uid, RealFriends, MaxNumCommunities) 
        end, 
        Uids),
    ParentPid ! {done, self()},
    ok.


% * Called on each Uid -- Used to calculate next label for each node
-spec propagate(uid(), FriendList :: [uid()], MaxNumCommunities :: pos_integer()) -> ok | {error, any()}.
propagate(Uid, [], _MaxNumCommunities) -> 
    ?INFO("WARNING: Uid ~p has no real/non-self friends -- this shouldn't happen", [Uid]),
    ets:delete(?COMMUNITY_DATA_TABLE, label_key(Uid));
propagate(Uid, FriendList, MaxNumCommunities) ->
    % ?dbg("Updating label for ~p", [Uid]),
    % ?dbg("  Friends: ~p", [FriendList]),
    FriendLabels = get_friend_labels(FriendList),
    
    % combine labels of all friends by summing each communities belonging coeff
    FriendLabelUnion = lists:foldl(
        fun(FriendLabel, Acc) ->
            util:map_merge_with(
                fun(_CommunityId, BNew, BCur) -> 
                    BNew + BCur 
                end, 
                FriendLabel, 
                Acc)
        end, #{}, FriendLabels),

    CloseKnitLabel = remove_distant_community_ids(FriendList, FriendLabelUnion),

    NormDirtyLabel = normalize_label(CloseKnitLabel),

    % remove all communities from label with belong_coeff < 1/MaxNumCommunities
    %   Basically just trim to limit the number of communities
    CleanThreshold = 1.0 / MaxNumCommunities,
    CleanLabel = maps:filter(fun(_CommunityId, B) -> 
                                B >= CleanThreshold 
                            end, 
                            NormDirtyLabel),
    % ?dbg("  Threshold: ~p~n  CleanLabel: ~p", [CleanThreshold, CleanLabel]),
    NewLabel = case maps:size(CleanLabel) > 0 of
        true -> normalize_label(CleanLabel);
        false -> #{strongest_community_id(NormDirtyLabel) => 1.0} % if all are < threshold, pick highest B
    end,

    case ets:update_element(?COMMUNITY_DATA_TABLE, label_key(Uid), {?NEW_LABEL_POS, NewLabel}) of
        true -> 
            % ?dbg("set ~p's new label to ~p", [Uid, NewLabel]),
            ok;
        false -> 
            % ?dbg("ERROR: couldn't set ~p's label to ~p", [Uid, NewLabel]),
            {error, "Element not found"}    
    end.

% * Used to generate data for termination condition
-spec get_community_membership_counts() -> {map(), map()}.
get_community_membership_counts() ->
    fold_all_uids(
        fun(_Uid, CurLabel, NewLabel, Acc) -> 
            get_community_membership_counts_acc(CurLabel, NewLabel, Acc) 
        end, {#{}, #{}}).


% * Called on each Uid's labels -- Used to accumulate data to find the membership count of 
% * active communities
-spec get_community_membership_counts_acc(community_label(), community_label(), {map(), map()}) -> 
        {map(), map()}.
get_community_membership_counts_acc(CurLabel, NewLabel, {OldAcc, NewAcc}) ->
    OldCommunityIdCount = maps:map(fun(CommunityId, _BCur) -> 
                                        maps:get(CommunityId, OldAcc, 0) + 1
                                   end, 
                                   CurLabel),

    NewCommunityIdCount = maps:map(fun(CommunityId, _BCur) -> 
                                        maps:get(CommunityId, NewAcc, 0) + 1
                                   end, 
                                   NewLabel),
    OldAcc1 = maps:merge(OldAcc, OldCommunityIdCount),
    NewAcc1 = maps:merge(NewAcc, NewCommunityIdCount),
    {OldAcc1, NewAcc1}.


% * Used to calculate termination condition
-spec min_counts(map(), map()) -> map().
min_counts(CommunityIdCount1, CommunityIdCount2) ->
    case maps:size(CommunityIdCount1) =:= 0 of
        true -> CommunityIdCount2;
        false ->
            Min = fun (_CommunityId, B1, B2) -> 
                    min(B1, B2) 
                end,
            util:map_intersect_with(Min, CommunityIdCount1, CommunityIdCount2)
    end.


% * Ensures that each node's belonging coefficients sum to 1
-spec normalize_label(community_label()) -> community_label().
normalize_label(Label) ->
    Sum = maps:fold(fun(_CommunityId, Value, Acc) -> 
                        Acc + Value 
                    end, 
                    0, Label),
    Div = fun(_CommunityId, B) -> B / Sum end,
    maps:map(Div, Label).


% * Called on each Uid -- Used to remove communities that are subsets of other communities
-spec identify_community_subsets(uid(), community_label(), {map(), map()}) -> {map(), map()}.
identify_community_subsets(Uid, CurLabel, {Communities, Subsets}) ->
    % ?dbg("POSTPROCESS CurLabel: ~p", [CurLabel]),
    LabelList = maps:to_list(CurLabel),
    lists:foldl(fun ({CommunityId, B}, {CommunityMap, CommunitySubsetsMap}) ->
                    case maps:is_key(CommunityId, CommunityMap) of
                        true -> 
                                CommunityMembers = maps:get(CommunityId, CommunityMap),
                                CommunitySubsets = maps:get(CommunityId, CommunitySubsetsMap),
                                UidCommunitiesSet = sets:del_element(
                                    CommunityId, 
                                    sets:from_list(maps:keys(CurLabel))),
                                {   
                                    CommunityMap#{CommunityId := CommunityMembers#{Uid => B}}, 
                                    CommunitySubsetsMap#{CommunityId := sets:intersection(
                                        CommunitySubsets, UidCommunitiesSet)}
                                };
                        false ->
                                {
                                    CommunityMap#{CommunityId => #{Uid => B}}, 
                                    CommunitySubsetsMap#{CommunityId => sets:from_list(maps:keys(CurLabel))}
                                }
                    end
                end, 
                {Communities, Subsets}, LabelList).


% * Called on each Uid -- Trims Label to only include final communities, renormalizes, and then applies to ETS
-spec finalize_label(uid(), community_label(), map()) -> community_label().
finalize_label(Uid, CurLabel, Communities) ->
    PrunedLabel = maps:filter(fun (CommunityId, _B) -> 
                                    maps:is_key(CommunityId, Communities) 
                                end, 
                                CurLabel),
    FinalLabel = case maps:size(PrunedLabel) > 0 of
            true -> normalize_label(PrunedLabel);
            false -> 
                ?INFO("  ~p was only part of subsets so giving self label! Curlabel: ~p ", [Uid, CurLabel]),
                #{Uid => 1.0}
        end,
    case ets:update_element(?COMMUNITY_DATA_TABLE, label_key(Uid), {?NEW_LABEL_POS, FinalLabel}) of
        true -> apply_new_label(Uid, FinalLabel), 
                FinalLabel;
        false -> FinalLabel
    end.


%%====================================================================
%% Label Propagation Helper Functions
%%====================================================================

-spec apply_new_label(uid(), community_label()) -> boolean().
apply_new_label(Uid, NewLabel) ->
    % ?dbg("Updating ~p's label to ~p", [Uid, NewLabel]),
    ets:update_element(?COMMUNITY_DATA_TABLE, label_key(Uid), {?CUR_LABEL_POS, NewLabel}).

-spec strongest_community_id(community_label()) -> uid().
strongest_community_id(Label) ->
    {CommunityId, _B} = maps:fold(fun(CommunityId, B, {CurCommunityId, CurB}) ->
                                        case B > CurB of
                                            true -> {CommunityId, B};
                                            false -> {CurCommunityId, CurB}
                                        end
                                    end, 
                                    {undefined, 0}, Label),
    CommunityId.

-spec remove_self_friend(Uid :: uid(), Friends :: [uid()]) -> [uid()].
remove_self_friend(Uid, Friends) ->
    lists:filter( 
        fun (Buid) -> 
            Buid =/= Uid
        end, 
        Friends).
    

-spec get_friend_labels([uid()]) -> [community_label()].
get_friend_labels([]) -> [];
get_friend_labels(Uids) ->
    lists:map(fun(Uid) -> 
                    Labels = ets:lookup(?COMMUNITY_DATA_TABLE, label_key(Uid)),
                    case Labels of
                        [{{labelinfo, _Uid}, CurLabel, _NewLabel}] -> CurLabel;
                        Other -> 
                            ?INFO("ERROR: Couldn't find friend ~p label!! Got ~p instead", [Uid, Other]),
                            #{}
                    end
              end, 
              Uids).


% Filters out all community ids that are not friends of the given friend list
% Used to limit community sharing to ensure that a uid can only join a community if the id of that 
%   community shares a mutual friend -- in future could edit to require more mutual friends
-spec remove_distant_community_ids([uid()], community_label()) -> map().
remove_distant_community_ids(FriendsList, LabelMap) ->
    FriendsOfFriendsMap = get_all_friends(FriendsList),
    maps:filter(
        fun (CommunityId, _B) -> 
            maps:get(CommunityId, FriendsOfFriendsMap, -1) > 0
        end,
        LabelMap).



-spec batch_combine_small_clusters(ParentPid :: pid(), MatchList :: list(), ClusterSizeThreshold :: pos_integer()) -> ok | {error, any()}.
batch_combine_small_clusters(ParentPid, MatchList, ClusterSizeThreshold) ->
    Start = util:now_ms(),
    Uids = lists:map(
        fun ([Uid, _CurLabel, _NewLabel]) -> 
            Uid 
        end, 
        MatchList),
    {ok, DirtyFriends} = model_friends:get_friends(Uids),
    % ?dbg("Got batch for ~p -> ~p", [MatchList, Friends]),
    NumCombined = lists:foldl(
        fun (Uid, Acc) -> 
            MyFriends = remove_self_friend(Uid, maps:get(Uid, DirtyFriends)),
            case combine_small_clusters(Uid, MyFriends, ClusterSizeThreshold) of
                ok -> Acc;
                _ -> Acc + 1
            end
        end, 
        0,
        Uids),
    ?INFO("~p forced ~p uids into communities in ~p ms", [self(), NumCombined, util:now_ms() - Start]),
    ParentPid ! {done, self()},
    ok.

combine_small_clusters(Uid, Friends, ClusterSizeThreshold) ->
    % ?dbg("---Cleaning ~p", [Uid]),
    [StartUid | Unvisited] = Friends,
    {IsLargeCluster, ClusterUids} = is_not_isolated(StartUid, Unvisited, [Uid], ClusterSizeThreshold),
    
    case IsLargeCluster of
        true -> ok;
        false ->
            [Leader | _SortedUids] = lists:sort(ClusterUids),
            ets:update_element(?COMMUNITY_DATA_TABLE, label_key(Uid), {?CUR_LABEL_POS, #{Leader => 1.0}}),
            ets:update_element(?COMMUNITY_DATA_TABLE, label_key(Uid), {?NEW_LABEL_POS, #{Leader => 1.0}}),
            ClusterUids
    end.

-spec is_not_isolated(Uid :: uid(), Unvisited :: [uid()], CurMembers :: [uid()], MinSize :: non_neg_integer()) -> {boolean(), [uid()]}.
is_not_isolated(Uid, _Unvisited, CurMembers, MinSize) when length(CurMembers) + 1 >= MinSize -> 
    {true, [Uid | CurMembers]};

is_not_isolated(Uid, Unvisited, CurMembers, MinSize) ->
    % ?dbg("checking ~p, unvisited: ~p, Curmembers: ~p", [Uid, Unvisited, CurMembers]),
    {ok, DirtyFriends} = model_friends:get_friends(Uid),
    Friends = remove_self_friend(Uid, DirtyFriends),
    NewFriends = sets:subtract(sets:from_list(Friends), sets:from_list(CurMembers)),
    NewUnvisited = sets:to_list(sets:union(NewFriends, sets:from_list(Unvisited))),
    
    case NewUnvisited of
        [] -> % if there are no more uids to visit, then we have our final cluster to check
            RetMembers = [Uid | CurMembers],
            % ?dbg("Found Disjoint community: ~p", [lists:sort(RetMembers)]),
            {length(RetMembers) >= MinSize, RetMembers};
        _ -> 
            [NextUid | NextUnvisited] = NewUnvisited,
            NewMembers = case lists:member(Uid, CurMembers) of
                true -> CurMembers;
                false -> [Uid | CurMembers]
            end,
            is_not_isolated(NextUid, NextUnvisited, NewMembers, MinSize)
    end.

    
% Calls Func on each key of the table. Func must have form -spec fun (Uid, CurLabel, NewLabel) -> ok
-spec foreach_uid(Func :: atom()) -> ok | {error, any()}.
foreach_uid(Func) ->
    ets:safe_fixtable(?COMMUNITY_DATA_TABLE, true),
    Matches = ets:match(?COMMUNITY_DATA_TABLE, {{labelinfo, '$1'}, '$2', '$3'}, ?MATCH_CHUNK_SIZE),

    do_for(Matches, Func),
    ets:safe_fixtable(?COMMUNITY_DATA_TABLE, false),
    ok.

do_for('$end_of_table', _) -> ok; 
do_for({EntryList, Cont}, Func) -> 
    lists:foreach(fun ([Uid, CurLabel, NewLabel]) -> 
                        Func(Uid, CurLabel, NewLabel) 
                  end, 
                  EntryList), 
    do_for(ets:match(Cont), Func).

% Calls Func on each key of the table. Must take (Uid, CurLabel, NewLabel, Accumulator) as input and
% return an updated accumulator to be passed to the next iteration
-spec fold_all_uids(Func :: atom(), Acc :: term()) -> term() | {error, any()}.
fold_all_uids(Func, AccInit) ->
    ets:safe_fixtable(?COMMUNITY_DATA_TABLE, true),
    Matches = ets:match(?COMMUNITY_DATA_TABLE, {{labelinfo, '$1'}, '$2', '$3'}, ?MATCH_CHUNK_SIZE),

    AccFinal = do_for_acc(Matches, Func, AccInit),
    ets:safe_fixtable(?COMMUNITY_DATA_TABLE, false),
    AccFinal.

do_for_acc('$end_of_table', _Func, Acc) -> Acc; 
do_for_acc({EntryList, Cont}, Func, Acc) -> 
    Acc1 = lists:foldl(fun ([Uid, CurLabel, NewLabel], AccIn) -> 
                            Func(Uid, CurLabel, NewLabel, AccIn) 
                        end, 
                        Acc, EntryList), 
    do_for_acc(ets:match(Cont), Func, Acc1).


% Calls func on batches of keys, func needs to take list of [Uid, CurLabel, NewLabel]
% Used to batch calls to redis
-spec foreach_uid_batch(Func :: atom(), Args :: list(), 
        BatchSize :: pos_integer()) -> ok | {error, any()}.
foreach_uid_batch(Func, Args, BatchSize) ->
    % Start = util:now_ms(),
    ets:safe_fixtable(?COMMUNITY_DATA_TABLE, true),
    Matches = ets:match(?COMMUNITY_DATA_TABLE, {{labelinfo, '$1'}, '$2', '$3'}, BatchSize),

    do_for_batch(Matches, Func, Args, 0),
    ets:safe_fixtable(?COMMUNITY_DATA_TABLE, false),

    % ?INFO("Batch propagation took ~p ms", [util:now_ms() - Start]),
    ok.

do_for_batch('$end_of_table', _Func, _Args, 0) ->  
    % ?dbg("----Done with BatchPropagate!---", []), 
    ok; 
do_for_batch('$end_of_table', Func, Args, NumChildren) -> 
    % ?INFO("STATS: ~p", [wpool:stats(?COMMUNITY_WORKER_POOL)]), 
    receive
        {done, _WorkerPid} -> 
            % case (NumChildren - 1) rem 10 of % log every 10th to avoid too many logs
            %     0 -> ?INFO("Worker ~p finished! ~p remaining", [WorkerPid, NumChildren - 1]);
            %     _ -> ok
            % end,
            do_for_batch('$end_of_table', Func, Args, NumChildren - 1)
    end,
    ok; 

do_for_batch({EntryList, Cont}, Func, Args, NumChildren) -> 
    wpool:cast(?COMMUNITY_WORKER_POOL, {?MODULE, Func, [self(), EntryList] ++ Args}, ?COMMUNITY_POOL_STRATEGY),
    % case NumChildren rem 10 of % log every 10th to avoid too many logs
    %     0 -> ?INFO("Spawned worker #~p to work on batch of size ~p", [NumChildren + 1, length(EntryList)]);
    %     _ -> ok
    % end,
    do_for_batch(ets:match(Cont), Func, Args, NumChildren + 1).


label_key(Uid) -> {labelinfo, Uid}.


%%====================================================================
%% Friend Recommendation Helper Functions
%%====================================================================


% Friend Recommendations sort by "connection strength" low to high, currently calculated as number of mutual friends
-spec find_community_friend_recommendations([uid()]) -> #{uid() => [uid()]}.
find_community_friend_recommendations(CommunityUids) ->
    {ok, FriendsMap} = model_friends:get_friends(CommunityUids),

    % Initialize accumulator with keys corresponding to all uids in the community
    % This initialization is used in find_friend_recommendations to be able to fold over all 
    % members of the community to calculate connection strength
    {FriendConnectionMap, CleanFriendsMap} = maps:fold(
        fun (Uid, FriendsList, {AccConnectionMap, AccFriendMap}) ->
            CleanFriendsList = remove_self_friend(Uid, FriendsList),
            ConnectionMap = util:map_from_keys(CleanFriendsList, undefined),
            {AccConnectionMap#{Uid => ConnectionMap}, AccFriendMap#{Uid => CleanFriendsList}}
            
        end,
        {#{}, #{}},
        FriendsMap),

    % Recommendation map maps each uid to a map of all potential recommendations and their connection strength
    % #{uid => #{buid => connectionstrength}}
    RecommendationMap = lists:foldl(
        fun (Uid, RecommendationMapAcc) ->
            % Calculate connection strength between Uid and all other community members
            UidRecommendationMap = find_friend_recommendations(Uid, CleanFriendsMap, RecommendationMapAcc),
            RecommendationMapAcc#{Uid => UidRecommendationMap}
        end,
        FriendConnectionMap,
        CommunityUids),

    % now sort recommendation lists by connection strength and return a map of uids to their
    % recommendations
    TruncRecommendationMap = maps:map(
        fun (_Uid, UidConnectionMap) ->
            UidConnectionList = maps:to_list(UidConnectionMap),
            % return just list of {uid, strength} tuples sorted by connection strength
            lists:keysort(2, UidConnectionList)
            
        end,
        RecommendationMap),

    TruncRecommendationMap.

% find recommendations for a single uid
-spec find_friend_recommendations(uid(), #{uid() => [uid()]}, map()) -> #{uid() => integer()}.
find_friend_recommendations(Uid, FriendMap, RecommendationMap) ->
    % calculate connection strength to every other non-friend uid in the community
    UidRecommendationMap = maps:fold(
        fun (Buid, _BuidRecommendationMap, RecommendationMapAcc) when Buid =:= Uid -> RecommendationMapAcc; 
            (Buid, BuidRecommendationMap, RecommendationMapAcc) ->
            IsFriend = lists:member(Buid, maps:get(Uid, FriendMap)),
            BuidConnectionStrength = maps:get(Uid, BuidRecommendationMap, undefined),

            % if Uid & Buid are friends or if connection strength has already been calculated, just 
            % use that value instead of recomputing
            ConnStrength = case {IsFriend, BuidConnectionStrength} of 
                {true, _} -> alreadyfriends;                
                {false, undefined} -> % connection strength has not been calculated
                    MyFriends = maps:get(Uid, FriendMap),
                    BuidFriends = maps:get(Buid, FriendMap),
                    get_connection_strength(MyFriends, BuidFriends);
                {false, Strength} -> Strength
            end,
            case ConnStrength of
                alreadyfriends -> RecommendationMapAcc; % dont recommend/connect if already friends
                _ -> maps:put(Buid, ConnStrength, RecommendationMapAcc)
            end
        end,
        #{},
        RecommendationMap),
    
    UidRecommendationMap.

-spec get_connection_strength(UidFriends :: [uid()], BuidFriends :: [uid()]) -> integer().
get_connection_strength(UidFriends, BuidFriends) ->
    sets:size(sets:intersection(sets:from_list(UidFriends), sets:from_list(BuidFriends))).

