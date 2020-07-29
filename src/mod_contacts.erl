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
-include("translate.hrl").

-define(NS_NORM, <<"halloapp:user:contacts">>).
-define(SALT_LENGTH_BYTES, 32).
-define(PROBE_HASH_LENGTH_BYTES, 2).

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
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_NORM, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 100),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(block_uids, Host, ?MODULE, block_uids, 50),
    ejabberd_hooks:add(unblock_uids, Host, ?MODULE, unblock_uids, 50),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_NORM),
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

process_local_iq(#iq{from = #jid{luser = UserId, lserver = Server}, type = set, lang = Lang,
        sub_els = [#contact_list{type = full, contacts = Contacts, syncid = SyncId, index = Index, 
                last = Last}]} = IQ) ->
    StartTime = os:system_time(microsecond), 
    ?INFO_MSG("Full contact sync Uid: ~p, syncid: ~p, index: ~p, last: ~p, num_contacts: ~p",
            [UserId, SyncId, Index, Last, length(Contacts)]),
    stat:count("HA/contacts", "sync_full_contacts", length(Contacts)),
    case SyncId of
        undefined ->
            Txt = ?T("Invalid syncid in the request"),
            ?WARNING_MSG("process_local_iq: ~p, ~p", [IQ, Txt]),
            ResultIQ = xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        _ ->
            count_full_sync(Index),
            ResultIQ = xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM,
                    syncid = SyncId, type = normal,
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
    ?INFO_MSG("Time taken: ~w us", [T]),
    ResultIQ;

process_local_iq(#iq{from = #jid{luser = UserId, lserver = Server}, type = set,
                    sub_els = [#contact_list{type = delta, contacts = Contacts,
                                            index = _Index, last = _Last}]} = IQ) ->
    xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal,
                    contacts = handle_delta_contacts(UserId, Server, Contacts)}).


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
        end, PotentialContactUids).


-spec block_uids(Uid :: binary(), Server :: binary(), Ouids :: list(binary())) -> ok.
block_uids(Uid, Server, Ouids) ->
    %% TODO(murali@): Add batched api for friends.
    lists:foreach(fun(Ouid) -> remove_friend(Uid, Server, Ouid) end, Ouids),
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
                        true -> add_friend(Uid, Server, Ouid);
                        false -> ok
                    end;
                {error, missing} -> ok
            end
        end, Ouids),
    ok.


-spec trigger_full_contact_sync(Uid :: binary()) -> ok.
trigger_full_contact_sync(Uid) ->
    Server = util:get_host(),
    ?INFO_MSG("Trigger full contact sync for user: ~p", [Uid]),
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


-spec get_role_value(atom()) -> list().
get_role_value(true) ->
    <<"friends">>;
get_role_value(false) ->
    <<"none">>.


-spec obtain_user_id(binary()) -> binary() | undefined.
obtain_user_id(Phone) ->
    ejabberd_auth_halloapp:get_uid(Phone).


-spec get_phone(UserId :: binary()) -> binary().
get_phone(UserId) ->
    ejabberd_auth_halloapp:get_phone(UserId).

-spec handle_delta_contacts(UserId :: binary(), Server :: binary(),
        Contacts :: [contact()]) -> [contact()].
