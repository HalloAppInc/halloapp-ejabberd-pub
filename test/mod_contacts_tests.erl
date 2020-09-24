%%%-------------------------------------------------------------------
%%% File: mod_contacts_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_contacts_tests).
-author('murali').

-include("xmpp.hrl").
-include("logger.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(PHONE1, <<"14703381473">>).
-define(NAME1, <<"murali">>).
-define(UA1, <<"ios">>).
-define(SYNC_ID1, <<"s1">>).

-define(UID2, <<"1000000000457424539">>).
-define(PHONE2, <<"14154121848">>).
-define(NAME2, <<"michael">>).
-define(UA2, <<"ios">>).
-define(SYNC_ID2, <<"s2">>).

-define(UID3, <<"1000000000686861254">>).
-define(PHONE3, <<"12066585586">>).
-define(NAME3, <<"nikola">>).
-define(UA3, <<"android">>).

-define(UID4, <<"10000000007785614784">>).
-define(PHONE4, <<"16507967982">>).
-define(NAME4, <<"vipin">>).
-define(UA4, <<"ios">>).

-define(PHONE5, <<"1452">>).
-define(PHONE6, <<"16503878455">>).
-define(PHONE7, <<"16503363079">>).

-define(SERVER, <<"s.halloapp.net">>).


setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    mod_libphonenumber:start(undefined, []),
    clear(),
    ok.


clear() ->
    {ok, ok} = gen_server:call(redis_contacts_client, flushdb),
    {ok, ok} = gen_server:call(redis_friends_client, flushdb),
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb),
    {ok, ok} = gen_server:call(redis_phone_client, flushdb).


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


insert_contacts(Uid, Phones) ->
    ok = model_contacts:add_contacts(Uid, Phones),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


normalize_and_insert_contacts_with_syncid_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1],
        [?UID2, ?PHONE2, ?NAME2, ?UA2],
        [?UID3, ?PHONE3, ?NAME3, ?UA3]]),
    InputContacts = [
        #contact{raw = ?PHONE2},
        #contact{raw = ?PHONE3},
        #contact{raw = ?PHONE4},
        #contact{raw = ?PHONE5},
        #contact{raw = ?PHONE6}
    ],
    insert_contacts(?UID2, [?PHONE1]),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 has UID1's phone number.
    %% UID1 does full sync with some phone numbers.

    ?assertEqual({ok, []}, model_contacts:get_contacts(?UID1)),

    %% Test output contact records.
    ActualContacts = mod_contacts:normalize_and_insert_contacts(?UID1, ?SERVER, InputContacts, ?SYNC_ID1),
    ExpectedContacts = [
        #contact{raw = ?PHONE2, normalized = ?PHONE2, name = ?NAME2, avatarid = <<>>, userid = ?UID2, role = <<"friends">>},
        #contact{raw = ?PHONE3, normalized = ?PHONE3, name = ?NAME3, userid = ?UID3, role = <<"none">>},
        #contact{raw = ?PHONE4, normalized = ?PHONE4, role = <<"none">>},
        #contact{raw = ?PHONE5},
        #contact{raw = ?PHONE6, normalized = ?PHONE6, role = <<"none">>}
    ],
    ?assertEqual(ExpectedContacts, ActualContacts),

    %% Test if the phones are inserted correctly.
    {ok, ActualSyncPhones} = model_contacts:get_sync_contacts(?UID1, ?SYNC_ID1),
    ExpectedSyncPhones = [?PHONE2, ?PHONE3],
    ?assertEqual(lists:sort(ExpectedSyncPhones), lists:sort(ActualSyncPhones)),

    %% Test if uid is correctly inserted for unregistered phone numbers.
    {ok, ActualUids1} = model_contacts:get_potential_reverse_contact_uids(?PHONE4),
    {ok, ActualUids2} = model_contacts:get_potential_reverse_contact_uids(?PHONE6),
    ?assert(lists:member(?UID1, ActualUids1)),
    ?assert(lists:member(?UID1, ActualUids2)),

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
        #contact{raw = ?PHONE2},
        #contact{raw = ?PHONE3},
        #contact{raw = ?PHONE4},
        #contact{raw = ?PHONE5}
    ],
    insert_contacts(?UID2, [?PHONE1]),
    insert_contacts(?UID1, [?PHONE6]),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 has UID1's phone number. UID1 has phone6.
    %% UID1 does incremental sync with some phone numbers.

    ?assertEqual({ok, [?PHONE6]}, model_contacts:get_contacts(?UID1)),

    %% Test output contact records.
    ActualContacts = mod_contacts:normalize_and_insert_contacts(?UID1, ?SERVER, InputContacts, undefined),
    ExpectedContacts = [
        #contact{raw = ?PHONE2, normalized = ?PHONE2, name = ?NAME2, avatarid = <<>>, userid = ?UID2, role = <<"friends">>},
        #contact{raw = ?PHONE3, normalized = ?PHONE3, name = ?NAME3, userid = ?UID3, role = <<"none">>},
        #contact{raw = ?PHONE4, normalized = ?PHONE4, role = <<"none">>},
        #contact{raw = ?PHONE5}
    ],
    ?assertEqual(ExpectedContacts, ActualContacts),

    %% Test if the phones are inserted correctly.
    %% We wont have Phone4: because that number is not registered on our platform.
    %% Since there is no uid associated with Phone4.
    {ok, ActualPhones} = model_contacts:get_contacts(?UID1),
    ExpectedPhones = [?PHONE2, ?PHONE3, ?PHONE6],
    ?assertEqual(lists:sort(ExpectedPhones), lists:sort(ActualPhones)),

    %% Test if uid is correctly inserted for unregistered phone numbers.
    {ok, ActualUids} = model_contacts:get_potential_reverse_contact_uids(?PHONE4),
    ?assert(lists:member(?UID1, ActualUids)),
    ok.


