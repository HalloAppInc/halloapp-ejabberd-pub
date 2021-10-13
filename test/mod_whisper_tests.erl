%%%-------------------------------------------------------------------
%%% File: mod_whisper_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_whisper_tests).
-author("nikola").

-include("xmpp.hrl").
-include("whisper.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("eunit/include/eunit.hrl").


setup() ->
    enif_protobuf:load_cache(server:get_msg_defs()),
    tutil:setup(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    ha_redis:start(),
    clear(),
    ok.

clear() ->
    tutil:cleardb(redis_whisper).


gen_key64_test() ->
    ?assertEqual(12, byte_size(tutil:gen_keyb64(12))),
    ?assertEqual(16, byte_size(tutil:gen_keyb64(13))),
    ?assertEqual(16, byte_size(tutil:gen_keyb64(14))),
    ?assertEqual(16, byte_size(tutil:gen_keyb64(15))),
    ?assertEqual(16, byte_size(tutil:gen_keyb64(16))),
    ok.

gen_otk_test() ->
    ?assertEqual(5, length(tutil:gen_otkb64(5, 10))),
    [Key | _Rest] = tutil:gen_otkb64(5, 12),
    ?assertEqual(12, byte_size(Key)),
    ok.

check_whisper_keys_test() ->
    ?assertEqual(ok, mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(10, 32))),
    ok.

bad_base64_key_test() ->
    ?assertEqual(
        {error, bad_base64_key},
        mod_whisper:check_whisper_keys(<<"()">>, tutil:gen_keyb64(64), tutil:gen_otkb64(10, 32))),
    ?assertEqual(
        {error, bad_base64_key},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), <<"()">>, tutil:gen_otkb64(10, 32))),
    ?assertEqual(
        {error, bad_base64_one_time_keys},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(64), [<<"()">> | tutil:gen_otkb64(10, 32)])),
    ok.

missing_identity_key_test() ->
    ?assertEqual({error, missing_identity_key},
        mod_whisper:check_whisper_keys(<<>>, tutil:gen_keyb64(64), tutil:gen_otkb64(10, 32))),
    ok.

missing_signed_key_test() ->
    ?assertEqual({error, missing_signed_key},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), <<>>, tutil:gen_otkb64(10, 32))),
    ok.

too_big_key_test() ->
    ?assertEqual({error, too_big_identity_key},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(?MAX_KEY_SIZE + 10), tutil:gen_keyb64(64), tutil:gen_otkb64(10, 32))),
    ?assertEqual({error, too_big_signed_key},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(?MAX_KEY_SIZE + 10), tutil:gen_otkb64(10, 32))),
    ok.

too_small_key_test() ->
    ?assertEqual({error, too_small_identity_key},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(?MIN_KEY_SIZE - 5), tutil:gen_keyb64(64), tutil:gen_otkb64(10, 32))),
    ?assertEqual({error, too_small_signed_key},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(?MIN_KEY_SIZE - 5), tutil:gen_otkb64(10, 32))),
    ok.

check_length_of_otks_test() ->
    ?assertEqual(ok,
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(?MIN_OTK_LENGTH, 32))),
    ?assertEqual({error, too_few_one_time_keys},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(?MIN_OTK_LENGTH - 1, 32))),
    ?assertEqual(ok,
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(?MAX_OTK_LENGTH, 32))),
    ?assertEqual({error, too_many_one_time_keys},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(?MAX_OTK_LENGTH + 1, 32))),
    ok.

check_size_of_otks_test() ->
    ?assertEqual({error, too_big_one_time_keys},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(?MIN_OTK_LENGTH, ?MAX_KEY_SIZE + 10))),
    ?assertEqual({error, too_small_one_time_keys},
        mod_whisper:check_whisper_keys(tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(?MIN_OTK_LENGTH, ?MIN_KEY_SIZE - 10))),
    ok.


%% -------------------------------------------- %%
%% Tests for IQ API
%% --------------------------------------------	%%

add_whisper_keys_test() ->
    setup(),
    {IK, SK, OTKS} = {tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(16, 64)},
    mod_whisper:set_keys_and_notify(?UID1, IK, SK, OTKS),

    ?assertEqual({ok, 16}, model_whisper_keys:count_otp_keys(?UID1)),
    OTKS2 = tutil:gen_otk(16, 64),
    Result2 = mod_whisper:process_local_iq(create_add_whisper_keys_iq(
        ?UID1, OTKS2)),
    ?assertEqual({ok, 32}, model_whisper_keys:count_otp_keys(?UID1)),
    check_iq_result(Result2),
    ok.

count_whisper_keys_test() ->
    setup(),
    {IK, SK, OTKS} = {tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(16, 64)},
    mod_whisper:set_keys_and_notify(?UID1, IK, SK, OTKS),

    ?assertEqual({ok, 16}, model_whisper_keys:count_otp_keys(?UID1)),
    Result2 = mod_whisper:process_local_iq(create_count_whisper_keys_iq(
        ?UID1)),
    check_iq_result_count(Result2, 16),
    ok.

