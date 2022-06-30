%%%-------------------------------------------------------------------
%%% @author luke
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 16. Jun 2022 12:44 PM
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
    compute_communities/1,
    batch_propagate/3,
    load_key/2
]).

% For debugging single step purposes
-export([
    community_detection_setup/2,
    identify_communities/4,
    single_step_label_propagation/3,
    apply_single_step_labels/0,
    community_detection_finish_and_cleanup/0
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
    %% Acc has format #{singleton => {NumSingleton, SingletonList}, 
    %%                  five_to_ten => {NumSizeFiveToTen, SizeFiveToTenList}, 
    %%                  more_than_ten => {NumSizeLargerThan10, SizeLargerThan10List}}
    AccInit = #{singleton => {0, []}, five_to_ten => {0, []}, more_than_ten => {0, []}},
    Res = maps:fold(
        fun community_fold_fun/3, 
        AccInit, 
        Communities),
    Res.


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
%% This module implements a community detection algorithm using label propagation following 
%% Steve Gregory's 2010 paper (doi: https://doi.org/10.1088/1367-2630/12/10/103018) 
%% The basic idea is to start with each node in its own community, and then iteratively assign it 
%% the communities held by the majority of its neighbors (i.e. if 4 of node 1's friends are in 
%% community 7 and 3 friends are in community 6, then node 1 will join community 7). This specific 
%% version of the algorithm was chosen because it allows for nodes to be a part of multiple 
%% communities, which often occurs in social networks. The specific number of communities a node is 
%% able to be a part of is configurable using the DEFAULT_MAX_COMMUNITIES macro in community.hrl or 
%% as the input to compute_communities/1


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
    
    NumWorkers = get_option(num_workers, ?COMMUNITY_DEFAULT_NUM_WORKERS, RunOpts),
    FreshStart = get_option(fresh_start, false, RunOpts),
    MaxNumCommunities = get_option(max_communities_per_node, ?DEFAULT_MAX_COMMUNITIES, RunOpts),
    MaxIters = get_option(max_iters, ?DEFAULT_MAXIMUM_ITERATIONS, RunOpts),
    BatchSize = get_option(batch_size, ?MATCH_CHUNK_SIZE, RunOpts),
    
    % setup ets table 
    community_detection_setup(NumWorkers, FreshStart),

    % Next, run the community detection algorithm
    {PrevMin, NumIters} = identify_communities(#{}, MaxNumCommunities, BatchSize, {0, MaxIters}),

    Success = PrevMin =:= #{},
    % post-process communities and clean up ets
    Communities = community_detection_finish_and_cleanup(),

    case Success of 
        true ->
            ?INFO("-----Community detection finished in ~p iterations, finding ~p unique communities-----",
                [NumIters, maps:size(Communities)]);
        false ->
            ?INFO("Community Detection was unsuccessful, ending at ~p iterations with ~p unique communities",
                [NumIters, maps:size(Communities)])
    end,

    {NumIters, Communities}.


% * Initialize Ets table for label propagation
-spec community_detection_setup(pos_integer(), boolean()) -> ok.
community_detection_setup(NumWorkers, FreshStart) -> 
    ?INFO("Setting up for community detection using ~p workers. Starting fresh: ~p", [NumWorkers, FreshStart]),
    Start = util:now_ms(),

    WorkerPoolOptions = [{workers, NumWorkers}],
    wpool:start_sup_pool(?COMMUNITY_WORKER_POOL, WorkerPoolOptions),
    % Make a new table for storing node information
    % Elem structure is {{labelinfo, Uid}, Old_Label, New_Label}
    ets:new(?COMMUNITY_DATA_TABLE, [named_table, public]),

    % first, dump information from Redis into ets
    % TODO (luke) This can be parallelized for each Node -- insertion into ets is thread-safe
    Nodes = model_accounts:get_node_list(),
    lists:foreach(fun (Node) -> 
                        load_keys(0, 0, Node, FreshStart)
                  end, Nodes),

    ?INFO("Label Propagation Initialization took ~p ms", [util:now_ms() - Start]),
    ok.


% * Do a single round of calculating new labels
-spec single_step_label_propagation(PrevMin :: map(), MaxNumCommunities :: pos_integer(), 
        BatchSize :: pos_integer()) -> {map(), boolean()}.
single_step_label_propagation(PrevMin, MaxNumCommunities, BatchSize) ->
    Start = util:now_ms(),
    % ?dbg("----------", []),
    % calculate new labels for each node in parallel batches of size ?MATCH_CHUNK_SIZE
    foreach_uid_batch_propagate(MaxNumCommunities, BatchSize),

    % check termination condition
    {OldCommunityIdCounts, NewCommunityIdCounts} = get_community_membership_counts(),
    CombinedCommunityIds = maps:merge(OldCommunityIdCounts, NewCommunityIdCounts),

    % The number of CommunityIds in use decreases monotonically, so this reflects 
    % OldCommunityIdCounts != NewCommunityIdCounts
    MinCommunityIdCounts = case maps:size(CombinedCommunityIds) > maps:size(NewCommunityIdCounts) of 
        true -> NewCommunityIdCounts;
        false -> min_counts(PrevMin, NewCommunityIdCounts)
    end,
    Continue = MinCommunityIdCounts =/= PrevMin,
    % ?dbg("Continue? ~p -- Min ~p , PrevMin ~p", [Continue, MinCommunityIdCounts, PrevMin]),
    ?INFO("Label Propagation single iteration found ~p communities in ~p ms", 
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
    ?INFO("Label Propagation applying labels took ~p ms", [util:now_ms() - Start]).


% * finalize list of non-subset communities, store in redis, and cleanup resources
-spec community_detection_finish_and_cleanup() -> map().
community_detection_finish_and_cleanup() ->
    Start = util:now_ms(),
    % Now post processing to clean up the community set and remove communities that are subsets of others
    {DirtyCommunities, SubsetMap} = foreach_uid_acc(
        fun (Uid, CurLabel, _NewLabel, Acc) -> 
            identify_community_subsets(Uid, CurLabel, Acc) 
        end, {#{}, #{}}),
    CommunitySubsets = maps:keys(maps:filter(
        fun  (_, #{}) -> false; %filter out empty maps to get only meaningful subsets
             (_, _) -> true 
        end, SubsetMap)),
    
    % final map of #{communities => #{members => belonging}} with no subsets
    Communities = maps:without(CommunitySubsets, DirtyCommunities), 
    
    % only include proper communities in final Uid labels
    ok = foreach_uid(fun (Uid, CurLabel, _) -> 
            finalize_label(Uid, CurLabel, Communities) 
        end), 

    % Now apply the updated community labels back into redis
    ok = foreach_uid(fun (Uid, CurLabel, _) -> 
            model_accounts:set_community_label(Uid, CurLabel) 
        end),

    ets:delete(?COMMUNITY_DATA_TABLE),
    wpool:stop_sup_pool(?COMMUNITY_WORKER_POOL),

    ?INFO("Label Propagation cleanup took ~p ms", [util:now_ms() - Start]),
    ?INFO("Label propagation resulted in ~p unique communities", 
        [maps:size(Communities)]),
    Communities.


%%====================================================================
%% Redis Migration Helpers
%%====================================================================

-spec load_keys(non_neg_integer(), non_neg_integer(), node(), boolean()) -> integer().
load_keys(0, N, Node, _FreshStart) when N > 0 orelse Node == -1 -> N;
load_keys(Cursor, N, Node, FreshStart) ->
    {NewCur, Uids} = model_accounts:scan(Node, Cursor, ?SCAN_BLOCK_SIZE),
    case {Uids, Cursor} of 
        {[], 0} -> N;
        _ -> lists:foreach(fun (Uid) -> load_key(Uid, FreshStart) end, Uids),
            load_keys(NewCur, N+length(Uids), Node, FreshStart)
    end.

% * Called on each Uid -- Used to load Uid data from Redis into ETS
-spec load_key(binary(), boolean())  -> boolean().
load_key(BinKey, FreshStart) ->
    IsValid = is_valid_account_key(BinKey),
    Uid = case IsValid of
        true -> extract_uid(BinKey);
        false -> undefined
    end,
    StartingLabel = case {Uid, FreshStart} of 
        {undefined, _} -> undefined;
        {_, true} -> #{Uid => 1.0};
        {_, false} -> model_accounts:get_community_label(Uid)
    end,
    case StartingLabel of
        undefined -> ets:insert_new(?COMMUNITY_DATA_TABLE, {{labelinfo, Uid}, #{Uid => 1.0}, #{}}); %idempotent
        _ -> ets:insert_new(?COMMUNITY_DATA_TABLE, {{labelinfo, Uid}, StartingLabel, #{}}) %idempotent
    end.

-spec is_valid_account_key(binary()) -> boolean().
is_valid_account_key(BinKey) ->
    GoodPrefix = binary:longest_common_prefix([BinKey, ?ACCOUNT_KEY]) == byte_size(?ACCOUNT_KEY),
    GoodLength = byte_size(BinKey) > byte_size(?ACCOUNT_KEY) + 3, % This 3 is the {} plus >= one more for the uid
    GoodPrefix andalso GoodLength.

extract_uid(BinKey) ->
    [?ACCOUNT_KEY, Uid] = binary:split(BinKey, [<<"{">>, <<"}">>], [trim_all, global]),
    Uid.


%%====================================================================
%% Label Propagation Functions
%%====================================================================

% * Main loop of label propagation algorithm:
% * Propagates new labels and then checks termination condition
-spec identify_communities(PrevMin :: map(), MaxNumCommunities :: pos_integer(), BatchSize :: pos_integer(),
        {IterNum :: non_neg_integer(), MaxIters :: non_neg_integer()}) -> non_neg_integer().
identify_communities(PrevMin, _MaxNumCommunities, _BatchSize, {MaxIters, MaxIters}) ->
    ?INFO("Community identification reached maximum iteration limit of ~p", [MaxIters]),
    {PrevMin, MaxIters}; % return map that can be used to continue computation
identify_communities(PrevMin, MaxNumCommunities, BatchSize, {IterNum, MaxIters}) ->
    % Do an iteration of label propagation
    ?INFO("Iteration ~p/~p", [IterNum + 1, MaxIters]),
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
                                {   
                                    CommunityMap#{CommunityId := CommunityMembers#{Uid => B}}, 
                                    CommunitySubsetsMap#{CommunityId := util:map_intersect(CommunitySubsets, CurLabel)} 
                                };
                        false ->
                                {
                                    CommunityMap#{CommunityId => #{Uid => B}}, 
                                    CommunitySubsetsMap#{CommunityId => CurLabel}
                                }
                    end
                end, 
                {Communities, Subsets}, LabelList).


-spec batch_propagate(ParentPid :: pid(), MatchList :: list(), MaxNumCommunities :: pos_integer()) -> ok | {error, any()}.
batch_propagate(ParentPid, MatchList, MaxNumCommunities) ->
    Uids = lists:map(
        fun ([Uid, _CurLabel, _NewLabel]) -> 
            Uid 
        end, 
        MatchList),
    {ok, Friends} = model_friends:get_friends_multi(Uids),
    % ?dbg("Got batch for ~p -> ~p", [MatchList, Friends]),
    lists:foreach(
        fun (Uid) -> 
            NoSelfFriend = lists:filter(
                fun (Buid) -> 
                    Buid =/= Uid
                end, 
                maps:get(Uid, Friends, [])),
            propagate(Uid, NoSelfFriend, MaxNumCommunities) 
        end, 
        Uids),
    ParentPid ! {done, self()},
    ok.

% * Called on each Uid -- Used to calculate next label for each node
-spec propagate(uid(), FriendList :: [uid()], MaxNumCommunities :: pos_integer()) -> ok | {error, any()}.
propagate(Uid, [], MaxNumCommunities) -> % If no friends, be own friend
    propagate(Uid, [Uid], MaxNumCommunities);

propagate(Uid, FriendList, MaxNumCommunities) ->
    % ?dbg("---------------------- Updating label for ~p--------------------------", [Uid]),
    % ?dbg("Friends: ~p", [FriendList]),
    FriendLabels = get_friend_labels(FriendList),

    % combine labels of all friends by summing each communities belonging coeff
    FriendLabelUnion = lists:foldl(
        fun(FriendLabel, Acc) ->
            util:map_merge_with(fun(_CommunityId, BNew, BCur) -> BNew + BCur end, FriendLabel, Acc)
        end, #{}, FriendLabels),

    NormDirtyLabel = normalize_label(FriendLabelUnion),

    % remove all communities from label with belong_coeff < 1/MaxNumCommunities
    CleanThreshold = 1.0 / MaxNumCommunities,
    CleanLabel = maps:filter(fun(_CommunityId, B) -> 
                                B >= CleanThreshold 
                            end, 
                            NormDirtyLabel),

    NewLabel = case maps:size(CleanLabel) > 0 of
        true -> normalize_label(CleanLabel);
        false -> #{strongest_community_id(NormDirtyLabel) => 1.0} % if all are < threshold, pick highest B
    end,

    case ets:update_element(?COMMUNITY_DATA_TABLE, {labelinfo, Uid}, {?NEW_LABEL_POS, NewLabel}) of
        true -> ok;
        false -> {error, "Element not found"}    
    end.

% * Used to generate data for termination condition
-spec get_community_membership_counts() -> {map(), map()}.
get_community_membership_counts() ->
    foreach_uid_acc(
        fun(_Uid, CurLabel, NewLabel, Acc) -> 
            get_community_membership_counts_acc(CurLabel, NewLabel, Acc) 
        end, {#{}, #{}}).

% * Called on each Uid's labels -- Used to accumulate data to find active communities
-spec get_community_membership_counts_acc(community_label(), community_label(), {map(), map()}) -> {map(), map()}.
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
    Min = fun (_CommunityId, B1, B2) -> 
              min(B1, B2) 
          end,
    util:map_intersect_with(Min, CommunityIdCount1, CommunityIdCount2).

% * Ensures that each node's belonging coefficients sum to 1
-spec normalize_label(community_label()) -> community_label().
normalize_label(Label) ->
    Sum = maps:fold(fun(_CommunityId, Value, Acc) -> 
                        Acc + Value 
                    end, 
                    0, Label),
    Div = fun(_CommunityId, B) -> B / Sum end,
    maps:map(Div, Label).

% * Called on each Uid -- Trims Label to only include final communities, renormalizes, and then applies to ETS
-spec finalize_label(uid(), community_label(), map()) -> community_label().
finalize_label(Uid, CurLabel, Communities) ->
    PrunedLabel = maps:filter(fun (CommunityId, _B) -> 
                                    maps:is_key(CommunityId, Communities) 
                                end, 
                                CurLabel),
    FinalLabel = normalize_label(PrunedLabel),
    case ets:update_element(?COMMUNITY_DATA_TABLE, {labelinfo, Uid}, {?NEW_LABEL_POS, FinalLabel}) of
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
    ets:update_element(?COMMUNITY_DATA_TABLE, {labelinfo, Uid}, {?CUR_LABEL_POS, NewLabel}).

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


-spec get_friend_labels([uid()]) -> [community_label()].
get_friend_labels([]) -> [];
get_friend_labels(Uids) ->
    lists:map(fun(Uid) -> 
                    Labels = ets:lookup(?COMMUNITY_DATA_TABLE, {labelinfo, Uid}),
                    case Labels of
                        [{{labelinfo, _Uid}, CurLabel, _NewLabel}] -> CurLabel;
                        _ -> #{}
                    end
              end, 
              Uids).



    
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
-spec foreach_uid_acc(Func :: atom(), Acc :: term()) -> term() | {error, any()}.
foreach_uid_acc(Func, AccInit) ->
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
-spec foreach_uid_batch_propagate(MaxNumCommunities :: pos_integer(), BatchSize :: pos_integer()) -> 
        ok | {error, any()}.
foreach_uid_batch_propagate(MaxNumCommunities, BatchSize) ->
    Start = util:now_ms(),
    ets:safe_fixtable(?COMMUNITY_DATA_TABLE, true),
    Matches = ets:match(?COMMUNITY_DATA_TABLE, {{labelinfo, '$1'}, '$2', '$3'}, BatchSize),

    do_for_batch(Matches, MaxNumCommunities, 0),
    ets:safe_fixtable(?COMMUNITY_DATA_TABLE, false),

    ?INFO("Batch propagation took ~p ms", [util:now_ms() - Start]),
    ok.

do_for_batch('$end_of_table', _MaxNumCommunities, 0) ->  
    % ?dbg("----Done with BatchPropagate!---", []), 
    ok; 
do_for_batch('$end_of_table', MaxNumCommunities, NumChildren) -> 
    % ?INFO("STATS: ~p", [wpool:stats(?COMMUNITY_WORKER_POOL)]), 
    receive
        {done, WorkerPid} -> 
            case (NumChildren - 1) rem 10 of % log every 10th to avoid too many logs
                0 -> ?INFO("Worker ~p finished! ~p remaining", [WorkerPid, NumChildren - 1]);
                _ -> ok
            end,
            do_for_batch('$end_of_table', MaxNumCommunities, NumChildren - 1)
    end,
    ok; 

do_for_batch({EntryList, Cont}, MaxNumCommunities, NumChildren) -> 
    wpool:cast(?COMMUNITY_WORKER_POOL, {?MODULE, batch_propagate, [self(), EntryList, MaxNumCommunities]}, ?COMMUNITY_POOL_STRATEGY),
    case NumChildren rem 10 of % log every 10th to avoid too many logs
        0 -> ?INFO("Spawned worker #~p to work on batch of size ~p", [NumChildren + 1, length(EntryList)]);
        _ -> ok
    end,
    do_for_batch(ets:match(Cont), MaxNumCommunities, NumChildren + 1).