normalize_and_insert_contacts_with_blocklist_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1],
        [?UID2, ?PHONE2, ?NAME2, ?UA2],
        [?UID3, ?PHONE3, ?NAME3, ?UA3]]),
    InputContacts = [
        #contact{raw = ?PHONE2},
        #contact{raw = ?PHONE3}
    ],
    insert_contacts(?UID2, [?PHONE1]),
    ok = model_privacy:block_uid(?UID2, ?UID1),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 has UID1's phone number.
    %% UID2 blocks UID1, now when UID1 syncs and adds UID2's number: they still should not be friends.

    %% Test output contact records.
    ActualContacts = mod_contacts:normalize_and_insert_contacts(?UID1, ?SERVER, InputContacts, undefined),
    ExpectedContacts = [
        #contact{raw = ?PHONE2, normalized = ?PHONE2, name = ?NAME2, userid = ?UID2, role = <<"none">>},
        #contact{raw = ?PHONE3, normalized = ?PHONE3, name = ?NAME3, userid = ?UID3, role = <<"none">>}
    ],
    ?assertEqual(ExpectedContacts, ActualContacts),

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
        #contact{raw = ?PHONE2},
        #contact{raw = ?PHONE3},
        #contact{raw = ?PHONE4},
        #contact{raw = ?PHONE5}
    ],
    insert_contacts(?UID2, [?PHONE1]),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 has UID1's phone number.
    %% We insert some phone numbers to UID1 and then do a full sync which should replace some of them.

    ?assertEqual({ok, []}, model_contacts:get_contacts(?UID1)),
    insert_contacts(?UID1, [?PHONE6, ?PHONE7]),
    {ok, ActualPhones1} = model_contacts:get_contacts(?UID1),
    ExpectedPhones1 = [?PHONE6, ?PHONE7],
    ?assertEqual(lists:sort(ExpectedPhones1), lists:sort(ActualPhones1)),

    %% Ensure finish_sync properly happens and replaces old contacts.
    _ = mod_contacts:normalize_and_insert_contacts(?UID1, ?SERVER, InputContacts, ?SYNC_ID1),
    ok = mod_contacts:finish_sync(?UID1, ?SERVER, ?SYNC_ID1),
    {ok, ActualPhones2} = model_contacts:get_contacts(?UID1),
    ExpectedPhones2 = [?PHONE2, ?PHONE3],
    ?assertEqual(lists:sort(ExpectedPhones2), lists:sort(ActualPhones2)),

    %% Ensure friend relationships are correctly inserted.
    {ok, ActualFriends} = model_friends:get_friends(?UID1),
    ExpectedFriends = [?UID2],
    ?assertEqual(ExpectedFriends, ActualFriends),
    ok.


