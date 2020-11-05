%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Jul 2020 8:11 PM
%%%-------------------------------------------------------------------
-module(mod_props_tests).
-author("josh").

-include("props.hrl").
-include("xmpp.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(HASH_LENGTH, (?PROPS_SHA_HASH_LENGTH_BYTES * 4 / 3)).
-define(UID, <<"1">>).
-define(UID2, <<"2">>).
-define(UID3, <<"3">>).
-define(PHONE, <<"16175280000">>).
-define(DEV_UID, <<"1000000000045484920">>).  % michael's uid is on the dev list
-define(TEST_UID, <<"3">>).
-define(TEST_PHONE, <<"16175550000">>).
-define(TEST_PROPLIST, [
    {some_test_prop, "value"},
    {max_group_size, 25},
    {groups, true},
    {pi, 3.14}
]).

%% ----------------------------------------------
%% Tests
%% ----------------------------------------------

hash_length_test() ->
    setup(),
    Hash1 = mod_props:get_hash(?UID),
    Hash2 = mod_props:get_hash(?DEV_UID),
    ?assert(?HASH_LENGTH == byte_size(Hash1)),
    ?assert(?HASH_LENGTH == byte_size(Hash2)),
    teardown().


hash_test() ->
    setup(),
    Hash1 = mod_props:get_hash(?UID),
    Hash2 = mod_props:get_hash(?DEV_UID),
    ?assertNotEqual(Hash1, Hash2),
    teardown().


hash_client_version_test() ->
    setup(),
    Hash1 = mod_props:get_hash(?UID),
    Hash2 = mod_props:get_hash(?UID2),
    Hash3 = mod_props:get_hash(?UID3),
    ?assertEqual(Hash1, Hash2),
    ?assertNotEqual(Hash1, Hash3),
    teardown().


iq_test() ->
    SortedProplist = lists:keysort(1, ?TEST_PROPLIST),
    Hash = mod_props:generate_hash(SortedProplist),
    Actual = mod_props:make_response(#iq{type = get}, SortedProplist, Hash),
    Expected = #iq{type = result, sub_els = [
        #props{hash = Hash, props = [
            #prop{name = groups, value = true},
            #prop{name = max_group_size, value = 25},
            #prop{name = pi, value = 3.14},
            #prop{name = some_test_prop, value = "value"}]}]},
    ?assertEqual(Expected, Actual).

%% ----------------------------------------------
%% Internal functions
%% ----------------------------------------------

setup() ->
    meck:new(model_accounts),
    meck:expect(model_accounts, get_phone, fun mock_get_phone/1),
    meck:expect(model_accounts, get_client_version, fun mock_get_client_version/1).


teardown() ->
    ?assert(meck:validate(model_accounts)),
    meck:unload(model_accounts).


mock_get_phone(Uid) ->
    case Uid of
        ?UID -> {ok, ?PHONE};
        ?UID2 -> {ok, ?PHONE};
        ?UID3 -> {ok, ?PHONE};
        ?DEV_UID -> {ok, ?PHONE};
        ?TEST_UID -> {ok, ?TEST_PHONE}
    end.


mock_get_client_version(Uid) ->
    case Uid of
        ?UID -> {ok, <<"HalloApp/iOS0.3.75">>};
        ?UID2 -> {ok, <<"HalloApp/iOS0.3.75">>};
        ?UID3 -> {ok, <<"HalloApp/iOS0.3.76">>};
        ?DEV_UID -> {ok, <<"HalloApp/iOS0.3.76">>};
        ?TEST_UID -> {ok, <<"HalloApp/Android0.100">>}
    end.

