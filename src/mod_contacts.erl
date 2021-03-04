%%%----------------------------------------------------------------------
%%% File    : mod_contacts.erl
%%%
%%% Copyright (C) 2020 HalloApp Inc.
%%%
%%% This file handles the iq packet queries with a custom namespace
%%% (<<"halloapp:user:contacts">>) that we defined.
%%% We define custom xml records of the following type:
%%% "contact_list", "contact", "raw", "uuid", role", "normalized" in
%%% xmpp/specs/xmpp_codec.spec file.
%%%----------------------------------------------------------------------

-module(mod_contacts).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("packets.hrl").
-include("ha_namespaces.hrl").
-include("time.hrl").

-define(SALT_LENGTH_BYTES, 32).
-define(PROBE_HASH_LENGTH_BYTES, 2).
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


-spec remove_user(UserId :: binary(), Server :: binary()) -> ok.
remove_user(UserId, Server) ->
    remove_all_contacts(UserId, Server).


-spec re_register_user(UserId :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(UserId, Server, _Phone) ->
    remove_all_contacts(UserId, Server).


%% TODO: Delay notifying the users about their contact to reduce unnecessary messages to clients.
-spec register_user(UserId :: binary(), Server :: binary(), Phone :: binary()) -> ok.
register_user(UserId, Server, Phone) ->
    {ok, PotentialContactUids} = model_contacts:get_potential_reverse_contact_uids(Phone),
    lists:foreach(
        fun(ContactId) ->
            probe_contact_about_user(UserId, Phone, Server, ContactId)
        end, PotentialContactUids),

    {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
    lists:foreach(
        fun(ContactId) ->
            notify_contact_about_user(UserId, Phone, Server, ContactId, none)
        end, ContactUids).


-spec block_uids(Uid :: binary(), Server :: binary(), Ouids :: list(binary())) -> ok.
block_uids(Uid, Server, Ouids) ->
    %% TODO(murali@): Add batched api for friends.
    lists:foreach(
        fun(Ouid) ->
            case model_accounts:get_phone(Ouid) of
                {ok, OPhone} ->
                    remove_friend(Uid, Server, Ouid),
                    notify_contact_about_user(Ouid, OPhone, Server, Uid, none);
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
                            notify_contact_about_user(Ouid, OPhone, Server, Uid, friends);
                        false ->
                            notify_contact_about_user(Ouid, OPhone, Server, Uid, none)
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


-spec obtain_user_id(binary()) -> binary() | undefined.
obtain_user_id(Phone) ->
    {ok, Uid} = model_phone:get_uid(Phone),
    Uid.


-spec get_phone(UserId :: binary()) -> binary() | undefined.
get_phone(UserId) ->
    case model_accounts:get_phone(UserId) of
        {ok, Phone} -> Phone;
        {error, missing} -> undefined
    end.

-spec handle_delta_contacts(UserId :: binary(), Server :: binary(),
        Contacts :: [contact()]) -> [contact()].
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
    remove_contact_phones(UserId, Server, DeleteContactPhones),
    AddContacts = normalize_and_insert_contacts(UserId, Server, AddContactsList, undefined),

    %% Send notification to user who invited this user.
    %% Server fix for an issue on the ios client: remove this after 03-10-21.
    AddContactsPhoneList = lists:foldl(
            fun (#pb_contact{normalized = undefined}, Acc) -> Acc;
                (#pb_contact{normalized = NormPhone}, Acc) -> [NormPhone | Acc]
            end, [], AddContacts),
    AddContactsPhoneSet = sets:from_list(AddContactsPhoneList),

    %% Check the user account status and current sync info and send notifications if necessary.
    check_and_send_notifications(UserId, Server, AddContactsPhoneSet, AddContacts),
    AddContacts.


-spec remove_all_contacts(UserId :: binary(), Server :: binary()) -> ok.
remove_all_contacts(UserId, Server) ->
    {ok, ContactPhones} = model_contacts:get_contacts(UserId),
    remove_contact_phones(UserId, Server, ContactPhones).


-spec finish_sync(UserId :: binary(), Server :: binary(), SyncId :: binary()) -> ok.
finish_sync(UserId, Server, SyncId) ->
    StartTime = os:system_time(microsecond), 
    UserPhone = get_phone(UserId),
    {ok, OldContactList} = model_contacts:get_contacts(UserId),
    {ok, NewContactList} = model_contacts:get_sync_contacts(UserId, SyncId),
    {ok, OldReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    OldContactSet = sets:from_list(OldContactList),
    NewContactSet = sets:from_list(NewContactList),
    DeleteContactSet = sets:subtract(OldContactSet, NewContactSet),
    AddContactSet = sets:subtract(NewContactSet, OldContactSet),
    OldReverseContactSet = sets:from_list(OldReverseContactList),
    ?INFO("Full contact sync stats: uid: ~p, old_contacts: ~p, new_contacts: ~p, "
            "add_contacts: ~p, delete_contacts: ~p", [UserId, sets:size(OldContactSet),
            sets:size(NewContactSet), sets:size(AddContactSet), sets:size(DeleteContactSet)]),
    ?INFO("Full contact sync: uid: ~p, add_contacts: ~p, delete_contacts: ~p",
                [UserId, sets:to_list(AddContactSet), sets:to_list(DeleteContactSet)]),
    %% TODO(murali@): Update this after moving pubsub to redis.
    remove_contacts_and_notify(UserId, Server, UserPhone,
            sets:to_list(DeleteContactSet), OldReverseContactSet),
    %% TODO(vipin): newness of contacts in AddContactSet needs to be used in update_and_...(...).
    NewContactRecordList = lists:map(
        fun(ContactPhone) ->
            update_and_notify_contact(UserId, UserPhone, OldContactSet,
                    OldReverseContactSet, Server, ContactPhone, yes)
        end, sets:to_list(AddContactSet)),

    %% Check the user account status and current sync info and send notifications if necessary.
    %% TODO(murali@): We will be sending duplicate contact messages initially - fix this separately.
    check_and_send_notifications(UserId, Server, NewContactSet, NewContactRecordList),

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


%% TODO(murali@): need to cache user details like phone across all functions in this module.
-spec check_and_send_notifications(UserId :: binary(), Server :: binary(),
        NewContactSet :: sets:set(binary()), NewContactRecordList :: [contact()]) -> ok.
check_and_send_notifications(UserId, Server, NewContactSet, NewContactRecordList) ->
    %% Checks if the user is a new user (meaning joined < 24hrs) andalso
    %% ensure that the user has not already done a non-empty full-contact sync andalso
    %% Checks if the new contact set is not-empty.
    ShouldNotifyFriends = should_notify_friends(UserId, NewContactSet),

    %% ShouldNotifyFriends will be true only if the user is a new user and
    %% has not synced any contacts yet, and is now syncing non-empty set of contacts.
    case ShouldNotifyFriends of
        true ->
            do_send_notifications(UserId, Server, NewContactRecordList);
        false -> ok
    end.


-spec do_send_notifications(UserId :: binary(), Server :: binary(),
        NewContactRecordList :: [contact()]) -> ok.
do_send_notifications(UserId, Server, NewContactRecordList) ->
    %% Send notification to user who invited this user.
    UserPhone = get_phone(UserId),
    %% Fetch all inviter phone numbers.
    {ok, InvitersList} = model_invites:get_inviters_list(UserPhone),
    InviterUidSet = sets:from_list([InviterUid || {InviterUid, _} <- InvitersList]),
    %% Send only one notification per contact - inviter/friend.
    lists:foreach(
            fun(#pb_contact{uid = ContactId, role = friends = Role}) ->
                case sets:is_element(ContactId, InviterUidSet) of
                    true ->
                        ?INFO("Notify Inviter: ~p about user: ~p joining", [ContactId, UserId]),
                        mod_invites:notify_inviter(UserId, UserPhone, Server,
                                ContactId, Role, normal, inviter_notice);
                    false ->
                        ?INFO("Notify Friend: ~p about user: ~p joining", [ContactId, UserId]),
                        notifications_util:send_contact_notification(UserId, UserPhone,
                                ContactId, Role, normal, friend_notice)
                end;
                (#pb_contact{normalized = ContactPhone, uid = ContactId, role = Role}) ->
                    ?INFO("No push notification to user, phone: ~p, uid: ~p, role: ~p",
                            [ContactPhone, ContactId, Role]),
                    ok
            end, NewContactRecordList),
    ok.


-spec should_notify_friends(UserId :: binary(), NewContactSet :: sets:set(binary())) -> boolean().
should_notify_friends(UserId, NewContactSet) ->
    %% Check if the user is a new user (meaning joined < 24hrs)
    {ok, CreationTs} = model_accounts:get_creation_ts_ms(UserId),
    IsNewUser = CreationTs + ?NOTIFICATION_EXPIRY_MS > util:now_ms(),

    %% Check if this is the first non-empty contact sync.
    IsFirstNonEmptyContactSync = not sets:is_empty(NewContactSet) andalso
            not model_accounts:is_first_sync_done(UserId),

    %% Check if it is their first non empty contact sync.
    %% If not - ignore and dont send notifications.
    %% If yes - check the account creation time and then decide.
    IsFirstNonEmptyContactSync andalso IsNewUser.


%%====================================================================
%% add_contact
%%====================================================================


-spec normalize_and_insert_contacts(UserId :: binary(), Server :: binary(),
        Contacts :: [contact()], SyncId :: undefined | binary()) -> [contact()].
normalize_and_insert_contacts(UserId, Server, Contacts, SyncId) ->
    UserPhone = get_phone(UserId),
    UserRegionId = mod_libphonenumber:get_region_id(UserPhone),
    {ok, OldContactList} = model_contacts:get_contacts(UserId),
    {ok, OldReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    OldContactSet = sets:from_list(OldContactList),
    OldReverseContactSet = sets:from_list(OldReverseContactList),
    %% Construct the list of new contact records to be returned and filter out the phone numbers
    %% that couldn't be normalized.
    {NewContacts, {NormalizedPhoneNumbers, UnregisteredPhoneNumbers}} = lists:mapfoldr(
            fun(Contact, {PhoneAcc, UnregisteredPhoneAcc}) ->
                NewContact = normalize_and_update_contact(
                        UserId, UserRegionId, UserPhone, OldContactSet,
                        OldReverseContactSet, Server, Contact, SyncId),
                NewAcc = case {NewContact#pb_contact.normalized, NewContact#pb_contact.uid} of
                    {undefined, _} -> {PhoneAcc, UnregisteredPhoneAcc};
                    {NormPhone, undefined} -> {[NormPhone | PhoneAcc], [NormPhone | UnregisteredPhoneAcc]};
                    {NormPhone, _} -> {[NormPhone | PhoneAcc], UnregisteredPhoneAcc}
                end,
                {NewContact, NewAcc}
            end, {[], []}, Contacts),
    %% Call the batched API to insert UserId for the unregistered phone numbers.
    model_contacts:add_reverse_hash_contacts(UserId, UnregisteredPhoneNumbers),
    %% Call the batched API to insert the normalized phone numbers.
    case SyncId of
        undefined -> model_contacts:add_contacts(UserId, NormalizedPhoneNumbers);
        _ -> model_contacts:sync_contacts(UserId, SyncId, NormalizedPhoneNumbers)
    end,
    NewContacts.


-spec normalize_and_update_contact(UserId :: binary(), UserRegionId :: binary(),
        UserPhone :: binary(), OldContactSet :: sets:set(binary()),
        OldReverseContactSet :: sets:set(binary()), Server :: binary(),
        Contact :: contact(), SyncId :: binary()) -> contact().
normalize_and_update_contact(_UserId, _UserRegionId, _UserPhone, _OldContactSet,
        _OldReverseContactSet, _Server, #pb_contact{raw = undefined}, _SyncId) ->
    #pb_contact{role = none};
normalize_and_update_contact(UserId, UserRegionId, UserPhone, OldContactSet,
        OldReverseContactSet, Server, Contact, SyncId) ->
    RawPhone = Contact#pb_contact.raw,
    ContactPhone = mod_libphonenumber:normalize(RawPhone, UserRegionId),
    NewContact = case ContactPhone of
        undefined ->
            stat:count("HA/contacts", "normalize_fail"),
            Contact#pb_contact{role = none, uid = undefined, normalized = undefined};
        _ ->
            stat:count("HA/contacts", "normalize_success"),
            case SyncId of
                undefined -> update_and_notify_contact(UserId, UserPhone, OldContactSet,
                        OldReverseContactSet, Server, ContactPhone, yes);
                _ -> update_and_notify_contact(UserId, UserPhone, OldContactSet,
                        OldReverseContactSet, Server, ContactPhone, no)
            end
    end,
    NewContact#pb_contact{raw = RawPhone}.


-spec update_and_notify_contact(UserId :: binary(), UserPhone :: binary(),
        OldContactSet :: sets:set(binary()), OldReverseContactSet :: sets:set(binary()),
        Server :: binary(), ContactPhone :: binary(), ShouldNotify :: atom()) -> contact().
update_and_notify_contact(UserId, UserPhone, OldContactSet, OldReverseContactSet,
        Server, ContactPhone, ShouldNotify) ->
    IsNewContact = not sets:is_element(ContactPhone, OldContactSet),
    ContactId = obtain_user_id(ContactPhone),
    %% TODO(vipin): Need to fix the stat below.
    stat:count("HA/contacts", "add_contact"),
    case ContactId of
        undefined ->
            %% TODO(murali@): change this when we switch to contact hashing.
            %% We are looking up redis sequentially for every phone number.
            %% TODO(murali@): this query will make it expensive. fix this with qmn later.
            NumPotentialFriends = case dev_users:is_dev_uid(UserId) of
                true -> model_contacts:get_contact_uids_size(ContactPhone);
                false -> 0  %% 0 or undefined is the same for the clients.
            end,
            #pb_contact{normalized = ContactPhone, uid = undefined,
                    role = none, num_potential_friends = NumPotentialFriends};
        _ ->
            %% TODO(murali@): update this to load block-uids once for this request
            %% and use it instead of every redis call.
            IsFriends = sets:is_element(ContactId, OldReverseContactSet) andalso
                    not model_privacy:is_blocked_any(UserId, ContactId),
            Role = get_role_value(IsFriends),
            %% Notify the new contact and update its friends table.
            case {ShouldNotify, IsNewContact, IsFriends} of
                {yes, true, true} ->
                    add_friend(UserId, Server, ContactId),
                    notify_contact_about_user(UserId, UserPhone, Server, ContactId, Role);
                {_, _, _} -> ok
            end,
            %% Send AvatarId only if ContactId and UserPhone are friends.
            AvatarId = case IsFriends of
                true -> model_accounts:get_avatar_id_binary(ContactId);
                false -> <<>>   %% Both <<>> or undefined will be the same when interpreted by the clients.
            end,
            Name = model_accounts:get_name_binary(ContactId),
            #pb_contact{
                uid = ContactId,
                name = Name,
                avatar_id = AvatarId,
                normalized = ContactPhone,
                role = Role
            }
    end.


-spec add_friend(Uid :: binary(), Server :: binary(), Ouid :: binary()) -> ok.
add_friend(Uid, Server, Ouid) ->
    add_friend(Uid, Server, Ouid, false).


-spec add_friend(Uid :: binary(), Server :: binary(), Ouid :: binary(), WasBlocked :: boolean()) -> ok.
add_friend(Uid, Server, Ouid, WasBlocked) ->
    ?INFO("~p is friends with ~p", [Uid, Ouid]),
    model_friends:add_friend(Uid, Ouid),
    ejabberd_hooks:run(add_friend, Server, [Uid, Server, Ouid, WasBlocked]).


-spec remove_friend(Uid :: binary(), Server :: binary(), Ouid :: binary()) -> ok.
remove_friend(Uid, Server, Ouid) ->
    ?INFO("~p is no longer friends with ~p", [Uid, Ouid]),
    model_friends:remove_friend(Uid, Ouid),
    ejabberd_hooks:run(remove_friend, Server, [Uid, Server, Ouid]).


%%====================================================================
%% delete_contact
%%====================================================================


-spec remove_contact_phones(
        UserId :: binary(), Server :: binary(), ContactPhones :: [binary()]) -> ok.
remove_contact_phones(UserId, Server, ContactPhones) ->
    UserPhone = get_phone(UserId),
    {ok, ReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    ReverseContactSet = sets:from_list(ReverseContactList),
    model_contacts:remove_contacts(UserId, ContactPhones),
    remove_contacts_and_notify(UserId, Server, UserPhone, ContactPhones, ReverseContactSet).


-spec remove_contacts_and_notify(UserId :: binary(), Server :: binary(), UserPhone :: binary(),
        ContactPhones :: [binary()], ReverseContactSet :: sets:set(binary())) ->ok.
remove_contacts_and_notify(UserId, Server, UserPhone, ContactPhones, ReverseContactSet) ->
    lists:foreach(
            fun(ContactPhone) ->
                remove_contact_and_notify(UserId, Server, UserPhone, ContactPhone, ReverseContactSet)
            end, ContactPhones).


%% Delete all associated info with the contact and the user.
-spec remove_contact_and_notify(UserId :: binary(), Server :: binary(),
        UserPhone :: binary(), ContactPhone :: binary(),
        ReverseContactSet :: sets:set(binary())) -> {ok, any()} | {error, any()}.
remove_contact_and_notify(UserId, Server, UserPhone, ContactPhone, ReverseContactSet) ->
    ContactId = obtain_user_id(ContactPhone),
    stat:count("HA/contacts", "remove_contact"),
    case ContactId of
        undefined ->
            ok;
        _ ->
            case sets:is_element(ContactId, ReverseContactSet) of
                true ->
                    remove_friend(UserId, Server, ContactId),
                    notify_contact_about_user(UserId, UserPhone, Server, ContactId, none);
                false -> ok
            end,
            ejabberd_hooks:run(remove_contact, Server, [UserId, Server, ContactId])
    end.


%%====================================================================
%% notify contact
%%====================================================================


%% Notifies contact about the user using the UserId and the role element to indicate
%% if they are now friends or not on halloapp.
-spec notify_contact_about_user(UserId :: binary(), UserPhone :: binary(), Server :: binary(),
        ContactId :: binary(), Role :: atom()) -> ok.
notify_contact_about_user(UserId, _UserPhone, _Server, UserId, _Role) ->
    ok;
notify_contact_about_user(UserId, UserPhone, _Server, ContactId, Role) ->
    notifications_util:send_contact_notification(UserId, UserPhone, ContactId, Role).

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
        id = util:new_msg_id(),
        to_uid = ContactId,
        payload = Payload
    },
    ?DEBUG("Probing contact: ~p about user: ~p using stanza: ~p",
            [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).


