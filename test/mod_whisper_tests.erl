%%%-------------------------------------------------------------------
%%% File: mod_whisper_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_whisper_tests).
-author("nikola").

-include("xmpp.hrl").
-include("whisper.hrl").
-include("account_test_data.hrl").
-include_lib("eunit/include/eunit.hrl").


setup() ->
    tutil:setup(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    clear(),
    ok.

clear() ->
    tutil:cleardb(redis_whisper).


gen_key64_test() ->
    ?assertEqual(12, byte_size(gen_keyb64(12))),
    ?assertEqual(16, byte_size(gen_keyb64(13))),
    ?assertEqual(16, byte_size(gen_keyb64(14))),
    ?assertEqual(16, byte_size(gen_keyb64(15))),
    ?assertEqual(16, byte_size(gen_keyb64(16))),
    ok.

gen_otk_test() ->
    ?assertEqual(5, length(gen_otk(5, 10))),
    [Key | _Rest] = gen_otk(5, 12),
    ?assertEqual(12, byte_size(Key)),
    ok.

check_whisper_keys_test() ->
    ?assertEqual(ok, mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(64), gen_otk(10, 32))),
    ok.

bad_base64_key_test() ->
    ?assertEqual(
        {error, bad_base64_key},
        mod_whisper:check_whisper_keys(<<"()">>, gen_keyb64(64), gen_otk(10, 32))),
    ?assertEqual(
        {error, bad_base64_key},
        mod_whisper:check_whisper_keys(gen_keyb64(64), <<"()">>, gen_otk(10, 32))),
    ?assertEqual(
        {error, bad_base64_one_time_keys},
        mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(64), [<<"()">> | gen_otk(10, 32)])),
    ok.

missing_identity_key_test() ->
    ?assertEqual({error, missing_identity_key},
        mod_whisper:check_whisper_keys(<<>>, gen_keyb64(64), gen_otk(10, 32))),
    ok.

missing_signed_key_test() ->
    ?assertEqual({error, missing_signed_key},
        mod_whisper:check_whisper_keys(gen_keyb64(64), <<>>, gen_otk(10, 32))),
    ok.

too_big_key_test() ->
    ?assertEqual({error, too_big_identity_key},
        mod_whisper:check_whisper_keys(gen_keyb64(?MAX_KEY_SIZE + 10), gen_keyb64(64), gen_otk(10, 32))),
    ?assertEqual({error, too_big_signed_key},
        mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(?MAX_KEY_SIZE + 10), gen_otk(10, 32))),
    ok.

too_small_key_test() ->
    ?assertEqual({error, too_small_identity_key},
        mod_whisper:check_whisper_keys(gen_keyb64(?MIN_KEY_SIZE - 5), gen_keyb64(64), gen_otk(10, 32))),
    ?assertEqual({error, too_small_signed_key},
        mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(?MIN_KEY_SIZE - 5), gen_otk(10, 32))),
    ok.

check_length_of_otks_test() ->
    ?assertEqual(ok,
        mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(64), gen_otk(?MIN_OTK_LENGTH, 32))),
    ?assertEqual({error, too_few_one_time_keys},
        mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(64), gen_otk(?MIN_OTK_LENGTH - 1, 32))),
    ?assertEqual(ok,
        mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(64), gen_otk(?MAX_OTK_LENGTH, 32))),
    ?assertEqual({error, too_many_one_time_keys},
        mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(64), gen_otk(?MAX_OTK_LENGTH + 1, 32))),
    ok.

check_size_of_otks_test() ->
    ?assertEqual({error, too_big_one_time_keys},
        mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(64), gen_otk(?MIN_OTK_LENGTH, ?MAX_KEY_SIZE + 10))),
    ?assertEqual({error, too_small_one_time_keys},
        mod_whisper:check_whisper_keys(gen_keyb64(64), gen_keyb64(64), gen_otk(?MIN_OTK_LENGTH, ?MIN_KEY_SIZE - 10))),
    ok.


%% -------------------------------------------- %%
%% Tests for IQ API
%% --------------------------------------------	%%

