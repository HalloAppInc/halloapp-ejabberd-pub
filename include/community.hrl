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

% The maximum number of iterations of label propagation we will allow when identifying communities
-define(MAXIMUM_ITERATIONS, 25). 

% number of keys to scan through on each iteration in the redis DB -- the COUNT option
%  docs: https://redis.io/commands/scan/#the-count-option
-define(SCAN_BLOCK_SIZE, 1000).

% Number of keys returned from a call to ets:match when iterating through all ets keys
-define(MATCH_CHUNK_SIZE, 1000). 

% This is the configuration parameter of the cluster detection algorithm
% Defines the maximum number of communities a single node can be a part of
-define(DEFAULT_MAX_COMMUNITIES, 5).

% Name of the ETS table used to calculate communities
-define(COMMUNITY_DATA_TABLE, community_data).
-define(UID_KEY_POS, 1). % Position of the key used to index into the ets table (format is {labelinfo, Uid})
-define(CUR_LABEL_POS, 2). % position of current label for each Uid in ets table
-define(NEW_LABEL_POS, 3). % position of new/updated label for each Uid in ets table



-endif.
