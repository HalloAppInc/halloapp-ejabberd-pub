%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Apr 2020 4:13 PM
%%%-------------------------------------------------------------------
-author("nikola").

-record(enrolled_users, {
    username = {<<"">>, <<"">>} :: {binary(), binary()},
    passcode = <<"">> :: binary()
}).