set_whisper_keys_test() ->
    setup(),
    {IK, SK, OTKS} = {gen_keyb64(64), gen_keyb64(64), gen_otk(16, 64)},
    Result = mod_whisper:process_local_iq(create_set_whisper_keys_iq(
        ?UID1, IK, SK, OTKS)),
    check_iq_result(Result),
    {ok, WKS} = model_whisper_keys:get_key_set_without_otp(?UID1),
    ?assertEqual(IK, WKS#user_whisper_key_set.identity_key),
    ?assertEqual(SK, WKS#user_whisper_key_set.signed_key),
    ?assertEqual({ok, 16}, model_whisper_keys:count_otp_keys(?UID1)),
    ok.

add_whisper_keys_test() ->
    setup(),
    {IK, SK, OTKS} = {gen_keyb64(64), gen_keyb64(64), gen_otk(16, 64)},
    Result = mod_whisper:process_local_iq(create_set_whisper_keys_iq(
        ?UID1, IK, SK, OTKS)),
    check_iq_result(Result),

    ?assertEqual({ok, 16}, model_whisper_keys:count_otp_keys(?UID1)),
    OTKS2 = gen_otk(16, 64),
    Result2 = mod_whisper:process_local_iq(create_add_whisper_keys_iq(
        ?UID1, OTKS2)),
    ?assertEqual({ok, 32}, model_whisper_keys:count_otp_keys(?UID1)),
    check_iq_result(Result2),
    ok.

count_whisper_keys_test() ->
    setup(),
    {IK, SK, OTKS} = {gen_keyb64(64), gen_keyb64(64), gen_otk(16, 64)},
    Result = mod_whisper:process_local_iq(create_set_whisper_keys_iq(
        ?UID1, IK, SK, OTKS)),
    check_iq_result(Result),

    ?assertEqual({ok, 16}, model_whisper_keys:count_otp_keys(?UID1)),
    Result2 = mod_whisper:process_local_iq(create_count_whisper_keys_iq(
        ?UID1)),
    check_iq_result_count(Result2, 16),
    ok.

get_whisper_keys_test() ->
    setup(),
    {IK, SK, OTKS} = {gen_keyb64(64), gen_keyb64(64), gen_otk(16, 64)},
    Result = mod_whisper:process_local_iq(create_set_whisper_keys_iq(
        ?UID1, IK, SK, OTKS)),
    check_iq_result(Result),

    ?assertEqual({ok, 16}, model_whisper_keys:count_otp_keys(?UID1)),
    Result2 = mod_whisper:process_local_iq(create_get_whisper_keys_iq(
        ?UID2, ?UID1)),
    check_iq_result_get(Result2, ?UID1, IK, SK, lists:nth(1, OTKS)),
    ?assertEqual({ok, 15}, model_whisper_keys:count_otp_keys(?UID1)),
    ok.

%% -------------------------------------------- %%
%% Helper functions
%% --------------------------------------------	%%

gen_otk(N, Bytes) ->
    [gen_keyb64(Bytes) || _X <- lists:seq(1, N)].

gen_keyb64(Bytes) ->
    base64:encode(gen_key(round(math:ceil(Bytes * 3 / 4)))).

gen_key(Bytes) ->
    crypto:strong_rand_bytes(Bytes).

create_set_whisper_keys_iq(Uid, IdentityKey, SignedKey, OneTimeKeys) ->
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [#whisper_keys{
            type = set,
            identity_key = IdentityKey,
            signed_key = SignedKey,
            one_time_keys = OneTimeKeys}]
    }.

create_add_whisper_keys_iq(Uid, OneTimeKeys) ->
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [#whisper_keys{
            type = add,
            one_time_keys = OneTimeKeys}]
    }.

create_count_whisper_keys_iq(Uid) ->
    #iq{
        from = #jid{luser = Uid},
        type = get,
        sub_els = [#whisper_keys{
            type = count}]
    }.

create_get_whisper_keys_iq(Uid, Ouid) ->
    #iq{
        from = #jid{luser = Uid},
        type = get,
        sub_els = [#whisper_keys{
            uid = Ouid,
            type = get}]
    }.

check_iq_result(Result) ->
    #iq{type = Type, sub_els = SubEls} = Result,
    ?assertEqual(result, Type),
    ?assertEqual([], SubEls),
    ok.

check_iq_result_count(Result, ExpectedCount) ->
    #iq{type = Type, sub_els = [#whisper_keys{type = WType, otp_key_count = Count}]} = Result,
    ?assertEqual(result, Type),
    ?assertEqual(normal, WType),  % TODO: this will one day change to 'count'
    ?assertEqual(integer_to_binary(ExpectedCount), Count),
    ok.

check_iq_result_get(Result, Uid, IK, SK, OTK) ->
    #iq{type = Type, sub_els = [#whisper_keys{type = normal} = WK]} = Result,
    ?assertEqual(result, Type),
    ?assertEqual(IK, WK#whisper_keys.identity_key),
    ?assertEqual(SK, WK#whisper_keys.signed_key),
    ?assertEqual([OTK], WK#whisper_keys.one_time_keys),
    ?assertEqual(Uid, WK#whisper_keys.uid),
    ok.



% TODO: test the subscription logic
% TODO: test the delete user logic
% TODO: test the notification logic for low number of otk

