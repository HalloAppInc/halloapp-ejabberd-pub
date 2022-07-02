%%%-------------------------------------------------------------------
%%% @author luke
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 16. Jun 2022 12:44 PM
%%%-------------------------------------------------------------------
-author("luke").

-ifndef(COMMUNITY_HRL).
-define(COMMUNITY_HRL, 1).

-include("ha_types.hrl").

% Map of Community Id => Belonging coefficient for a given Uid
% i.e. if a uid's label is #{<<"1">> => .75, <<"2">> => .25} means that it belongs to community 1 
%  with strength .75 and to community 2 with strength .25 (belonging coefficients in a label must 
%  sum to 1)
-type community_label() :: #{uid() => float()}.
-type propagation_option() :: {fresh_start, boolean()} | {max_iters, pos_integer()} | 
    {num_workers, pos_integer()} | {max_communities_per_node, pos_integer()} | 
    {batch_size, pos_integer()} | {small_cluster_threshold, pos_integer()}.

% The maximum number of nodes that will be forced to share one community
-define(DEFAULT_SMALL_CLUSTER_THRESHOLD, 5).

% This is the configuration parameter of the cluster detection algorithm
% Defines the maximum number of communities a single node can be a part of
-define(DEFAULT_MAX_COMMUNITIES, 4).

% The default maximum number of iterations of label propagation we will allow when identifying communities
-define(DEFAULT_MAXIMUM_ITERATIONS, 100). 

% number of keys to scan through on each iteration in the redis DB -- the COUNT option
%  docs: https://redis.io/commands/scan/#the-count-option
-define(SCAN_BLOCK_SIZE, 1000).

% Number of keys returned from a call to ets:match when iterating through all ets keys
% Also size of batch call to model_friends:get_friends_multi/1
-ifdef(TEST).
-define(MATCH_CHUNK_SIZE, 10). % to allow testing of parallel batches
-else.
-define(MATCH_CHUNK_SIZE, 2500). 
-endif.

-define(COMMUNITY_WORKER_POOL, community_workers). % Name of the worker pool used to process batches
-define(COMMUNITY_DEFAULT_NUM_WORKERS, 4). % size of the worker pool
-define(COMMUNITY_POOL_STRATEGY, available_worker). % strategy used to delegate tasks to workers

% Name of the ETS table used to calculate communities
-define(COMMUNITY_DATA_TABLE, community_data).
-define(UID_KEY_POS, 1). % Position of the key used to index into the ets table (format is {labelinfo, Uid})
-define(CUR_LABEL_POS, 2). % position of current label for each Uid in ets table
-define(NEW_LABEL_POS, 3). % position of new/updated label for each Uid in ets table



-endif.
