%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc
%%% @doc
%%%
%%% @end
%%% Created : 18. Aug 2020 8:55 PM
%%%-------------------------------------------------------------------
-module(dev_users_tests).
-author("josh").

-include_lib("tutil.hrl").

-define(UID, <<"1">>).
-define(PHONE, <<"16175280000">>).
-define(DEV_UID, <<"1000000000045484920">>).  % michael's uid is on the dev list
-define(TEST_UID, <<"3">>).
-define(TEST_PHONE, <<"16175550000">>).

%% ----------------------------------------------
%% Tests
%% ----------------------------------------------

is_dev_uid_testset(_) ->
    [?_assert(dev_users:is_dev_uid(?DEV_UID)),
    ?_assert(dev_users:is_dev_uid(?TEST_UID)),
    ?_assertNot(dev_users:is_dev_uid(?UID))].

%% ----------------------------------------------
%% Internal functions
%% ----------------------------------------------

setup() ->
    tutil:setup([
        {meck, model_accounts, get_phone, fun mock_get_phone/1}
    ]).


mock_get_phone(Uid) ->
    case Uid of
        ?UID -> {ok, ?PHONE};
        ?DEV_UID -> {ok, ?PHONE};
        ?TEST_UID -> {ok, ?TEST_PHONE}
    end.

