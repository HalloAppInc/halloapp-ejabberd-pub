%%%----------------------------------------------------------------------
%%% File    : mod_contacts.erl
%%%
%%% Copyright (C) 2020 HalloApp Inc.
%%%
%%%----------------------------------------------------------------------

-module(mod_contacts).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("ha_namespaces.hrl").
-include("time.hrl").

-define(SALT_LENGTH_BYTES, 32).
-define(PROBE_HASH_LENGTH_BYTES, 2).
-define(MAX_INVITERS, 3).
-define(NOTIFICATION_EXPIRY_MS, 1 * ?WEEKS_MS).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% IQ handlers and hooks.
-export([
    process_local_iq/1, 
    remove_user/2, 
    register_user/3, 
    re_register_user/3,
    block_uids/3,
    unblock_uids/3,
    trigger_full_contact_sync/1
]).

-export([
    finish_sync/3
]).

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_contact_list, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 100),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(block_uids, Host, ?MODULE, block_uids, 50),
    ejabberd_hooks:add(unblock_uids, Host, ?MODULE, unblock_uids, 50),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_contact_list),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 100),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(block_uids, Host, ?MODULE, block_uids, 50),
    ejabberd_hooks:delete(unblock_uids, Host, ?MODULE, unblock_uids, 50),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


%%====================================================================
%% iq handlers
%%====================================================================

process_local_iq(#pb_iq{from_uid = UserId, type = set,
        payload = #pb_contact_list{type = full, contacts = Contacts, sync_id = SyncId, batch_index = Index,
            is_last = Last}} = IQ) ->
    Server = util:get_host(),
    StartTime = os:system_time(microsecond), 
    ?INFO("Full contact sync Uid: ~p, sync_id: ~p, batch_index: ~p, is_last: ~p, num_contacts: ~p",
            [UserId, SyncId, Index, Last, length(Contacts)]),
    stat:count("HA/contacts", "sync_full_contacts", length(Contacts)),
    case SyncId of
        undefined ->
            ?WARNING("undefined sync_id, iq: ~p", [IQ]),
            ResultIQ = pb:make_error(IQ, util:err(undefined_syncid));
        _ ->
            count_full_sync(Index),
            ResultIQ = pb:make_iq_result(IQ, #pb_contact_list{sync_id = SyncId, type = normal,
                    contacts = normalize_and_insert_contacts(UserId, Server, Contacts, SyncId)})
    end,
    case Last of
        false -> ok;
        true ->
            stat:count("HA/contacts", "sync_full_finish"),
            %% Unfinished finish_sync will need the next full sync to send all the relevant
            %% notifications (some might be sent more than once).
            spawn(?MODULE, finish_sync, [UserId, Server, SyncId])
    end,
    EndTime = os:system_time(microsecond),
    T = EndTime - StartTime,
    ?INFO("Time taken: ~w us", [T]),
    ResultIQ;

process_local_iq(#pb_iq{from_uid = UserId, type = set,
        payload = #pb_contact_list{type = delta, contacts = Contacts,
            batch_index = _Index, is_last = _Last}} = IQ) ->
    Server = util:get_host(),
    pb:make_iq_result(IQ, #pb_contact_list{type = normal,
                    contacts = handle_delta_contacts(UserId, Server, Contacts)}).