block_uids_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1],
        [?UID2, ?PHONE2, ?NAME2, ?UA2]]),

    insert_contacts(?UID2, [?PHONE1, ?PHONE3]),
    insert_contacts(?UID1, [?PHONE2, ?PHONE3]),
    model_friends:add_friend(?UID1, ?UID2),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 and UID1's are friends.
    %% When one of them blocks the other, friend relationships must be removed.

    ?assertEqual({ok, [?UID2]}, model_friends:get_friends(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_friends:get_friends(?UID2)),
    mod_contacts:block_uids(?UID1, ?SERVER, [?UID2]),
    ?assertEqual({ok, []}, model_friends:get_friends(?UID1)),
    ?assertEqual({ok, []}, model_friends:get_friends(?UID2)),
    ok.


unblock_uids_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1],
        [?UID2, ?PHONE2, ?NAME2, ?UA2]]),

    insert_contacts(?UID2, [?PHONE1, ?PHONE3]),
    insert_contacts(?UID1, [?PHONE2, ?PHONE3]),
    model_privacy:block_uid(?UID1, ?UID2),
    model_privacy:block_uid(?UID2, ?UID1),

    %% setup here is that there are three accounts UID1, UID2 and UID3.
    %% UID2 and UID1's are not friends, since both of them blocked each other.
    %% If one of them unblocks the other: they still are not friends, since the other block still exists.
    %% Only when both unblock each other, friend relationships must be re-added.

    ?assertEqual({ok, []}, model_friends:get_friends(?UID1)),
    ?assertEqual({ok, []}, model_friends:get_friends(?UID2)),
    model_privacy:unblock_uid(?UID1, ?UID2),
    mod_contacts:unblock_uids(?UID1, ?SERVER, [?UID2]),
    %% UID1 unblocks UID2: but UID2 still blocks UID1: so they should still not be friends.
    ?assertEqual({ok, []}, model_friends:get_friends(?UID1)),
    ?assertEqual({ok, []}, model_friends:get_friends(?UID2)),

    model_privacy:unblock_uid(?UID2, ?UID1),
    mod_contacts:unblock_uids(?UID2, ?SERVER, [?UID1]),
    %% Now UID2 unblocks UID1: so now they should be friends.
    ?assertEqual({ok, [?UID2]}, model_friends:get_friends(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_friends:get_friends(?UID2)),
    ok.


new_user_invite_notification_test() ->
    setup(),
    setup_accounts([[?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    %% UID1 invites PHONE2, invite goes from the client and the server does not know about
    %% PHONE2
    {?PHONE2, ok, undefined} = mod_invites:request_invite(?UID1, ?PHONE2),
 
    %% PHONE2 joins as UID2. 
    setup_accounts([[?UID2, ?PHONE2, ?NAME2, ?UA2]]),

    %% UID2 uploads his addressbook and that has UID1's phone number.
    InputContacts = [#contact{raw = ?PHONE1}],

    mod_contacts:normalize_and_insert_contacts(?UID2, ?SERVER, InputContacts, ?SYNC_ID2),

    meck:new(ejabberd_router),
    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            #message{type = MsgType, sub_els = SubEls} = Packet,
            #contact_list{contacts = [Contact]} = SubEls,
            #contact{name = Name} = Contact,
            ?assertEqual(Name, ?NAME2),
            ?assertEqual(MsgType, headline),
            ok
        end),

    mod_contacts:finish_sync(?UID2, ?SERVER, ?SYNC_ID2),
    ?assertEqual({ok, [?PHONE1]}, model_contacts:get_contacts(?UID2)),

    meck:validate(ejabberd_router),
    meck:unload(ejabberd_router),
    ok.

