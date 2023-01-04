%%%-------------------------------------------------------------------
%%% File: mod_katchup_contacts_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_katchup_contacts_tests).
-author('murali').

-include("packets.hrl").
-include("logger.hrl").
-include("contacts.hrl").
-include("tutil.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1001000000376503286">>).
-define(PHONE1, <<"14703381473">>).
-define(NAME1, <<"murali">>).
-define(UA1, <<"Katchup/iOS1.2.3">>).
-define(SYNC_ID1, <<"s1">>).
-define(BATCH_ID1, <<"1">>).

-define(UID2, <<"1001000000457424539">>).
-define(PHONE2, <<"14154121848">>).
-define(NAME2, <<"michael">>).
-define(UA2, <<"Katchup/iOS1.2.3">>).
-define(SYNC_ID2, <<"s2">>).

-define(UID3, <<"1001000000686861254">>).
-define(PHONE3, <<"12066585586">>).
-define(NAME3, <<"nikola">>).
-define(UA3, <<"Katchup/Android1.2.3">>).

-define(UID4, <<"10010000007785614784">>).
-define(PHONE4, <<"16507967982">>).
-define(NAME4, <<"vipin">>).
-define(UA4, <<"Katchup/iOS1.2.3">>).

-define(PHONE5, <<"1452">>).
-define(PHONE6, <<"16503878455">>).
-define(PHONE7, <<"16503363079">>).

-define(SERVER, <<"s.halloapp.net">>).


setup() ->
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_libphonenumber:start(undefined, []),
    mod_katchup_contacts:stop(?SERVER),
    mod_katchup_contacts:create_contact_options_table(),
    mod_katchup_contacts:start(?SERVER, []),
    tutil:setup([
        {start, stringprep},
        {redis, [redis_accounts, redis_contacts, redis_phone]}
    ]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                   helper functions                           %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


setup_accounts(Accounts) ->
    lists:foreach(
        fun([Uid, Phone, Name, UserAgent]) ->
            AppType = util_uid:get_app_type(Uid),
            ok = model_accounts:create_account(Uid, Phone, UserAgent),
            ok = model_accounts:set_name(Uid, Name),
            ok = model_phone:add_phone(Phone, AppType, Uid)
        end, Accounts),
    ok.


insert_contacts(Uid, Phones) ->
    ok = model_contacts:add_contacts(Uid, Phones),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


trigger_sync_error_test() ->
    setup(),
    tutil:meck_init(mod_katchup_contacts, hash_syncid_to_bucket, fun(_) -> 1 end),
    tutil:meck_init(model_accounts, is_first_sync_done, fun(_) -> true end),
    SyncErrorPercent = 25,
    ok = mod_katchup_contacts:set_full_sync_error_percent(SyncErrorPercent),
    ok = mod_katchup_contacts:set_full_sync_retry_time(?DEFAULT_SYNC_RETRY_TIME),
    SyncRetryTime1 = mod_katchup_contacts:get_full_sync_retry_time(),
    SyncErrorPercent1 = mod_katchup_contacts:get_full_sync_error_percent(),
    ?assertEqual(SyncRetryTime1, ?DEFAULT_SYNC_RETRY_TIME),
    ?assertEqual(SyncErrorPercent1, SyncErrorPercent),

    ok = mod_katchup_contacts:set_full_sync_error_percent(20),
    ok = mod_katchup_contacts:set_full_sync_retry_time(43200),
    SyncRetryTime2 = mod_katchup_contacts:get_full_sync_retry_time(),
    SyncErrorPercent2 = mod_katchup_contacts:get_full_sync_error_percent(),
    ?assertEqual(SyncRetryTime2, 43200),
    ?assertEqual(SyncErrorPercent2, 20),

    ResultIQ = mod_katchup_contacts:process_local_iq(#pb_iq{payload = #pb_contact_list{type = full}}),
    ?assertEqual(error, ResultIQ#pb_iq.type),
    #pb_contact_sync_error{retry_after_secs = RetryAfterSecs} = ResultIQ#pb_iq.payload,
    ?assert(RetryAfterSecs > 43200),
    ?assert(RetryAfterSecs < 43200 + ?MAX_JITTER_VALUE),
    tutil:meck_finish(mod_katchup_contacts),
    tutil:meck_finish(model_accounts),
    ok.


normalize_and_insert_contacts_with_syncid_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1],
        [?UID2, ?PHONE2, ?NAME2, ?UA2],
        [?UID3, ?PHONE3, ?NAME3, ?UA3]]),
    InputContacts = [
        #pb_contact{raw = ?PHONE2, normalized = undefined},
        #pb_contact{raw = ?PHONE3, normalized = undefined},
        #pb_contact{raw = ?PHONE4, normalized = undefined},
        #pb_contact{raw = ?PHONE5, normalized = undefined},
        #pb_contact{raw = ?PHONE6, normalized = undefined}
    ],
    insert_contacts(?UID2, [?PHONE1]),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 has UID1's phone number.
    %% UID1 does full sync with some phone numbers.

    ?assertEqual({ok, []}, model_contacts:get_contacts(?UID1)),
    ?assertEqual({ok, []}, model_contacts:get_sync_contacts(?UID1, ?SYNC_ID1)),

    %% Test output contact records.
    ActualContacts = mod_katchup_contacts:normalize_and_insert_contacts(?UID1, ?SERVER, InputContacts, ?SYNC_ID1),
    ExpectedContacts = [
        #pb_contact{raw = ?PHONE2, normalized = ?PHONE2, name = ?NAME2, avatar_id = <<>>, uid = ?UID2},
        #pb_contact{raw = ?PHONE3, normalized = ?PHONE3, name = ?NAME3, avatar_id = <<>>, uid = ?UID3},
        #pb_contact{raw = ?PHONE4, normalized = ?PHONE4, avatar_id = <<>>, uid = undefined},
        #pb_contact{raw = ?PHONE5, normalized = undefined, avatar_id = <<>>, uid = undefined},
        #pb_contact{raw = ?PHONE6, normalized = ?PHONE6, avatar_id = <<>>, uid = undefined}
    ],
    ?assertEqual(lists:sort(ExpectedContacts), lists:sort(ActualContacts)),

    %% Test if the phones are inserted correctly.
    {ok, ActualSyncPhones} = model_contacts:get_sync_contacts(?UID1, ?SYNC_ID1),
    ExpectedSyncPhones = [?PHONE2, ?PHONE3, ?PHONE4, ?PHONE6],
    ?assertEqual(lists:sort(ExpectedSyncPhones), lists:sort(ActualSyncPhones)),

    % %% Test if uid is correctly inserted for unregistered phone numbers.
    % {ok, ActualUids1} = model_contacts:get_potential_reverse_contact_uids(?PHONE4),
    % {ok, ActualUids2} = model_contacts:get_potential_reverse_contact_uids(?PHONE6),
    % ?assert(lists:member(?UID1, ActualUids1)),
    % ?assert(lists:member(?UID1, ActualUids2)),

    %% Ensure contacts are still empty and only inserted with syncid.
    ?assertEqual({ok, []}, model_contacts:get_contacts(?UID1)),
    ok.


