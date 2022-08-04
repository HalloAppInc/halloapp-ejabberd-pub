%%%-------------------------------------------------------------------
%%% File: mod_client_version_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_client_version_tests).
-author("nikola").


-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1">>).
-define(SERVER, <<"s.halloapp.net">>).

setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_accounts).


mod_client_version_test() ->
    setup(),
    Host = <<"s.halloapp.net">>,
    Opts = [],
    ?assertEqual(ok, mod_client_version:start(Host, Opts)),
    ?assertEqual(ok, mod_client_version:stop(Host)),
    ?assertEqual([], mod_client_version:depends(Host, Opts)),
    ?assertEqual([], mod_client_version:mod_options(Host)),
    ok.

% TODO when
