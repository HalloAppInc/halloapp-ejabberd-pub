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
-define(TEST_PROPLIST, [
    {some_test_prop, "value"},
    {max_group_size, 25},
    {groups, true},
    {pi, 3.14}
]).


hash_length_test() ->
    {Hash, _SortedProplist} = mod_props:generate_hash_and_sorted_proplist(?TEST_PROPLIST),
    ?assert(?HASH_LENGTH == byte_size(Hash)).


hash_test() ->
    {Hash1, _} = mod_props:generate_hash_and_sorted_proplist(?TEST_PROPLIST),
    {Hash2, _} = mod_props:generate_hash_and_sorted_proplist(lists:reverse(?TEST_PROPLIST)),
    ?assertEqual(Hash1, Hash2),
    {Hash3, _} = mod_props:generate_hash_and_sorted_proplist([{some_key, "val"} | ?TEST_PROPLIST]),
    ?assertNotEqual(Hash1, Hash3).


iq_test() ->
    {Hash, SortedProplist} = mod_props:generate_hash_and_sorted_proplist(?TEST_PROPLIST),
    Actual = mod_props:make_response(#iq{type = get}, SortedProplist, Hash),
    Expected = #iq{type = result, sub_els = [
        #props{hash = Hash, props = [
            #prop{name = groups, value = true},
            #prop{name = max_group_size, value = 25},
            #prop{name = pi, value = 3.14},
            #prop{name = some_test_prop, value = "value"}]}]},
    ?assertEqual(Expected, Actual).

