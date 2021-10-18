%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_geodb_tests).
-author("vipin").

-include_lib("eunit/include/eunit.hrl").

-define(SERVER, <<"s.halloapp.net">>).

setup() ->
    ?assert(config:is_testing_env()).

geo_db_test() ->
    setup(),
    application:ensure_all_started(locus),
    mod_geodb:start(?SERVER, []),
    % _StartTime = util:now_ms(),
    <<"US">> = mod_geodb:lookup("2600:1700:1150:d42f:fd51:608a:4ac0:ea6"),
    % _EndTime = util:now_ms(),
    % ?debugFmt("Time taken: ~p", [EndTime - StartTime]),
    <<"US">> = mod_geodb:lookup("2605:6440:4012:1004::bfa9"),
    <<"PS">> = mod_geodb:lookup("37.8.5.229"),
    mod_geodb:stop(?SERVER),
    ok.


