%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-author("vipin").

-ifndef(EXPIRATION_HRL).
-define(EXPIRATION_HRL, 1).

-include("time.hrl").

%% TODO (murali@): Remove tracking push notifications being sent to the client.
%% i am concerned with the memory usage for this, but we only need this for about 3 more months
%% until ios can handle dismissing notifications for all content.
%% We can remove this code altogether then. this would help solve some duplicate 
%% push issues we have been noticing with groupfeed e2e rerequests.
-define(PUSH_EXPIRATION, (7 * ?DAYS)).

-endif.