normalize_and_insert_contacts_without_syncid_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1],
        [?UID2, ?PHONE2, ?NAME2, ?UA2],
        [?UID3, ?PHONE3, ?NAME3, ?UA3]]),
    InputContacts = [
        #pb_contact{raw = ?PHONE2},
        #pb_contact{raw = ?PHONE3},
        #pb_contact{raw = ?PHONE4},
        #pb_contact{raw = ?PHONE5}
    ],
    insert_contacts(?UID2, [?PHONE1]),
    insert_contacts(?UID1, [?PHONE6]),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 has UID1's phone number. UID1 has phone6.
    %% UID1 does incremental sync with some phone numbers.

    ?assertEqual({ok, [?PHONE6]}, model_contacts:get_contacts(?UID1)),

    %% Test output contact records.
    ActualContacts = mod_katchup_contacts:normalize_and_insert_contacts(?UID1, ?SERVER, InputContacts, undefined),
    ExpectedContacts = [
        #pb_contact{raw = ?PHONE2, normalized = ?PHONE2, name = ?NAME2, avatar_id = <<>>, uid = ?UID2},
        #pb_contact{raw = ?PHONE3, normalized = ?PHONE3, name = ?NAME3, avatar_id = <<>>, uid = ?UID3},
        #pb_contact{raw = ?PHONE4, normalized = ?PHONE4, avatar_id = <<>>, uid = undefined},
        #pb_contact{raw = ?PHONE5, normalized = undefined, avatar_id = <<>>, uid = undefined}
    ],
    ?assertEqual(lists:sort(ExpectedContacts), lists:sort(ActualContacts)),

    %% Test if the phones are inserted correctly.
    %% We wont have Phone4: because that number is not registered on our platform.
    %% Since there is no uid associated with Phone4.
    {ok, ActualPhones} = model_contacts:get_contacts(?UID1),
    ExpectedPhones = [?PHONE2, ?PHONE3, ?PHONE4, ?PHONE6],
    ?assertEqual(lists:sort(ExpectedPhones), lists:sort(ActualPhones)),

    % %% Test if uid is correctly inserted for unregistered phone numbers.
    % {ok, ActualUids} = model_contacts:get_potential_reverse_contact_uids(?PHONE4),
    % ?assert(lists:member(?UID1, ActualUids)),
    ok.