%% TODO(murali@): update remove_user to have phone in the hook arguments.
-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, Server) ->
    {ok, Phone} = model_accounts:get_phone(Uid),
    remove_all_contacts(Uid, Server, true),
    {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
    lists:foreach(
        fun(ContactId) ->
            notify_contact_about_user(<<>>, Phone, ContactId, none, normal, delete_notice)
        end, ContactUids),
    ok.


-spec re_register_user(UserId :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(UserId, Server, _Phone) ->
    remove_all_contacts(UserId, Server, false).


%% TODO: Delay notifying the users about their contact to reduce unnecessary messages to clients.
-spec register_user(UserId :: binary(), Server :: binary(), Phone :: binary()) -> ok.
register_user(UserId, Server, Phone) ->
    {ok, PotentialContactUids} = model_contacts:get_potential_reverse_contact_uids(Phone),
    lists:foreach(
        fun(ContactId) ->
            probe_contact_about_user(UserId, Phone, Server, ContactId)
        end, PotentialContactUids),

    %% Send notifications to relevant users.
    send_new_user_notifications(UserId, Phone),
    ok.


-spec send_new_user_notifications(UserId :: binary(), UserPhone :: binary()) -> ok.
send_new_user_notifications(UserId, Phone) ->
    {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
    %% Fetch all inviter phone numbers.
    {ok, InvitersList} = model_invites:get_inviters_list(Phone),
    InviterUidSet = sets:from_list([InviterUid || {InviterUid, _} <- InvitersList]),

    %% Send only one notification per contact - inviter/contact based.
    lists:foreach(
            fun(ContactId) ->
                case sets:is_element(ContactId, InviterUidSet) of
                    true ->
                        ?INFO("Notify Inviter: ~p about user: ~p joining", [ContactId, UserId]),
                        notifications_util:send_contact_notification(UserId, Phone,
                                ContactId, none, normal, inviter_notice);
                    false ->
                        ?INFO("Notify Contact: ~p about user: ~p joining", [ContactId, UserId]),
                        notifications_util:send_contact_notification(UserId, Phone,
                                ContactId, none, normal, contact_notice)
                end
            end, ContactUids),
    ok.


-spec block_uids(Uid :: binary(), Server :: binary(), Ouids :: list(binary())) -> ok.
block_uids(Uid, Server, Ouids) ->
    %% TODO(murali@): Add batched api for friends.
    lists:foreach(
        fun(Ouid) ->
            case model_accounts:get_phone(Ouid) of
                {ok, OPhone} ->
                    remove_friend(Uid, Server, Ouid),
                    notify_contact_about_user(Ouid, OPhone, Uid, none);
                {error, missing} -> ok
            end
        end, Ouids),
    ok.


-spec unblock_uids(Uid :: binary(), Server :: binary(), Ouids :: list(binary())) -> ok.
unblock_uids(Uid, Server, Ouids) ->
    {ok, Phone} = model_accounts:get_phone(Uid),
    {ok, ReverseBlockList} = model_privacy:get_blocked_by_uids(Uid),
    ReverseBlockSet = sets:from_list(ReverseBlockList),
    lists:foreach(
        fun(Ouid) ->
            case model_accounts:get_phone(Ouid) of
                {ok, OPhone} ->
                    %% We now know, that Uid unblocked Ouid.
                    %% So, try and add a friend relationship between Ouid and Uid.
                    %% Ouid and Uid will be friends if both of them have each others as contacts and
                    %% if Ouid did not block Uid.
                    case model_contacts:is_contact(Uid, OPhone) andalso
                            model_contacts:is_contact(Ouid, Phone) andalso
                            not sets:is_element(Ouid, ReverseBlockSet) of
                        true ->
                            WasBlocked = true,
                            add_friend(Uid, Server, Ouid, WasBlocked),
                            notify_contact_about_user(Ouid, OPhone, Uid, friends);
                        false ->
                            notify_contact_about_user(Ouid, OPhone, Uid, none)
                    end;
                {error, missing} -> ok
            end
        end, Ouids),
    ok.


-spec trigger_full_contact_sync(Uid :: binary()) -> ok.
trigger_full_contact_sync(Uid) ->
    Server = util:get_host(),
    ?INFO("Trigger full contact sync for user: ~p", [Uid]),
    send_probe_message(<<>>, <<>>, Uid, Server),
    ok.


%%====================================================================
%% internal functions
%%====================================================================


-spec count_full_sync(Index :: non_neg_integer()) -> ok.
count_full_sync(0) ->
    stat:count("HA/contacts", "sync_full_start"),
    stat:count("HA/contacts", "sync_full_part"),
    ok;
count_full_sync(_Index) ->
    stat:count("HA/contacts", "sync_full_part"),
    ok.


-spec get_role_value(atom()) -> atom().
get_role_value(true) -> friends;
get_role_value(false) -> none.


-spec get_phone(UserId :: binary()) -> binary() | undefined.
get_phone(UserId) ->
    case model_accounts:get_phone(UserId) of
        {ok, Phone} -> Phone;
        {error, missing} -> undefined
    end.

-spec handle_delta_contacts(UserId :: binary(), Server :: binary(),
        Contacts :: [pb_contact()]) -> [pb_contact()].
handle_delta_contacts(UserId, Server, Contacts) ->
    {DeleteContactsList, AddContactsList} = lists:partition(
            fun(#pb_contact{action = Action}) ->
                Action =:= delete
            end, Contacts),
    DeleteContactPhones = lists:foldl(
            fun(#pb_contact{normalized = undefined}, Acc) ->
                    ?ERROR("Uid: ~s, UserId, sending invalid_contacts", [UserId]),
                    %% Added on 2020-12-11 because of some client bug.
                    %% Clients must be fixing this soon. Check again in 2months.
                    Acc;
                (#pb_contact{normalized = Normalized}, Acc) ->
                    [Normalized | Acc]
            end, [], DeleteContactsList),
    remove_contact_phones(UserId, DeleteContactPhones),
    AddContacts = normalize_and_insert_contacts(UserId, Server, AddContactsList, undefined),
    AddContacts.


-spec remove_all_contacts(UserId :: binary(), Server :: binary(), IsAccountDeleted :: boolean()) -> ok.
remove_all_contacts(UserId, _Server, IsAccountDeleted) ->
    {ok, ContactPhones} = model_contacts:get_contacts(UserId),
    remove_contact_phones(UserId, ContactPhones, IsAccountDeleted).


-spec finish_sync(UserId :: binary(), Server :: binary(), SyncId :: binary()) -> ok.
finish_sync(UserId, _Server, SyncId) ->
    StartTime = os:system_time(microsecond), 
    UserPhone = get_phone(UserId),
    {ok, OldContactList} = model_contacts:get_contacts(UserId),
    {ok, NewContactList} = model_contacts:get_sync_contacts(UserId, SyncId),
    {ok, OldReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    {ok, BlockedUids} = model_privacy:get_blocked_uids(UserId),
    {ok, BlockedByUids} = model_privacy:get_blocked_by_uids(UserId),
    {ok, OldFriendUids} = model_friends:get_friends(UserId),
    OldFriendUidSet = sets:from_list(OldFriendUids),
    OldContactSet = sets:from_list(OldContactList),
    NewContactSet = sets:from_list(NewContactList),
    DeleteContactSet = sets:subtract(OldContactSet, NewContactSet),
    AddContactSet = sets:subtract(NewContactSet, OldContactSet),
    OldReverseContactSet = sets:from_list(OldReverseContactList),
    BlockedUidSet = sets:from_list(BlockedUids ++ BlockedByUids),
    ?INFO("Full contact sync stats: uid: ~p, old_contacts: ~p, new_contacts: ~p, "
            "add_contacts: ~p, delete_contacts: ~p", [UserId, sets:size(OldContactSet),
            sets:size(NewContactSet), sets:size(AddContactSet), sets:size(DeleteContactSet)]),
    ?INFO("Full contact sync: uid: ~p, add_contacts: ~p, delete_contacts: ~p",
                [UserId, sets:to_list(AddContactSet), sets:to_list(DeleteContactSet)]),
    remove_contacts_and_notify(UserId, UserPhone,
            sets:to_list(DeleteContactSet), OldReverseContactSet, false),
    %% Convert Phones to pb_contact records.
    AddContacts = lists:map(
            fun(ContactPhone) ->
                #pb_contact{normalized = ContactPhone}
            end, sets:to_list(AddContactSet)),

    %% Obtain UserIds for all the normalized phone numbers.
    {_UnRegisteredContacts, RegisteredContacts} = obtain_user_ids(AddContacts),
    %% Set friend relationships for registered contacts and notify.
    {_NonFriendContacts, _FriendContacts} = obtain_roles_and_notify(UserId, UserPhone,
            RegisteredContacts, OldContactSet, OldReverseContactSet, OldFriendUidSet, BlockedUidSet, true),

    %% finish_sync will add various contacts and their reverse mapping in the db.
    model_contacts:finish_sync(UserId, SyncId),

    %% Check if any new contacts were uploaded in this sync - if yes - then update sync status.
    %% checking this will help us set this field only for non-empty full contact sync.
    case NewContactList =/= [] of
        true ->
            {ok, Result} = model_accounts:mark_first_sync_done(UserId),
            ?INFO("Uid: ~p, mark_first_sync_done: ~p", [UserId, Result]);
        false -> ok
    end,

    EndTime = os:system_time(microsecond),
    T = EndTime - StartTime,
    ?INFO("Time taken: ~w us", [T]),
    ok.


%%====================================================================
%% add_contact
%%====================================================================


-spec normalize_and_insert_contacts(UserId :: binary(), Server :: binary(),
        Contacts :: [pb_contact()], SyncId :: undefined | binary()) -> [pb_contact()].
normalize_and_insert_contacts(UserId, _Server, Contacts, SyncId) ->
    UserPhone = get_phone(UserId),
    UserRegionId = mod_libphonenumber:get_region_id(UserPhone),
    {ok, OldContactList} = model_contacts:get_contacts(UserId),
    {ok, OldReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    {ok, BlockedUids} = model_privacy:get_blocked_uids(UserId),
    {ok, BlockedByUids} = model_privacy:get_blocked_by_uids(UserId),
    {ok, OldFriendUids} = model_friends:get_friends(UserId),
    OldFriendUidSet = sets:from_list(OldFriendUids),
    OldContactSet = sets:from_list(OldContactList),
    OldReverseContactSet = sets:from_list(OldReverseContactList),
    BlockedUidSet = sets:from_list(BlockedUids ++ BlockedByUids),

    %% If it is a delta-sync - undefined syncId, we need to notify contacts,
    %% otherwise, we will notify them at the end in finish_sync(...)
    ShouldNotify = case SyncId of
        undefined -> true;
        _ -> false
    end,

    %% Firstly, normalize all phone numbers received.
    {UnNormalizedContacts1, NormalizedContacts1} = normalize_contacts(Contacts, UserRegionId),
    %% Obtain UserIds for all the normalized phone numbers.
    {UnRegisteredContacts1, RegisteredContacts1} = obtain_user_ids(NormalizedContacts1),
    %% Obtain potential_friends for unregistered contacts.
    UnRegisteredContacts2 = obtain_potential_friends(UserId, UnRegisteredContacts1),
    %% Obtain names for all registered contacts.
    RegisteredContacts2 = obtain_names(RegisteredContacts1),
    %% Set friend relationships for registered contacts and notify.
    {NonFriendContacts1, FriendContacts1} = obtain_roles_and_notify(UserId, UserPhone,
            RegisteredContacts2, OldContactSet, OldReverseContactSet, OldFriendUidSet, BlockedUidSet, ShouldNotify),
    %% Obtain avatar_id for all friend contacts.
    FriendContacts2 = obtain_avatar_ids(FriendContacts1),

    NormalizedPhoneNumbers = extract_normalized(NormalizedContacts1),
    UnRegisteredPhoneNumbers = extract_normalized(UnRegisteredContacts2),

    %% Call the batched API to insert UserId for the unregistered phone numbers.
    model_contacts:add_reverse_hash_contacts(UserId, UnRegisteredPhoneNumbers),
    %% Call the batched API to insert the normalized phone numbers.
    case SyncId of
        undefined -> model_contacts:add_contacts(UserId, NormalizedPhoneNumbers);
        _ -> model_contacts:sync_contacts(UserId, SyncId, NormalizedPhoneNumbers)
    end,

    %% Return all contacts. Includes the following:
    %% - un-normalized phone numbers
    %% - normalized but unregistered contacts
    %% - registered but non-friend contacts
    %% - registered and friend contacts.
    UnNormalizedContacts1 ++ UnRegisteredContacts2 ++ NonFriendContacts1 ++ FriendContacts2.


%% Splits contact records to unnormalized and normalized contacts.
%% Sets normalized field for normalized contacts.
-spec normalize_contacts(Contacts :: [pb_contact()],
        UserRegionId :: binary()) -> {[pb_contact()], [pb_contact()]}.
normalize_contacts(Contacts, UserRegionId) ->
    lists:foldl(
        fun(#pb_contact{raw = undefined} = Contact, {UnNormAcc, NormAcc}) ->
                ?WARNING("Invalid contact: raw is undefined"),
                NewContact = Contact#pb_contact{
                    role = none,
                    uid = undefined,
                    normalized = undefined},
                {[NewContact | UnNormAcc], NormAcc};
            (#pb_contact{raw = RawPhone} = Contact, {UnNormAcc, NormAcc}) ->
                ContactPhone = mod_libphonenumber:normalize(RawPhone, UserRegionId),
                case ContactPhone of
                    undefined ->
                        stat:count("HA/contacts", "normalize_fail"),
                        NewContact = Contact#pb_contact{
                            role = none,
                            uid = undefined,
                            normalized = undefined},
                        {[NewContact | UnNormAcc], NormAcc};
                    _ ->
                        stat:count("HA/contacts", "normalize_success"),
                        NewContact = Contact#pb_contact{normalized = ContactPhone},
                        {UnNormAcc, [NewContact | NormAcc]}
                end
        end, {[], []}, Contacts).


%% Splits normalized contact records to unregistered and registered contacts.
%% Sets userids for registered contacts.
-spec obtain_user_ids(NormContacts :: [pb_contact()]) -> {[pb_contact()], [pb_contact()]}.
obtain_user_ids(NormContacts) ->
    ContactPhones = extract_normalized(NormContacts),
    PhoneUidsMap = model_phone:get_uids(ContactPhones),
    lists:foldl(
        fun(#pb_contact{normalized = ContactPhone} = Contact, {UnRegAcc, RegAcc}) ->
            ContactId = maps:get(ContactPhone, PhoneUidsMap, undefined),
            case ContactId of
                undefined ->
                    {[Contact#pb_contact{uid = undefined, role = none} | UnRegAcc], RegAcc};
                _ ->
                    {UnRegAcc, [Contact#pb_contact{uid = ContactId} | RegAcc]}
            end
        end, {[], []}, NormContacts).


%% Sets potential friends for un-registered contacts.
-spec obtain_potential_friends(Uid :: binary(), UnRegisteredContacts :: [pb_contact()]) -> [pb_contact()].
obtain_potential_friends(_Uid, UnRegisteredContacts) ->
    ContactPhones = extract_normalized(UnRegisteredContacts),
    PhoneToInvitersMap = model_invites:get_inviters_list(ContactPhones),
    PhoneToContactsMap = model_contacts:get_contacts_uids_size(ContactPhones),
    lists:map(
        fun(#pb_contact{normalized = ContactPhone} = Contact) ->
            NumInviters = length(maps:get(ContactPhone, PhoneToInvitersMap, [])),
            NumPotentialFriends = maps:get(ContactPhone, PhoneToContactsMap, 0),
            case NumInviters >= ?MAX_INVITERS of
                %% Dont share potential friends info if the number is already invited by more than MAX_INVITERS.
                true -> Contact;
                %% TODO(murali@): change this when we switch to contact hashing.
                false -> Contact#pb_contact{num_potential_friends = NumPotentialFriends}
            end
        end, UnRegisteredContacts).


%% Sets names for all registered contacts.
-spec obtain_names(RegContacts :: [pb_contact()]) -> [pb_contact()].
obtain_names(RegContacts) ->
    ContactIds = extract_uid(RegContacts),
    ContactIdNamesMap = model_accounts:get_names(ContactIds),
    lists:map(
        fun(#pb_contact{uid = ContactId} = Contact) ->
            ContactName = maps:get(ContactId, ContactIdNamesMap, undefined),
            Contact#pb_contact{name = ContactName}
        end, RegContacts).


%% Splits registered contact records to non-friend and friend contacts.
%% Sets role for all contacts.
-spec obtain_roles_and_notify(Uid :: binary(), UserPhone :: binary(), RegContacts :: [pb_contact()],
        OldContactSet :: sets:set(binary()), OldReverseContactSet :: sets:set(binary()), OldFriendUidSet :: sets:set(binary()),
        BlockedUidSet :: sets:set(binary()), ShouldNotify :: boolean()) -> {[pb_contact()], [pb_contact()]}.
obtain_roles_and_notify(Uid, UserPhone, RegContacts, OldContactSet,
        OldReverseContactSet, OldFriendUidSet, BlockedUidSet, ShouldNotify) ->
    Server = util:get_host(),
    {NonFriendContacts, FriendContacts} = lists:foldl(
        fun(#pb_contact{normalized = ContactPhone, uid = ContactId} = Contact,
                {NonFriendAcc, FriendAcc}) ->
            IsNewContact = not sets:is_element(ContactPhone, OldContactSet),
            IsFriends = sets:is_element(ContactId, OldReverseContactSet) andalso
                    not sets:is_element(ContactId, BlockedUidSet),
            Role = get_role_value(IsFriends),
            %% Notify the new contact and update its friends table.
            case {ShouldNotify, IsNewContact, IsFriends} of
                {true, true, true} ->
                    notify_contact_about_user(Uid, UserPhone, ContactId, Role);
                {_, _, _} -> ok
            end,
            %% Update Acc
            NewContact = Contact#pb_contact{role = Role},
            case IsFriends of
                true ->
                    {NonFriendAcc, [NewContact | FriendAcc]};
                false ->
                    {[NewContact | NonFriendAcc], FriendAcc}
            end
        end, {[], []}, RegContacts),

    %% Extract current friends and add only new friends to the database.
    CurrentFriendUids = extract_uid(FriendContacts),
    %% These are the new friends we need to add to the database and let other modules know about it.
    NewFriendUids = lists:filter(
        fun(FriendUid) ->
            not sets:is_element(FriendUid, OldFriendUidSet)
        end, CurrentFriendUids),
    %% Store friend relationships in the database.
    ok = model_friends:add_friends(Uid, NewFriendUids),
    %% Run add_friend hook only for NewFriendUids - other modules are interested in only new changes to relationships.
    lists:foreach(
        fun(FriendUid) ->
            add_friend_hook(Uid, Server, FriendUid, false)
        end, NewFriendUids),

    {NonFriendContacts, FriendContacts}.


%% Sets avatar_ids for all registered contacts.
-spec obtain_avatar_ids(FriendContacts :: [pb_contact()]) -> [pb_contact()].
obtain_avatar_ids(FriendContacts) ->
    ContactIds = lists:map(
            fun(#pb_contact{uid = ContactId}) ->
                ContactId
            end, FriendContacts),
    ContactIdAvatarsMap = model_accounts:get_avatar_ids(ContactIds),
    lists:map(
        fun(#pb_contact{uid = ContactId} = Contact) ->
            AvatarId = maps:get(ContactId, ContactIdAvatarsMap, undefined),
            Contact#pb_contact{avatar_id = AvatarId}
        end, FriendContacts).


-spec add_friend(Uid :: binary(), Server :: binary(), Ouid :: binary(), WasBlocked :: boolean()) -> ok.
add_friend(Uid, Server, Ouid, WasBlocked) ->
    ?INFO("~p is friends with ~p", [Uid, Ouid]),
    model_friends:add_friend(Uid, Ouid),
    add_friend_hook(Uid, Server, Ouid, WasBlocked).


-spec add_friend_hook(Uid :: binary(), Server :: binary(), Ouid :: binary(), WasBlocked :: boolean()) -> ok.
add_friend_hook(Uid, Server, Ouid, WasBlocked) ->
    ejabberd_hooks:run(add_friend, Server, [Uid, Server, Ouid, WasBlocked]).


-spec remove_friend(Uid :: binary(), Server :: binary(), Ouid :: binary()) -> ok.
remove_friend(Uid, Server, Ouid) ->
    ?INFO("~p is no longer friends with ~p", [Uid, Ouid]),
    model_friends:remove_friend(Uid, Ouid),
    ejabberd_hooks:run(remove_friend, Server, [Uid, Server, Ouid]).


-spec extract_normalized(Contacts :: [pb_contact()]) -> [binary()].
extract_normalized(Contacts) ->
    lists:map(fun(Contact) -> Contact#pb_contact.normalized end, Contacts).


-spec extract_uid(Contacts :: [pb_contact()]) -> [binary()].
extract_uid(Contacts) ->
    lists:map(fun(Contact) -> Contact#pb_contact.uid end, Contacts).


%%====================================================================
%% delete_contact
%%====================================================================


-spec remove_contact_phones(UserId :: binary(), ContactPhones :: [binary()]) -> ok.
remove_contact_phones(UserId, ContactPhones) ->
    remove_contact_phones(UserId, ContactPhones, false).


-spec remove_contact_phones(
        UserId :: binary(), ContactPhones :: [binary()], IsAccountDeleted :: boolean()) -> ok.
remove_contact_phones(UserId, ContactPhones, IsAccountDeleted) ->
    UserPhone = get_phone(UserId),
    {ok, ReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    ReverseContactSet = sets:from_list(ReverseContactList),
    model_contacts:remove_contacts(UserId, ContactPhones),
    remove_contacts_and_notify(UserId, UserPhone, ContactPhones, ReverseContactSet, IsAccountDeleted).


-spec remove_contacts_and_notify(UserId :: binary(), UserPhone :: binary(),
        ContactPhones :: [binary()], ReverseContactSet :: sets:set(binary()),
        IsAccountDeleted :: boolean()) ->ok.
remove_contacts_and_notify(UserId, UserPhone, ContactPhones, ReverseContactSet, IsAccountDeleted) ->
    lists:foreach(
            fun(ContactPhone) ->
                remove_contact_and_notify(UserId, UserPhone, ContactPhone,
                        ReverseContactSet, IsAccountDeleted)
            end, ContactPhones).


%% Delete all associated info with the contact and the user.
-spec remove_contact_and_notify(UserId :: binary(), UserPhone :: binary(),
        ContactPhone :: binary(), ReverseContactSet :: sets:set(binary()),
        IsAccountDeleted :: boolean()) -> {ok, any()} | {error, any()}.
remove_contact_and_notify(UserId, UserPhone, ContactPhone, ReverseContactSet, IsAccountDeleted) ->
    Server = util:get_host(),
    {ok, ContactId} = model_phone:get_uid(ContactPhone),
    stat:count("HA/contacts", "remove_contact"),
    case ContactId of
        undefined ->
            ok;
        _ ->
            case sets:is_element(ContactId, ReverseContactSet) of
                true ->
                    remove_friend(UserId, Server, ContactId),
                    case IsAccountDeleted of
                        true ->
                            %% dont notify the contact here. we will send a separate notification.
                            ok;
                        false ->
                            notify_contact_about_user(UserId, UserPhone, ContactId, none)
                    end;
                false -> ok
            end,
            ejabberd_hooks:run(remove_contact, Server, [UserId, Server, ContactId])
    end.


%%====================================================================
%% notify contact
%%====================================================================


%% Notifies contact about the user using the UserId and the role element to indicate
%% if they are now friends or not on halloapp.
-spec notify_contact_about_user(UserId :: binary(), UserPhone :: binary(),
        ContactId :: binary(), Role :: atom()) -> ok.
notify_contact_about_user(UserId, _UserPhone, UserId, _Role) ->
    ok;
notify_contact_about_user(UserId, UserPhone, ContactId, Role) ->
    notify_contact_about_user(UserId, UserPhone, ContactId, Role, normal, normal).


-spec notify_contact_about_user(UserId :: binary(), UserPhone :: binary(), ContactId :: binary(),
        Role :: atom(), MessageType :: atom(), ContactListType :: atom()) -> ok.
notify_contact_about_user(UserId, UserPhone, ContactId, Role, MessageType, ContactListType) ->
    notifications_util:send_contact_notification(UserId, UserPhone, ContactId,
            Role, MessageType, ContactListType).


-spec probe_contact_about_user(UserId :: binary(), UserPhone :: binary(),
        Server :: binary(), ContactId :: binary()) -> ok.
probe_contact_about_user(UserId, UserPhone, Server, ContactId) ->
    ?INFO("UserId: ~s, ContactId: ~s", [UserId, ContactId]),
    <<HashValue:?PROBE_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, UserPhone),
    send_probe_message(UserId, HashValue, ContactId, Server),
    ok.


-spec send_probe_message(UserId :: binary(), HashValue :: binary(),
        ContactId :: binary(), Server :: binary()) -> ok.
send_probe_message(UserId, HashValue, ContactId, Server) ->
    Payload = #pb_contact_hash{hash = HashValue},
    Stanza = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = ContactId,
        payload = Payload
    },
    ?DEBUG("Probing contact: ~p about user: ~p using stanza: ~p",
            [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).