handle_delta_contacts(UserId, Server, Contacts) ->
    {DeleteContactsList, AddContactsList} = lists:partition(
            fun(#contact{type = Type}) ->
                Type == delete
            end, Contacts),
    DeleteContactPhones = lists:map(
            fun(Contact) ->
                Contact#contact.normalized
            end, DeleteContactsList),
    remove_contact_phones(UserId, Server, DeleteContactPhones),
    normalize_and_insert_contacts(UserId, Server, AddContactsList, undefined).


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
    ?INFO_MSG("Full contact sync stats: uid: ~p, old_contacts: ~p, new_contacts: ~p, "
            "add_contacts: ~p, delete_contacts: ~p", [UserId, sets:size(OldContactSet),
            sets:size(NewContactSet), sets:size(AddContactSet), sets:size(DeleteContactSet)]),
    ?INFO_MSG("Full contact sync: uid: ~p, add_contacts: ~p, delete_contacts: ~p",
                [UserId, AddContactSet, DeleteContactSet]),
    %% TODO(murali@): Update this after moving pubsub to redis.
    remove_contacts_and_notify(UserId, Server, UserPhone,
            sets:to_list(DeleteContactSet), OldReverseContactSet),
    %% TODO(vipin): newness of contacts in AddContactSet needs to be used in update_and_...(...).
    lists:foreach(
        fun(ContactPhone) ->
            update_and_notify_contact(UserId, UserPhone, OldContactSet,
                    OldReverseContactSet, Server, ContactPhone, yes)
        end, sets:to_list(AddContactSet)),
    %% finish_sync will add various contacts and their reverse mapping in the db.
    model_contacts:finish_sync(UserId, SyncId),
    EndTime = os:system_time(microsecond),
    T = EndTime - StartTime,
    ?INFO_MSG("Time taken: ~w us", [T]),
    ok.


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
                NewAcc = case {NewContact#contact.normalized, NewContact#contact.userid} of
                    {undefined, _} -> {PhoneAcc, UnregisteredPhoneAcc};
                    {NormPhone, undefined} -> {[PhoneAcc], [NormPhone | UnregisteredPhoneAcc]};
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
        _OldReverseContactSet, _Server, #contact{raw = undefined}, _SyncId) ->
    #contact{};
normalize_and_update_contact(UserId, UserRegionId, UserPhone, OldContactSet,
        OldReverseContactSet, Server, Contact, SyncId) ->
    RawPhone = Contact#contact.raw,
    ContactPhone = mod_libphonenumber:normalize(RawPhone, UserRegionId),
    NewContact = case ContactPhone of
        undefined ->
            stat:count("HA/contacts", "normalize_fail"),
            #contact{};
        _ ->
            stat:count("HA/contacts", "normalize_success"),
            case SyncId of
                undefined -> update_and_notify_contact(UserId, UserPhone, OldContactSet,
                        OldReverseContactSet, Server, ContactPhone, yes);
                _ -> update_and_notify_contact(UserId, UserPhone, OldContactSet,
                        OldReverseContactSet, Server, ContactPhone, no)
            end
    end,
    NewContact#contact{raw = RawPhone}.


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
        undefined -> #contact{normalized = ContactPhone, role = <<"none">>};
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
                false -> undefined
            end,
            #contact{userid = ContactId, avatarid = AvatarId, normalized = ContactPhone,
                     role = Role}
    end.


-spec add_friend(Uid :: binary(), Server :: binary(), Ouid :: binary()) -> ok.
add_friend(Uid, Server, Ouid) ->
    ?INFO_MSG("~p is friends with ~p", [Uid, Ouid]),
    model_friends:add_friend(Uid, Ouid),
    ejabberd_hooks:run(add_friend, Server, [Uid, Server, Ouid]).


-spec remove_friend(Uid :: binary(), Server :: binary(), Ouid :: binary()) -> ok.
remove_friend(Uid, Server, Ouid) ->
    ?INFO_MSG("~p is no longer friends with ~p", [Uid, Ouid]),
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
                    notify_contact_about_user(UserId, UserPhone, Server, ContactId, <<"none">>);
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
        ContactId :: binary(), Role :: list()) -> ok.
notify_contact_about_user(UserId, _UserPhone, _Server, UserId, _Role) ->
    ok;
notify_contact_about_user(UserId, UserPhone, Server, ContactId, Role) ->
    AvatarId = case Role of
        <<"none">> -> undefined;
        <<"friends">> -> model_accounts:get_avatar_id_binary(UserId)
    end,
    Contact = #contact{userid = UserId, avatarid = AvatarId, normalized = UserPhone, role = Role},
    SubEls = [#contact_list{type = normal, xmlns = ?NS_NORM, contacts = [Contact]}],
    Stanza = #message{from = jid:make(Server),
                      to = jid:make(ContactId, Server),
                      sub_els = SubEls},
    ?DEBUG("Notifying contact: ~p about user: ~p using stanza: ~p",
            [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).


-spec probe_contact_about_user(UserId :: binary(), UserPhone :: binary(),
        Server :: binary(), ContactId :: binary()) -> ok.
probe_contact_about_user(UserId, UserPhone, Server, ContactId) ->
    ?INFO_MSG("UserId: ~s, ContactId: ~s", [UserId, ContactId]),
    <<HashValue:?PROBE_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, UserPhone),
    send_probe_message(UserId, HashValue, ContactId, Server),
    ok.


-spec send_probe_message(UserId :: binary(), HashValue :: binary(),
        ContactId :: binary(), Server :: binary()) -> ok.
send_probe_message(UserId, HashValue, ContactId, Server) ->
    SubEl = #contact_list{
        type = normal,
        xmlns = ?NS_NORM,
        contact_hash = [base64:encode(HashValue)]},
    Stanza = #message{
        from = jid:make(Server),
        to = jid:make(ContactId, Server),
        sub_els = [SubEl]},
    ?DEBUG("Probing contact: ~p about user: ~p using stanza: ~p",
            [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).


