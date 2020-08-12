%%%-------------------------------------------------------------------
%%% File: mod_user_privacy_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_user_privacy_tests).
-author('murali').

-include("xmpp.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1">>).
-define(PHONE1, <<"14703381473">>).
-define(UA1, <<"ios">>).

-define(NAME1, <<"alice">>).
-define(NAME2, <<"bob">>).

-define(UID2, <<"2">>).
-define(UID3, <<"3">>).
-define(SERVER, <<"s.halloapp.net">>).

-define(HASH_FUNC, sha256).


setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    clear(),
    ok.


clear() ->
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb).


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
    #uid_el{type = Type, uid = Uid}.

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


update_privacy_type_error_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    ?assertEqual({error, unexcepted_uids}, mod_user_privacy:update_privacy_type(?UID1, all, <<>>, [?UID2])),
    ?assertEqual({error, invalid_type}, mod_user_privacy:update_privacy_type(?UID1, check, <<>>, [?UID2])),
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
    HashValue1 = base64url:encode(crypto:hash(?HASH_FUNC, <<",", ?UID2/binary>>)),
    UidEl1 = create_uid_el(add, ?UID2),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, except, HashValue1, [UidEl1])),
    ?assertEqual(except, mod_user_privacy:get_privacy_type(?UID1)),
    {ok, Res1} = model_privacy:get_except_uids(?UID1),
    ExpectedList1 = lists:sort([?UID2]),
    ActualList1 = lists:sort(Res1),
    ?assertEqual(ExpectedList1, ActualList1),

    HashValue2 = base64url:encode(crypto:hash(?HASH_FUNC, <<",", ?UID2/binary, ",", ?UID3/binary>>)),
    UidEl2 = create_uid_el(add, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, except, HashValue2, [UidEl2])),
    ?assertEqual(except, mod_user_privacy:get_privacy_type(?UID1)),
    {ok, Res2} = model_privacy:get_except_uids(?UID1),
    ExpectedList2 = lists:sort([?UID2, ?UID3]),
    ActualList2 = lists:sort(Res2),
    ?assertEqual(ExpectedList2, ActualList2),
    ok.


update_privacy_type_only_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    ?assertEqual(all, mod_user_privacy:get_privacy_type(?UID1)),
    HashValue1 = base64url:encode(crypto:hash(?HASH_FUNC, <<",", ?UID2/binary>>)),
    UidEl1 = create_uid_el(add, ?UID2),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, only, HashValue1, [UidEl1])),
    ?assertEqual(only, mod_user_privacy:get_privacy_type(?UID1)),
    {ok, Res1} = model_privacy:get_only_uids(?UID1),
    ExpectedList1 = lists:sort([?UID2]),
    ActualList1 = lists:sort(Res1),
    ?assertEqual(ExpectedList1, ActualList1),

    HashValue2 = base64url:encode(crypto:hash(?HASH_FUNC, <<",", ?UID3/binary>>)),
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

    HashValue1 = base64url:encode(crypto:hash(?HASH_FUNC, <<",", ?UID2/binary, ",", ?UID3/binary>>)),
    UidEl1 = create_uid_el(add, ?UID2),
    UidEl2 = create_uid_el(add, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, mute, HashValue1, [UidEl1, UidEl2])),
    {ok, Res1} = model_privacy:get_mutelist_uids(?UID1),
    ExpectedList1 = lists:sort([?UID2, ?UID3]),
    ActualList1 = lists:sort(Res1),
    ?assertEqual(ExpectedList1, ActualList1),

    HashValue2 = base64url:encode(crypto:hash(?HASH_FUNC, <<",", ?UID2/binary>>)),
    UidEl3 = create_uid_el(delete, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, mute, HashValue2, [UidEl3])),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_mutelist_uids(?UID1)),
    ok.


update_privacy_type_block_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    HashValue1 = base64url:encode(crypto:hash(?HASH_FUNC, <<",", ?UID3/binary>>)),
    UidEl1 = create_uid_el(add, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, block, HashValue1, [UidEl1])),
    {ok, Res1} = model_privacy:get_blocked_uids(?UID1),
    ExpectedList1 = lists:sort([?UID3]),
    ActualList1 = lists:sort(Res1),
    ?assertEqual(ExpectedList1, ActualList1),

    HashValue2 = base64url:encode(crypto:hash(?HASH_FUNC, <<>>)),
    UidEl2 = create_uid_el(delete, ?UID3),
    ?assertEqual(ok, mod_user_privacy:update_privacy_type(?UID1, block, HashValue2, [UidEl2])),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)),
    ok.

