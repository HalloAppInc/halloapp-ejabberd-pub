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
-define(MAX_INVITERS, 2).
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
finish_sync(UserId, Server, SyncId) ->
    StartTime = os:system_time(microsecond), 
    UserPhone = get_phone(UserId),
    {ok, OldContactList} = model_contacts:get_contacts(UserId),
    {ok, NewContactList} = model_contacts:get_sync_contacts(UserId, SyncId),
    {ok, OldReverseContactList} = model_contacts:get_contact_uids(UserPhone),
    {ok, BlockedUids} = model_privacy:get_blocked_uids(UserId),
    {ok, BlockedByUids} = model_privacy:get_blocked_by_uids(UserId),
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
    %% TODO(vipin): newness of contacts in AddContactSet needs to be used in update_and_...(...).
    %% Convert Phones to pb_contact records.
    AddContacts1 = lists:map(
            fun(ContactPhone) ->
                #pb_contact{normalized = ContactPhone}
            end, sets:to_list(AddContactSet)),
    %% Obtain UserIds for all the normalized phone numbers.
    AddContacts2 = obtain_user_ids(AddContacts1),
    lists:map(
            fun(Contact) ->
                update_and_notify_contact(UserId, UserPhone, OldContactSet,
                        OldReverseContactSet, BlockedUidSet, Contact, yes)
            end, AddContacts2),

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
    OldContactSet = sets:from_list(OldContactList),
    OldReverseContactSet = sets:from_list(OldReverseContactList),
    BlockedUidSet = sets:from_list(BlockedUids ++ BlockedByUids),

    %% Firstly, normalize all phone numbers received.
    Contacts1 = normalize_contacts(Contacts, UserRegionId),
    %% Obtain UserIds for all the normalized phone numbers.
    Contacts2 = obtain_user_ids(Contacts1),
    %% Obtain names for all valid userids
    Contacts3 = obtain_user_names(Contacts2),

    %% Construct the list of new contact records to be returned and filter out the phone numbers
    %% that couldn't be normalized.
    {Contacts4, {NormalizedPhoneNumbers, UnregisteredPhoneNumbers}} = lists:mapfoldr(
            fun(Contact, {PhoneAcc, UnregisteredPhoneAcc}) ->
                NewContact = case SyncId of
                    undefined -> update_and_notify_contact(UserId, UserPhone, OldContactSet,
                            OldReverseContactSet, BlockedUidSet, Contact, yes);
                    _ -> update_and_notify_contact(UserId, UserPhone, OldContactSet,
                            OldReverseContactSet, BlockedUidSet, Contact, no)
                end,
                NewAcc = case {NewContact#pb_contact.normalized, NewContact#pb_contact.uid} of
                    {undefined, _} -> {PhoneAcc, UnregisteredPhoneAcc};
                    {NormPhone, undefined} -> {[NormPhone | PhoneAcc], [NormPhone | UnregisteredPhoneAcc]};
                    {NormPhone, _} -> {[NormPhone | PhoneAcc], UnregisteredPhoneAcc}
                end,
                {NewContact, NewAcc}
            end, {[], []}, Contacts3),

    %% Call the batched API to insert UserId for the unregistered phone numbers.
    model_contacts:add_reverse_hash_contacts(UserId, UnregisteredPhoneNumbers),
    %% Call the batched API to insert the normalized phone numbers.
    case SyncId of
        undefined -> model_contacts:add_contacts(UserId, NormalizedPhoneNumbers);
        _ -> model_contacts:sync_contacts(UserId, SyncId, NormalizedPhoneNumbers)
    end,
    Contacts4.


-spec normalize_contacts(Contacts :: [pb_contact()], UserRegionId :: binary()) -> [pb_contact()].
normalize_contacts(Contacts, UserRegionId) ->
    lists:map(
        fun(#pb_contact{raw = undefined} = Contact) ->
                ?WARNING("Invalid contact: raw is undefined"),
                Contact#pb_contact{role = none, uid = undefined, normalized = undefined};
            (#pb_contact{raw = RawPhone} = Contact) ->
                ContactPhone = mod_libphonenumber:normalize(RawPhone, UserRegionId),
                case ContactPhone of
                    undefined ->
                        stat:count("HA/contacts", "normalize_fail"),
                        Contact#pb_contact{role = none, uid = undefined, normalized = undefined};
                    _ ->
                        stat:count("HA/contacts", "normalize_success"),
                        Contact#pb_contact{normalized = ContactPhone}
                end
        end, Contacts).


-spec obtain_user_ids(Contacts :: [pb_contact()]) -> [pb_contact()].
obtain_user_ids(Contacts) ->
    ContactPhones = lists:foldl(
            fun(#pb_contact{normalized = undefined}, Acc) -> Acc;
                (#pb_contact{normalized = ContactPhone}, Acc) -> [ContactPhone | Acc]
            end, [], Contacts),
    PhoneUidsMap = model_phone:get_uids(ContactPhones),
    Contacts1 = lists:map(
            fun(#pb_contact{normalized = ContactPhone} = Contact) ->
                ContactId = maps:get(ContactPhone, PhoneUidsMap, undefined),
                Contact#pb_contact{uid = ContactId}
            end, Contacts),
    Contacts1.


-spec obtain_user_names(Contacts :: [pb_contact()]) -> [pb_contact()].
obtain_user_names(Contacts) ->
    ContactIds = lists:foldl(
            fun(#pb_contact{uid = undefined}, Acc) -> Acc;
                (#pb_contact{uid = ContactId}, Acc) -> [ContactId | Acc]
            end, [], Contacts),
    ContactIdNamesMap = model_accounts:get_names(ContactIds),
    Contacts1 = lists:map(
            fun(#pb_contact{uid = undefined} = Contact) -> Contact;
                (#pb_contact{uid = ContactId} = Contact) ->
                    ContactName = maps:get(ContactId, ContactIdNamesMap, undefined),
                    Contact#pb_contact{name = ContactName}
            end, Contacts),
    Contacts1.


%% TODO(murali@): clean these functions by passing a record with various fields as info.
-spec update_and_notify_contact(UserId :: binary(), UserPhone :: binary(),
        OldContactSet :: sets:set(binary()), OldReverseContactSet :: sets:set(binary()),
        BlockedUidSet :: sets:set(binary()), Contact :: pb_contact(),
        ShouldNotify :: atom()) -> pb_contact().
update_and_notify_contact(_UserId, _UserPhone, _OldContactSet, _OldReverseContactSet,
        _BlockedUidSet, #pb_contact{normalized = undefined} = Contact, _ShouldNotify) ->
    Contact;
update_and_notify_contact(UserId, UserPhone, OldContactSet, OldReverseContactSet,
        BlockedUidSet, Contact, ShouldNotify) ->
    Server = util:get_host(),
    ContactPhone = Contact#pb_contact.normalized,
    ContactId = Contact#pb_contact.uid,
    IsNewContact = not sets:is_element(ContactPhone, OldContactSet),
    %% TODO(vipin): Need to fix the stat below.
    stat:count("HA/contacts", "add_contact"),
    case ContactId of
        undefined ->
            %% Dont share potential friends info if the number is already invited by more than MAX_INVITERS.
            PotentialFriends1 = case model_invites:get_inviters_list(ContactPhone) of
                {ok, InvitersList} when length(InvitersList) > ?MAX_INVITERS -> 0;
                _ -> model_contacts:get_contact_uids_size(ContactPhone)
            end,
            %% TODO(murali@): change this when we switch to contact hashing.
            %% We are looking up redis sequentially for every phone number.
            %% TODO(murali@): this query will make it expensive. fix this with qmn later.
            PotentialFriends2 = case dev_users:is_dev_uid(UserId) of
                true -> PotentialFriends1;
                false -> 0  %% 0 or undefined is the same for the clients.
            end,
            Contact#pb_contact{
                role = none,
                num_potential_friends = PotentialFriends2
            };
        _ ->
            IsFriends = sets:is_element(ContactId, OldReverseContactSet) andalso
                    not sets:is_element(ContactId, BlockedUidSet),
            Role = get_role_value(IsFriends),
            %% Notify the new contact and update its friends table.
            case {ShouldNotify, IsNewContact, IsFriends} of
                {yes, true, true} ->
                    add_friend(UserId, Server, ContactId),
                    notify_contact_about_user(UserId, UserPhone, ContactId, Role);
                {_, _, _} -> ok
            end,
            %% Send AvatarId only if ContactId and UserPhone are friends.
            AvatarId = case IsFriends of
                true -> model_accounts:get_avatar_id_binary(ContactId);
                false -> <<>>   %% Both <<>> or undefined will be the same when interpreted by the clients.
            end,
            Contact#pb_contact{
                avatar_id = AvatarId,
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
        id = util:new_msg_id(),
        to_uid = ContactId,
        payload = Payload
    },
    ?DEBUG("Probing contact: ~p about user: ~p using stanza: ~p",
            [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).


