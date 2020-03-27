%%%----------------------------------------------------------------------
%%% Records for presence_subscriptions
%%% presence_subs: indicates the friends for whom
%%% we need to fetch presence for the user.
%%%
%%%----------------------------------------------------------------------


-record(presence_subs, {subscriberid = {<<"">>, <<"">>} :: {binary(), binary()},
                        userid = {<<"">>, <<"">>} :: {binary(), binary()}}).