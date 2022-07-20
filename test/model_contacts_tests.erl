%%%-------------------------------------------------------------------
%%% File: model_contacts_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_contacts_tests).
-author("murali").

-include_lib("eunit/include/eunit.hrl").
-define(UID, <<"1000000000376503286">>).
-define(UID2, <<"1000000000376503287">>).
-define(CONTACT1, <<"14705551473">>).
-define(CONTACT2, <<"16502241748">>).
-define(CONTACT3, <<"14703381473">>).
-define(SID, <<"dbd22016">>).

setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_contacts).


keys_test() ->
    ?assertEqual(<<"con:{1000000000376503286}">>, model_contacts:contacts_key(?UID)),
    ?assertEqual(<<"sync:{1000000000376503286}:dbd22016">>, model_contacts:sync_key(?UID, ?SID)),
    ?assertEqual(<<"rev:{14705551473}">>, model_contacts:reverse_key(?CONTACT1)),
    ?assertNotEqual(<<"rph:{14705551473}">>, model_contacts:reverse_phone_hash_key(?CONTACT1)),
    ok.


add_contact_test() ->
    setup(),
    {ok, []} = model_contacts:get_contacts(?UID),
    ?assertEqual(0, model_contacts:count_contacts(?UID)),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    %% Test con:{uid}
    {ok, [?CONTACT1]} = model_contacts:get_contacts(?UID),
    ?assertEqual(1, model_contacts:count_contacts(?UID)),
    %% Test rev:{phone}
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT1).


add_contacts_test() ->
    setup(),
    ok = model_contacts:add_contacts(?UID, []),
    {ok, []} = model_contacts:get_contacts(?UID),
    ?assertEqual(0, model_contacts:count_contacts(?UID)),
    ok = model_contacts:add_contacts(?UID, [?CONTACT1, ?CONTACT2]),
    %% Test con:{uid}
    {ok, [?CONTACT1, ?CONTACT2]} = model_contacts:get_contacts(?UID),
    ?assertEqual(2, model_contacts:count_contacts(?UID)),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT3),
    %% Test rev:{phone}
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT2),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT3).


remove_contact_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
    ok = model_contacts:remove_contact(?UID, ?CONTACT1),
    %% Test con:{uid}
    {ok, [?CONTACT2]} = model_contacts:get_contacts(?UID),
    ?assertEqual(1, model_contacts:count_contacts(?UID)),
    %% Test rev:{phone}
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT2).


remove_contacts_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
    ok = model_contacts:remove_contacts(?UID, []),
    {ok, [?CONTACT1, ?CONTACT2]} = model_contacts:get_contacts(?UID),
    ?assertEqual(2, model_contacts:count_contacts(?UID)),
    ok = model_contacts:remove_contacts(?UID, [?CONTACT1, ?CONTACT2]),
    %% Test con:{uid}
    {ok, []} = model_contacts:get_contacts(?UID),
    ?assertEqual(0, model_contacts:count_contacts(?UID)),
    %% Test rev:{phone}
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT2).


remove_all_contacts_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
     %% Test con:{uid}
    {ok, [?CONTACT1, ?CONTACT2]} = model_contacts:get_contacts(?UID),
    ?assertEqual(2, model_contacts:count_contacts(?UID)),
    ok = model_contacts:remove_all_contacts(?UID),
    %% Test con:{uid}
    {ok, []} = model_contacts:get_contacts(?UID),
    ?assertEqual(0, model_contacts:count_contacts(?UID)),
    %% Test rev:{phone}
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT2).


empty_sync_contacts_test() ->
    setup(),
    {error, _} = model_contacts:finish_sync(?UID, ?SID),
    {ok, []} = model_contacts:get_contacts(?UID),

    ok = model_contacts:sync_contacts(?UID, ?SID, [?CONTACT3]),
    ok = model_contacts:finish_sync(?UID, ?SID),
    {ok, [?CONTACT3]} = model_contacts:get_contacts(?UID),

    %% We no longer do finish_sync with empty lists
    ok.


