%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 18. Aug 2020 8:55 PM
%%%-------------------------------------------------------------------
-module(dev_users_tests).
-author("josh").

-include_lib("eunit/include/eunit.hrl").

-define(UID, <<"1">>).
-define(PHONE, <<"16175280000">>).
-define(DEV_UID, <<"1000000000045484920">>).  % michael's uid is on the dev list
-define(TEST_UID, <<"3">>).
-define(TEST_PHONE, <<"16175550000">>).

%% ----------------------------------------------
%% Tests
%% ----------------------------------------------

is_dev_uid_test() ->
    setup(),
    ?assert(dev_users:is_dev_uid(?DEV_UID)),
    ?assert(dev_users:is_dev_uid(?TEST_UID)),
    ?assertNot(dev_users:is_dev_uid(?UID)),
    teardown().

%% ----------------------------------------------
%% Internal functions
%% ----------------------------------------------

setup() ->
    tutil:meck_init(model_accounts, get_phone, fun mock_get_phone/1).


teardown() ->
    tutil:meck_finish(model_accounts).


mock_get_phone(Uid) ->
    case Uid of
        ?UID -> {ok, ?PHONE};
        ?DEV_UID -> {ok, ?PHONE};
        ?TEST_UID -> {ok, ?TEST_PHONE}
    end.