normalize_and_insert_contacts_with_blocklist_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1],
        [?UID2, ?PHONE2, ?NAME2, ?UA2],
        [?UID3, ?PHONE3, ?NAME3, ?UA3]]),
    InputContacts = [
        #pb_contact{raw = ?PHONE2},
        #pb_contact{raw = ?PHONE3}
    ],
    insert_contacts(?UID2, [?PHONE1]),
    ok = model_privacy:block_uid(?UID2, ?UID1),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 has UID1's phone number.
    %% UID2 blocks UID1

    %% Test output contact records.
    ActualContacts = mod_katchup_contacts:normalize_and_insert_contacts(?UID1, ?SERVER, InputContacts, undefined),
    ExpectedContacts = [
        #pb_contact{raw = ?PHONE2, normalized = ?PHONE2, name = ?NAME2, uid = ?UID2},
        #pb_contact{raw = ?PHONE3, normalized = ?PHONE3, name = ?NAME3, uid = ?UID3}
    ],
    ?assertEqual(lists:sort(ExpectedContacts), lists:sort(ActualContacts)),

    %% Test if the phones are inserted correctly.
    {ok, ActualPhones} = model_contacts:get_contacts(?UID1),
    ExpectedPhones = [?PHONE2, ?PHONE3],
    ?assertEqual(lists:sort(ExpectedPhones), lists:sort(ActualPhones)),
    ok.


finish_sync_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1],
        [?UID2, ?PHONE2, ?NAME2, ?UA2],
        [?UID3, ?PHONE3, ?NAME3, ?UA3]]),
    InputContacts = [
        #pb_contact{raw = ?PHONE2},
        #pb_contact{raw = ?PHONE3},
        #pb_contact{raw = ?PHONE4},
        #pb_contact{raw = ?PHONE5}
    ],
    insert_contacts(?UID2, [?PHONE1]),

    %% Check sync status of the uid.
    ?assertEqual(false, model_accounts:is_first_sync_done(?UID1)),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 has UID1's phone number.
    %% We insert some phone numbers to UID1 and then do a full sync which should replace some of them.

    ?assertEqual({ok, []}, model_contacts:get_contacts(?UID1)),
    insert_contacts(?UID1, [?PHONE6, ?PHONE7]),
    {ok, ActualPhones1} = model_contacts:get_contacts(?UID1),
    ExpectedPhones1 = [?PHONE6, ?PHONE7],
    ?assertEqual(lists:sort(ExpectedPhones1), lists:sort(ActualPhones1)),

    %% Ensure finish_sync properly happens and replaces old contacts.
    _ = mod_katchup_contacts:normalize_and_insert_contacts(?UID1, ?SERVER, InputContacts, ?SYNC_ID1),
    ok = mod_katchup_contacts:finish_sync(?UID1, ?SERVER, ?SYNC_ID1),
    {ok, ActualPhones2} = model_contacts:get_contacts(?UID1),
    ExpectedPhones2 = [?PHONE2, ?PHONE3, ?PHONE4],
    ?assertEqual(lists:sort(ExpectedPhones2), lists:sort(ActualPhones2)),

    %% Verify sync status
    ?assertEqual(true, model_accounts:is_first_sync_done(?UID1)),
    ok.


max_contacts_test() ->
    setup(),
    tutil:meck_init(model_contacts, count_sync_contacts, fun(_,_) -> {ok, ?MAX_CONTACTS - 1} end),
    tutil:meck_init(mod_katchup_contacts, finish_sync, fun(_,_,_) -> ok end),

    IQ =  #pb_iq{from_uid = ?UID1, type = set, payload = #pb_contact_list{type = full,
        contacts = [#pb_contact{raw = ?PHONE1}], sync_id = ?SYNC_ID1, batch_index = ?BATCH_ID1, is_last = false}},
    ResultIQ = mod_katchup_contacts:process_iq(IQ),
    ?assertEqual(error, ResultIQ#pb_iq.type),
    ?assertEqual(<<"too_many_contacts">>, ResultIQ#pb_iq.payload#pb_error_stanza.reason),
    tutil:meck_finish(model_contacts),
    tutil:meck_finish(mod_katchup_contacts),
    ok.