get_whisper_keys_test() ->
    setup(),
    {IK, SK, OTKS} = {tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(16, 64)},
    mod_whisper:set_keys_and_notify(?UID1, IK, SK, OTKS),

    ?assertEqual({ok, 16}, model_whisper_keys:count_otp_keys(?UID1)),
    Result = mod_whisper:process_local_iq(create_get_whisper_keys_iq(
        ?UID2, ?UID1)),
    ?assertEqual(result, Result#pb_iq.type),
    check_wk_result(Result#pb_iq.payload, ?UID1, IK, SK, lists:nth(1, OTKS)),
    ?assertEqual({ok, 15}, model_whisper_keys:count_otp_keys(?UID1)),
    ok.


get_whisper_keys_collection_test() ->
    setup(),
    {IK, SK, OTKS} = {tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(16, 64)},
    mod_whisper:set_keys_and_notify(?UID1, IK, SK, OTKS),
    {IK2, SK2, OTKS2} = {tutil:gen_keyb64(64), tutil:gen_keyb64(64), tutil:gen_otkb64(16, 64)},
    mod_whisper:set_keys_and_notify(?UID2, IK2, SK2, OTKS2),
    ?assertEqual({ok, 16}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, 16}, model_whisper_keys:count_otp_keys(?UID2)),

    Result = mod_whisper:process_local_iq(create_get_whisper_keys_collection_iq(
        ?UID3, [?UID1, ?UID2])),
    ?assertEqual(result, Result#pb_iq.type),
    [WK1, WK2] = Result#pb_iq.payload#pb_whisper_keys_collection.collection,
    check_wk_result(WK1, ?UID1, IK, SK, lists:nth(1, OTKS)),
    check_wk_result(WK2, ?UID2, IK2, SK2, lists:nth(1, OTKS2)),
    ?assertEqual({ok, 15}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, 15}, model_whisper_keys:count_otp_keys(?UID2)),
    ok.


get_trunc_whisper_keys_collection_test() ->
    setup(),
    {IK, SK, OTKS} = tutil:gen_whisper_keys(16, 64),
    mod_whisper:set_keys_and_notify(?UID1, IK, SK, OTKS),
    {IK2, SK2, OTKS2} = tutil:gen_whisper_keys(16, 64),
    mod_whisper:set_keys_and_notify(?UID2, IK2, SK2, OTKS2),

    Result = mod_whisper:process_local_iq(create_get_trunc_whisper_keys_collection_iq(
        ?UID3, [?UID1, ?UID2, ?UID3, undefined])),
    ?assertEqual(result, Result#pb_iq.type),
    [WK1, WK2] = Result#pb_iq.payload#pb_trunc_whisper_keys_collection.collection,
    check_trunc_ik(WK1, IK),
    check_trunc_ik(WK2, IK2),
    ok.

%% -------------------------------------------- %%
%% Helper functions
%% --------------------------------------------	%%

create_add_whisper_keys_iq(Uid, OneTimeKeys) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = #pb_whisper_keys{
            action = add,
            identity_key = undefined,
            signed_key = undefined,
            one_time_keys = OneTimeKeys}
    }.

create_count_whisper_keys_iq(Uid) ->
    #pb_iq{
        from_uid = Uid,
        type = get,
        payload = #pb_whisper_keys{
            action = count}
    }.

create_get_whisper_keys_iq(Uid, Ouid) ->
    #pb_iq{
        from_uid = Uid,
        type = get,
        payload = #pb_whisper_keys{
            uid = Ouid,
            action = get}
    }.

create_get_whisper_keys_collection_iq(Uid, Ouids) ->
    Collection = lists:map(
        fun(Ouid) -> #pb_whisper_keys{uid = Ouid, action = get} end,
        Ouids),
    #pb_iq{
        from_uid = Uid,
        type = get,
        payload = #pb_whisper_keys_collection{collection = Collection}
    }.

create_get_trunc_whisper_keys_collection_iq(Uid, Ouids) ->
    Collection = lists:map(
        fun(Ouid) -> #pb_trunc_whisper_keys{uid = Ouid} end,
        Ouids),
    #pb_iq{
        from_uid = Uid,
        type = get,
        payload = #pb_trunc_whisper_keys_collection{collection = Collection}
    }.

check_iq_result(Result) ->
    #pb_iq{type = Type, payload = Payload} = Result,
    ?assertEqual(result, Type),
    ?assertEqual(undefined, Payload),
    ok.

check_iq_result_count(Result, ExpectedCount) ->
    #pb_iq{type = Type, payload = #pb_whisper_keys{action = WType, otp_key_count = Count}} = Result,
    ?assertEqual(result, Type),
    ?assertEqual(normal, WType),  % TODO: this will one day change to 'count'
    ?assertEqual(ExpectedCount, Count),
    ok.

check_wk_result(WK, Uid, IK, SK, OTK) ->
    ?assertEqual(normal, WK#pb_whisper_keys.action),
    ?assertEqual(base64:decode(IK), WK#pb_whisper_keys.identity_key),
    ?assertEqual(base64:decode(SK), WK#pb_whisper_keys.signed_key),
    ?assertEqual([base64:decode(OTK)], WK#pb_whisper_keys.one_time_keys),
    ?assertEqual(Uid, WK#pb_whisper_keys.uid),
    ok.

check_trunc_ik(WK, IK) ->
    TruncIK = WK#pb_trunc_whisper_keys.trunc_public_identity_key,
    IKBin = base64:decode(IK),
    TruncIKey1 = try enif_protobuf:decode(IKBin, pb_identity_key) of
        #pb_identity_key{public_key = IPublicKey} ->
            <<TruncIKey:?TRUNC_IKEY_LENGTH/binary, _Rest/binary>> = IPublicKey,
            TruncIKey
    catch Class : Reason : St ->
        ?assert(false)
    end,
    ?assertEqual(TruncIK, TruncIKey1),
    ok.
 

% TODO: test the subscription logic
% TODO: test the delete user logic
% TODO: test the notification logic for low number of otk

