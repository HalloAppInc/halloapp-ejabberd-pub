%%%-------------------------------------------------------------------
%%% File: mod_user_privacy_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_user_privacy_tests).
-author('murali').

-include("xmpp.hrl").
-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1">>).
-define(PHONE1, <<"14703381473">>).
-define(UA1, <<"ios">>).

-define(NAME1, <<"alice">>).
-define(NAME2, <<"bob">>).

-define(UID2, <<"2">>).
-define(UID3, <<"3">>).
-define(UID4, <<"4">>).
-define(UID5, <<"5">>).
-define(SERVER, <<"s.halloapp.net">>).

-define(HASH_FUNC, sha256).


setup() ->
    tutil:setup(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_accounts).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                   helper functions                           %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

setup_accounts(Accounts) ->
    lists:foreach(
        fun([Uid, Phone, Name, UserAgent]) ->
            ok = model_accounts:create_account(Uid, Phone, Name, UserAgent),
            ok = model_phone:add_phone(Phone, Uid)
        end, Accounts),
    ok.


create_uid_el(Type, Uid) ->
    #pb_uid_element{action = Type, uid = Uid}.


create_privacy_list(Type, HashValue, UidEls) ->
    #pb_privacy_list{
        type = Type,
        hash = HashValue,
        uid_elements = UidEls
    }.


create_iq_request_privacy_list(Uid, Type, Payload) ->
    #pb_iq{
        from_uid = Uid,
        to_uid = <<>>,
        type = Type,
        payload = Payload
    }.


create_error_st(Reason) ->
    util:err(Reason).

create_error_hash_st(Reason, Hash) ->
    #pb_privacy_list_result{
        result = <<"failed">>,
        reason = util:to_binary(Reason),
        hash = Hash
    }.

create_iq_response_privacy_list(Uid, Type, Payload) ->
    #pb_iq{
        to_uid = Uid,
        from_uid = <<>>,
        type = Type,
        payload = Payload
    }.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


join_binary_test() ->
    setup(),

    ?assertEqual(<<>>, util:join_binary(<<",">>, [], <<>>)),
    FinalString = <<",", ?UID1/binary, ",", ?UID2/binary, ",", ?UID3/binary>>,
    ?assertEqual(FinalString, util:join_binary(<<",">>, [?UID1, ?UID2, ?UID3], <<>>)),
    ok.


update_privacy_type_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    ?assertEqual(all, mod_user_privacy:get_privacy_type(?UID1)),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, all, <<>>, [])),
    ?assertEqual(all, mod_user_privacy:get_privacy_type(?UID1)),
    ok.



iq_unexcepted_uids_error_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),
    UidEl1 = create_uid_el(add, ?UID2),
    SubEl1 = create_privacy_list(all, <<>>, [UidEl1]),
    RequestIQ = create_iq_request_privacy_list(?UID1, set, SubEl1),

    SubEl2 = create_error_st(unexcepted_uids),
    ExpectedResponseIQ = create_iq_response_privacy_list(?UID1, error, SubEl2),
    ActualResponseIQ = mod_user_privacy:process_local_iq(RequestIQ),

    ?assertEqual(ExpectedResponseIQ, ActualResponseIQ),
    ok.


iq_invalid_type_error_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),
    UidEl1 = create_uid_el(add, ?UID2),
    SubEl1 = create_privacy_list(check, <<>>, [UidEl1]),
    RequestIQ = create_iq_request_privacy_list(?UID1, set, SubEl1),

    SubEl2 = create_error_st(invalid_type),
    ExpectedResponseIQ = create_iq_response_privacy_list(?UID1, error, SubEl2),
    ActualResponseIQ = mod_user_privacy:process_local_iq(RequestIQ),

    ?assertEqual(ExpectedResponseIQ, ActualResponseIQ),
    ok.


