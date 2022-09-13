%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 12. May 2021 1:18 PM
%%%-------------------------------------------------------------------
-module(util_http_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").


get_ip_test() ->
    ?assertEqual("1.1.1.1",
        util_http:get_ip(undefined, [{'X-Forwarded-For', <<"1.1.1.1,2.2.2.2">>}])).