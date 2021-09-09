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
-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(HASH_LENGTH, ?PROPS_SHA_HASH_LENGTH_BYTES).
-define(UID, <<"1">>).
-define(UID2, <<"2">>).
-define(UID3, <<"3">>).
-define(PHONE, <<"16175280000">>).
-define(DEV_UID, <<"1000000000045484920">>).  % michael's uid is on the dev list
-define(TEST_UID, <<"4">>).
-define(TEST_PHONE, <<"16175550000">>).
-define(TEST_PROPLIST, [
    {some_test_prop, "value"},
    {max_group_size, 25},
    {groups, true},
    {pi, 3.14}
]).
-define(CLIENT_VERSION1, <<"HalloApp/iOS1.8.151">>).

%% ----------------------------------------------
%% Tests
%% ----------------------------------------------

hash_length_test() ->
    setup(),
    Hash1 = mod_props:get_hash(?UID, ?CLIENT_VERSION1),
    Hash2 = mod_props:get_hash(?DEV_UID, ?CLIENT_VERSION1),
    ?assert(?HASH_LENGTH == byte_size(Hash1)),
    ?assert(?HASH_LENGTH == byte_size(Hash2)),
    teardown().


hash_test() ->
    setup(),
    Hash1 = mod_props:get_hash(?UID, ?CLIENT_VERSION1),
    Hash2 = mod_props:get_hash(?DEV_UID, ?CLIENT_VERSION1),
    ?assertNotEqual(Hash1, Hash2),
    teardown().


iq_test() ->
    SortedProplist = lists:keysort(1, ?TEST_PROPLIST),
    Hash = mod_props:generate_hash(SortedProplist),
    Actual = mod_props:make_response(#pb_iq{type = get}, SortedProplist, Hash),
    Expected = #pb_iq{type = result, payload =
        #pb_props{hash = Hash, props = [
            #pb_prop{name = <<"groups">>, value = <<"true">>},
            #pb_prop{name = <<"max_group_size">>, value = <<"25">>},
            #pb_prop{name = <<"pi">>, value = float_to_binary(3.14, [{decimals, 2}])},
            #pb_prop{name = <<"some_test_prop">>, value = <<"value">>}]}},
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