iq_hash_mismatch_error_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),
    UidEl1 = create_uid_el(add, ?UID2),
    SubEl1 = create_privacy_list(only, <<"error">>, [UidEl1]),
    RequestIQ = create_iq_request_privacy_list(?UID1, set, SubEl1),

    ServerHashValue = crypto:hash(?HASH_FUNC, <<",", ?UID2/binary>>),
    SubEl2 = create_error_hash_st(hash_mismatch, ServerHashValue),
    ExpectedResponseIQ = create_iq_response_privacy_list(?UID1, error, SubEl2),
    ActualResponseIQ = mod_user_privacy:process_local_iq(RequestIQ),

    ?assertEqual(ExpectedResponseIQ, ActualResponseIQ),
    ok.


iq_result_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),
    UidEl1 = create_uid_el(add, ?UID2),
    SubEl1 = create_privacy_list(except, undefined, [UidEl1]),
    RequestIQ = create_iq_request_privacy_list(?UID1, set, SubEl1),

    ExpectedResponseIQ = create_iq_response_privacy_list(?UID1, result, undefined),
    ActualResponseIQ = mod_user_privacy:process_local_iq(RequestIQ),

    ?assertEqual(ExpectedResponseIQ, ActualResponseIQ),
    ok.


iq_get_privacy_list_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),
    ok = model_privacy:add_only_uids(?UID1, [?UID2, ?UID3]),
    ok = model_privacy:add_except_uids(?UID1, [?UID3, ?UID4]),
    ok = model_privacy:mute_uids(?UID1, [?UID4]),
    ok = model_privacy:block_uids(?UID1, [?UID5]),
    ok = model_privacy:set_privacy_type(?UID1, except),

    RequestIQ = create_iq_request_privacy_list(?UID1, get, #pb_privacy_lists{}),

    UidEl1 = create_uid_el(add, ?UID2),
    UidEl2 = create_uid_el(add, ?UID3),
    UidEl3 = create_uid_el(add, ?UID4),
    UidEl4 = create_uid_el(add, ?UID5),
    OnlyList = create_privacy_list(only, <<>>, [UidEl1, UidEl2]),
    ExceptList = create_privacy_list(except, <<>>, [UidEl2, UidEl3]),
    MuteList = create_privacy_list(mute, <<>>, [UidEl3]),
    BlockList = create_privacy_list(block, <<>>, [UidEl4]),
    ExpectedResponseIQ = create_iq_response_privacy_list(?UID1, result,
            #pb_privacy_lists{active_type = except, lists = [BlockList, MuteList, OnlyList, ExceptList]}),
    ActualResponseIQ = mod_user_privacy:process_local_iq(RequestIQ),

    ?assertEqual(ExpectedResponseIQ, ActualResponseIQ),
    ok.


update_privacy_type_error_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    UidEl1 = create_uid_el(add, ?UID2),
    ?assertEqual({error, unexcepted_uids}, mod_user_privacy:update_privacy_type(?UID1, all, <<>>, [UidEl1])),
    ?assertEqual({error, invalid_type}, mod_user_privacy:update_privacy_type(?UID1, check, <<>>, [UidEl1])),

    %% Send incorrect hash value.
    ServerHashValue = crypto:hash(?HASH_FUNC, <<",", ?UID2/binary>>),
    ?assertEqual({error, hash_mismatch, ServerHashValue},
            mod_user_privacy:update_privacy_type(?UID1, except, <<"error">>, [UidEl1])),
    ok.


update_privacy_type_hash_undefined_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    ?assertEqual(all, mod_user_privacy:get_privacy_type(?UID1)),
    UidEl1 = create_uid_el(add, ?UID2),
    UidEl2 = create_uid_el(add, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, except, undefined, [UidEl1, UidEl2])),
    ?assertEqual(except, mod_user_privacy:get_privacy_type(?UID1)),
    {ok, Res1} = model_privacy:get_except_uids(?UID1),
    ExpectedList1 = lists:sort([?UID2, ?UID3]),
    ActualList1 = lists:sort(Res1),
    ?assertEqual(ExpectedList1, ActualList1),
    ok.


update_privacy_type_except_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    ?assertEqual(all, mod_user_privacy:get_privacy_type(?UID1)),
    HashValue1 = crypto:hash(?HASH_FUNC, <<",", ?UID2/binary>>),
    UidEl1 = create_uid_el(add, ?UID2),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, except, HashValue1, [UidEl1])),
    ?assertEqual(except, mod_user_privacy:get_privacy_type(?UID1)),
    {ok, Res1} = model_privacy:get_except_uids(?UID1),
    ExpectedList1 = lists:sort([?UID2]),
    ActualList1 = lists:sort(Res1),
    ?assertEqual(ExpectedList1, ActualList1),

    HashValue2 = crypto:hash(?HASH_FUNC, <<",", ?UID3/binary>>),
    UidEl2 = create_uid_el(add, ?UID3),
    UidEl3 = create_uid_el(delete, ?UID2),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, except, HashValue2, [UidEl2, UidEl3])),
    ?assertEqual(except, mod_user_privacy:get_privacy_type(?UID1)),
    {ok, Res2} = model_privacy:get_except_uids(?UID1),
    ExpectedList2 = lists:sort([?UID3]),
    ActualList2 = lists:sort(Res2),
    ?assertEqual(ExpectedList2, ActualList2),
    ok.


