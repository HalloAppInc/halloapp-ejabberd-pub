%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Jul 2020 5:06 PM
%%%-------------------------------------------------------------------
-author("josh").

-define(PROPLIST, [
    {groups, false},
    {max_group_size, 25}
]).

-define(PROPS_HASH_KEY, {?MODULE, hash}).
-define(PROPLIST_KEY, {?MODULE, proplist}).
-define(NS_PROPS, <<"halloapp:props">>).
-define(PROPS_SHA_HASH_LENGTH_BYTES, 6).