sync_contacts_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
    ok = model_contacts:sync_contacts(?UID, ?SID, [?CONTACT3]),
    %% Test sync:{sid}
    {ok, [?CONTACT3]} = model_contacts:get_sync_contacts(?UID, ?SID),
    %% Test con:{uid}
    {ok, [?CONTACT1, ?CONTACT2]} = model_contacts:get_contacts(?UID),
    %% Test rev:{phone}
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT2),
    ok = model_contacts:finish_sync(?UID, ?SID),
    %% Test con:{uid}
    {ok, [?CONTACT3]} = model_contacts:get_contacts(?UID),
    %% Test rev:{phone}
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT2).


is_contact_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
    true = model_contacts:is_contact(?UID,  ?CONTACT1),
    true = model_contacts:is_contact(?UID,  ?CONTACT2),
    false = model_contacts:is_contact(?UID,  ?CONTACT3).

get_contact_uids_multi_test() ->
    setup(),
    ?assertEqual(
        {ok, #{?CONTACT1 => [], ?CONTACT2 => []}}, 
        model_contacts:get_contact_uids([?CONTACT1, ?CONTACT2])),
    ok = model_contacts:add_contacts(?UID, [?CONTACT1, ?CONTACT2]),
    ok = model_contacts:add_contacts(?UID2, [?CONTACT1]),
    ?assertEqual(
        {ok, #{?CONTACT1 => [?UID, ?UID2], ?CONTACT2 => [?UID]}}, 
        model_contacts:get_contact_uids([?CONTACT1, ?CONTACT2])),
    ok.

get_contact_uids_size_test() ->
    setup(),
    ?assertEqual(0, model_contacts:get_contact_uids_size(?CONTACT1)),
    ok = model_contacts:add_contacts(?UID, [?CONTACT1, ?CONTACT2]),
    ?assertEqual(1, model_contacts:get_contact_uids_size(?CONTACT1)),
    ok = model_contacts:add_contacts(?UID2, [?CONTACT1, ?CONTACT2]),
    ?assertEqual(2, model_contacts:get_contact_uids_size(?CONTACT1)),
    ok.


get_contacts_uids_size_test() ->
    setup(),
    ?assertEqual(#{}, model_contacts:get_contacts_uids_size([])),
    ok = model_contacts:add_contacts(?UID, [?CONTACT1, ?CONTACT2]),
    ok = model_contacts:add_contacts(?UID2, [?CONTACT1]),
    ResMap = #{?CONTACT1 => 2, ?CONTACT2 => 1},
    ResMap = model_contacts:get_contacts_uids_size([?CONTACT1, ?CONTACT2]),
    ResMap = model_contacts:get_contacts_uids_size([?CONTACT1, ?CONTACT2, ?CONTACT3]),
    ok.


add_reverse_hash_contacts_test() ->
    setup(),
    ok = model_contacts:add_reverse_hash_contacts(?UID, [?CONTACT1, ?CONTACT2]),
    {ok, []} = model_contacts:get_contacts(?UID),
    {ok, [?UID]} = model_contacts:get_potential_reverse_contact_uids(?CONTACT1),
    {ok, [?UID]} = model_contacts:get_potential_reverse_contact_uids(?CONTACT2),
    {ok, []} = model_contacts:get_potential_reverse_contact_uids(?CONTACT3).


hash_phone_test() ->
    setup(),
    Hash1 = model_contacts:hash_phone(<<"14703381472">>),
    Hash2 = model_contacts:hash_phone(<<"14703381473">>),
    Hash3 = model_contacts:hash_phone(<<"14703381474">>),
    Hash4 = model_contacts:hash_phone(<<"14703381503">>),
    ?assertEqual(Hash1, Hash2),
    ?assertEqual(Hash1, Hash3),
    ?assertEqual(Hash1, Hash4),

    Hash5 = model_contacts:hash_phone(<<"14703381504">>),
    Hash6 = model_contacts:hash_phone(<<"14703381505">>),
    ?assertNotEqual(Hash1, Hash5),
    ?assertEqual(Hash5, Hash6),
    ok.


non_invited_phone_test() ->
    setup(),
    ?assertEqual([], model_contacts:get_not_invited_phones()),
    ?assertEqual(true, model_contacts:add_not_invited_phone(?CONTACT1)),
    ?assertEqual(false, model_contacts:add_not_invited_phone(?CONTACT1)),
    ?assertEqual(true, model_contacts:add_not_invited_phone(?CONTACT2)),
    Data = model_contacts:get_not_invited_phones(),
    {Phones, _Times} = lists:unzip(Data),
    ?assertEqual(2, length(Phones)),
    ?assertEqual(lists:sort([?CONTACT1, ?CONTACT2]), lists:sort(Phones)),
    ok.


sequence_loop(To, To, Fun, MapAcc) -> maps:size(MapAcc);
sequence_loop(From, To, Fun, MapAcc) ->
    NewMapAcc = erlang:apply(Fun, [From, MapAcc]),
    sequence_loop(From + 1, To, Fun, NewMapAcc).


%% Tests the lossiness of the hash function by hashing a large sequence of phone numbers.
%% We ensure that the different hash value is of the order of total numbers / 32.
test_hash_lossiness(From, To) ->
    Fun = fun(Number, Map) ->
        Hash = model_contacts:hash_phone(integer_to_binary(Number)),
        maps:put(Hash, 1, Map)
    end,
    ActualSize = sequence_loop(From, To, Fun, #{}),
    ExpectedSize = (To - From) / 32,
    ?assert(ActualSize =< ExpectedSize).


while(0, _F) -> ok;
while(N, F) ->
    erlang:apply(F, [N]),
    while(N -1, F).

perf_test1(N) ->
    StartTime = os:system_time(microsecond),
    while(N,
        fun(X) ->
            ok = model_contacts:add_contact(integer_to_binary(10), integer_to_binary(X))
        end),
    EndTime = os:system_time(microsecond),
    T = EndTime - StartTime,
%%    ?debugFmt("~w operations took ~w us => ~f ops/sec", [N, T, N / (T / 1000000)]),

    Contacts = [integer_to_binary(X) || X <- lists:seq(1,N,1)],
    StartTime1 = os:system_time(microsecond),
    ok = model_contacts:add_contacts(integer_to_binary(10), Contacts),
    EndTime1 = os:system_time(microsecond),
    T1 = EndTime1 - StartTime1,
%%    ?debugFmt("Batched ~w operations took ~w us => ~f ops/sec", [N, T1, N / (T1 / 1000000)]).
    {T, T1}.

perf_test() ->
    setup(),
    N = 50,
    while(N,
        fun(X) ->
            perf_test1(X)
        end),
    {ok, N}.


% generate_contacts(N) ->
%     lists:map(fun(X) -> integer_to_binary(X) end, lists:seq(1,N)).


% add_contacts_perf_test() ->
%     tutil:perf(
%         1000,
%         fun() -> setup() end,
%         fun() -> model_contacts:add_reverse_hash_contacts(?UID, generate_contacts(200)) end
%     ).


% remove_contacts_perf_test() ->
%     tutil:perf(
%         100,
%         fun() -> setup() end,
%         fun() ->
%             ContactList = generate_contacts(200),
%             lists:foreach(fun(X) -> ok = model_contacts:add_contact(?UID, X) end, ContactList),
%             ok = model_contacts:remove_contacts(?UID, ContactList)
%         end
%     ).


% remove_all_contacts_perf_test() ->
%     tutil:perf(
%         100,
%         fun() -> setup() end,
%         fun() ->
%             lists:foreach(fun(X) -> ok = model_contacts:add_contact(?UID, X) end, generate_contacts(200)),
%             ok = model_contacts:remove_all_contacts(?UID)
%         end
%     ).