update_privacy_type_only_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    ?assertEqual(all, mod_user_privacy:get_privacy_type(?UID1)),
    HashValue1 = crypto:hash(?HASH_FUNC, <<",", ?UID2/binary>>),
    UidEl1 = create_uid_el(add, ?UID2),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, only, HashValue1, [UidEl1])),
    ?assertEqual(only, mod_user_privacy:get_privacy_type(?UID1)),
    {ok, Res1} = model_privacy:get_only_uids(?UID1),
    ExpectedList1 = lists:sort([?UID2]),
    ActualList1 = lists:sort(Res1),
    ?assertEqual(ExpectedList1, ActualList1),

    HashValue2 = crypto:hash(?HASH_FUNC, <<",", ?UID3/binary>>),
    UidEl2 = create_uid_el(delete, ?UID2),
    UidEl3 = create_uid_el(add, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, only, HashValue2, [UidEl2, UidEl3])),
    ?assertEqual(only, mod_user_privacy:get_privacy_type(?UID1)),
    {ok, Res2} = model_privacy:get_only_uids(?UID1),
    ExpectedList2 = lists:sort([?UID3]),
    ActualList2 = lists:sort(Res2),
    ?assertEqual(ExpectedList2, ActualList2),
    ok.


update_privacy_type_mute_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    HashValue1 = crypto:hash(?HASH_FUNC, <<",", ?UID2/binary, ",", ?UID3/binary>>),
    UidEl1 = create_uid_el(add, ?UID2),
    UidEl2 = create_uid_el(add, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, mute, HashValue1, [UidEl1, UidEl2])),
    {ok, Res1} = model_privacy:get_mutelist_uids(?UID1),
    ExpectedList1 = lists:sort([?UID2, ?UID3]),
    ActualList1 = lists:sort(Res1),
    ?assertEqual(ExpectedList1, ActualList1),

    HashValue2 = crypto:hash(?HASH_FUNC, <<",", ?UID2/binary>>),
    UidEl3 = create_uid_el(delete, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, mute, HashValue2, [UidEl3])),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_mutelist_uids(?UID1)),
    ok.


update_privacy_type_block_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    HashValue1 = crypto:hash(?HASH_FUNC, <<",", ?UID3/binary>>),
    UidEl1 = create_uid_el(add, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, block, HashValue1, [UidEl1])),
    {ok, Res1} = model_privacy:get_blocked_uids(?UID1),
    ExpectedList1 = lists:sort([?UID3]),
    ActualList1 = lists:sort(Res1),
    ?assertEqual(ExpectedList1, ActualList1),

    HashValue2 = crypto:hash(?HASH_FUNC, <<>>),
    UidEl2 = create_uid_el(delete, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, block, HashValue2, [UidEl2])),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)),
    ok.

