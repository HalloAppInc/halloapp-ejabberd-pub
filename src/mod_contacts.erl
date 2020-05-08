%%%----------------------------------------------------------------------
%%% File    : mod_contacts.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This file handles the iq packet queries with a custom namespace
%%% (<<"halloapp:user:contacts">>) that we defined.
%%% We define custom xml records of the following type:
%%% "contact_list", "contact", "raw", "uuid", role", "normalized" in
%%% xmpp/specs/xmpp_codec.spec file.
%%% TODO(murali@): test this module for other international countries.
%%%----------------------------------------------------------------------

-module(mod_contacts).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").

-define(NS_NORM, <<"halloapp:user:contacts">>).
%% TODO(murali@:) remove this after migration!
-define(SERVER, <<"s.halloapp.net">>).

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% IQ handlers and hooks.
-export([process_local_iq/1, remove_user/2, re_register_user/2]).

-export([
    is_bidirectional_contact/2,
    finish_sync/3
]).

start(Host, Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_NORM, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50),
    phone_number_util:init(Host, Opts),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_NORM),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 50),
    phone_number_util:close(Host),
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
                    sub_els = [#contact_list{type = full, contacts = Contacts,
                                            syncid = SyncId, index = Index, last = Last}]} = IQ) ->
    ?INFO_MSG("Full contact sync Uid: ~p, syncid: ~p, index: ~p, last: ~p, num_contacts: ~p",
            [UserId, SyncId, Index, Last, length(Contacts)]),
    case SyncId of
        undefined ->
            Txt = ?T("Invalid syncid in the request"),
            ?WARNING_MSG("process_local_iq: ~p, ~p", [IQ, Txt]),
            ResultIQ = xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        _ ->
            ResultIQ = xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM,
                    syncid = SyncId, type = normal,
                    contacts = normalize_and_sync_contacts(UserId, Server, Contacts, SyncId)})
    end,
    case Last of
        false -> ok;
        true -> spawn(?MODULE, finish_sync, [UserId, Server, SyncId])
    end,
    ResultIQ;

process_local_iq(#iq{from = #jid{luser = UserId, lserver = Server}, type = set,
                    sub_els = [#contact_list{type = delta, contacts = Contacts,
                                            index = _Index, last = _Last}]} = IQ) ->
    xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal,
                    contacts = handle_delta_contacts(UserId, Server, Contacts)}).


remove_user(UserId, Server) ->
    delete_all_contacts(UserId, Server).


-spec re_register_user(User :: binary(), Server :: binary()) -> ok.
re_register_user(UserId, Server) ->
    delete_all_contacts(UserId, Server).


%%====================================================================
%% internal functions
%%====================================================================

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


-spec is_contact(UserId :: binary(), ContactPhone :: binary()) -> boolean().
is_contact(UserId, ContactPhone) ->
    model_contacts:is_contact(UserId, ContactPhone).


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
    delete_contact_phones(UserId, Server, DeleteContactPhones),
    normalize_and_add_contacts(UserId, Server, AddContactsList).


-spec delete_all_contacts(UserId :: binary(), Server :: binary()) -> ok.
delete_all_contacts(UserId, Server) ->
    {ok, ContactPhones} = model_contacts:get_contacts(UserId),
    delete_contact_phones(UserId, Server, ContactPhones).


-spec finish_sync(UserId :: binary(), Server :: binary(), SyncId :: binary()) -> ok.
finish_sync(UserId, Server, SyncId) ->
    {ok, OldContactList} = model_contacts:get_contacts(UserId),
    {ok, NewContactList} = model_contacts:get_sync_contacts(UserId, SyncId),
    OldContactSet = sets:from_list(OldContactList),
    NewContactSet = sets:from_list(NewContactList),
    DeleteContactSet = sets:subtract(OldContactSet, NewContactSet),
    AddContactSet = sets:subtract(NewContactSet, OldContactSet),
    ?INFO_MSG("Full contact sync stats: uid: ~p, old_contacts: ~p, new_contacts: ~p"
            "add_contacts: ~p, delete_contacts: ~p", [UserId, sets:size(OldContactSet),
            sets:size(NewContactSet), sets:size(AddContactSet), sets:size(DeleteContactSet)]),
    ?INFO_MSG("Full contact sync: uid: ~p, add_contacts: ~p, delete_contacts: ~p",
                [UserId, AddContactSet, DeleteContactSet]),
    %% TODO(murali@): Update this after moving pubsub to redis.
    delete_contact_phones(UserId, Server, sets:to_list(DeleteContactSet)),
    lists:foreach(
        fun(ContactPhone) ->
            add_contact_phone_and_notify_user(UserId, Server, ContactPhone)
        end, sets:to_list(AddContactSet)),
    model_contacts:finish_sync(UserId, SyncId).


%%====================================================================
%% add_contact
%%====================================================================

-spec normalize_and_sync_contacts(UserId :: binary(), Server :: binary(),
        Contacts :: [contact()], SyncId :: binary()) -> [contact()].
normalize_and_sync_contacts(UserId, Server, Contacts, SyncId) ->
    UserNumber = get_phone(UserId),
    UserRegionId = mod_libphonenumber:get_region_id(UserNumber),
    lists:map(
            fun(Contact) ->
                normalize_and_sync_contact(UserId, UserRegionId, Server, Contact, SyncId)
            end, Contacts).


-spec normalize_and_sync_contact(UserId :: binary(), UserRegionId :: binary(),
        Server :: binary(), Contact :: contact(), SyncId :: binary()) -> contact().
normalize_and_sync_contact(_UserId, _UserRegionId, _Server, #contact{raw = undefined}, _SyncId) ->
    #contact{};
normalize_and_sync_contact(UserId, UserRegionId, _Server, Contact, SyncId) ->
    RawPhone = Contact#contact.raw,
    ContactPhone = mod_libphonenumber:normalize(RawPhone, UserRegionId),
    case ContactPhone of
        undefined ->
            #contact{raw = RawPhone};
        _ ->
            ContactId = obtain_user_id(ContactPhone),
            model_contacts:sync_contacts(UserId, SyncId, [ContactPhone]),
            case ContactId of
                undefined ->
                    #contact{raw = RawPhone, normalized = ContactPhone, role = <<"none">>};
                _ ->
                    IsFriends = model_friends:is_friend(UserId, ContactId),
                    Role = get_role_value(IsFriends),
                    #contact{raw = RawPhone, userid = ContactId,
                            normalized = ContactPhone, role = Role}
            end
    end.


-spec normalize_and_add_contacts(UserId :: binary(), Server :: binary(),
        Contacts :: [contact()]) -> [contact()].
normalize_and_add_contacts(UserId, Server, Contacts) ->
    UserNumber = get_phone(UserId),
    UserRegionId = mod_libphonenumber:get_region_id(UserNumber),
    lists:map(
            fun(Contact) ->
                normalize_and_add_contact(UserId, UserRegionId, Server, Contact)
            end, Contacts).


-spec normalize_and_add_contact(UserId :: binary(), UserRegionId :: binary(),
        Server :: binary(), Contact :: contact()) -> contact().
normalize_and_add_contact(_UserId, _UserRegionId, _Server, #contact{raw = undefined}) ->
    #contact{};
normalize_and_add_contact(UserId, UserRegionId, Server, Contact) ->
    RawPhone = Contact#contact.raw,
    ContactPhone = mod_libphonenumber:normalize(RawPhone, UserRegionId),
    NewContact = case ContactPhone of
                undefined ->
                    #contact{};
                _ ->
                    add_contact_phone(UserId, Server, ContactPhone)
            end,
    NewContact#contact{raw = RawPhone}.


-spec add_contact_phone(UserId :: binary(), Server :: binary(),
        ContactPhone :: binary()) -> contact().
add_contact_phone(UserId, Server, ContactPhone) ->
    UserPhone = get_phone(UserId),
    NotifyContact = not is_contact(UserId, ContactPhone),
    ContactId = obtain_user_id(ContactPhone),
    model_contacts:add_contact(UserId, ContactPhone),
    case ContactId of
        undefined ->
            #contact{normalized = ContactPhone, role = <<"none">>};
        _ ->
            IsFriends = update_friends_table(UserId, ContactId, UserPhone, ContactPhone, Server),
            Role = get_role_value(IsFriends),
            case NotifyContact of
                true -> notify_contact_about_user(UserId, Server, ContactId, Role);
                false -> ok
            end,
            #contact{userid = ContactId, normalized = ContactPhone, role = Role}
    end.


-spec add_contact_phone_and_notify_user(UserId :: binary(), Server :: binary(),
        ContactPhone :: binary()) -> contact().
add_contact_phone_and_notify_user(UserId, Server, ContactPhone) ->
    Contact = add_contact_phone(UserId, Server, ContactPhone),
    case Contact#contact.userid of
        undefined -> ok;
        _ ->
            notify_contact_about_user(Contact#contact.userid, Server, UserId, Contact#contact.role)
    end,
    Contact.


-spec update_friends_table(
        UserId :: binary(), ContactId :: binary(), UserPhone :: binary(),
        ContactPhone :: binary(), Server :: binary()) -> boolean().
update_friends_table(UserId, ContactId, UserPhone, ContactPhone, Server) ->
    case is_bidirectional_contact_internal(UserId, ContactId, UserPhone, ContactPhone) of
        true ->
            ?INFO_MSG("~p is friends with ~p", [UserId, ContactId]),
            model_friends:add_friend(UserId, ContactId),
            ejabberd_hooks:run(add_friend, Server, [UserId, Server, ContactId]),
            true;
        false ->
            ?INFO_MSG("~p is no longer friends with ~p", [UserId, ContactId]),
            model_friends:remove_friend(UserId, ContactId),
            ejabberd_hooks:run(remove_friend, Server, [UserId, Server, ContactId]),
            false
    end.


%%====================================================================
%% delete_contact
%%====================================================================


-spec delete_contact_phones(
        UserId :: binary(), Server :: binary(), ContactPhones :: [binary()]) -> ok.
delete_contact_phones(UserId, Server, ContactPhones) ->
    lists:foreach(
            fun(ContactPhone) ->
                delete_contact_phone(UserId, Server, ContactPhone)
            end, ContactPhones).


%% Delete all associated info with the contact and the user.
-spec delete_contact_phone(UserId :: binary(),
        Server :: binary(), ContactPhones :: binary()) -> {ok, any()} | {error, any()}.
delete_contact_phone(UserId, Server, ContactPhone) ->
    ContactId = obtain_user_id(ContactPhone),
    model_contacts:remove_contact(UserId, ContactPhone),
    case ContactId of
        undefined ->
            ok;
        _ ->
            remove_friend_and_notify(UserId, Server, ContactId)
    end.


-spec remove_friend_and_notify(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
remove_friend_and_notify(UserId, Server, ContactId) ->
    model_friends:remove_friend(UserId, ContactId),
    ejabberd_hooks:run(remove_friend, Server, [UserId, Server, ContactId]),
    notify_contact_about_user(UserId, Server, ContactId, <<"none">>).


%%====================================================================
%% notify contact
%%====================================================================

%% Notifies contact about the user using the UserId and the role element to indicate
%% if they are now friends or not on halloapp.
-spec notify_contact_about_user(UserId :: binary(), Server :: binary(),
        ContactId :: binary(), Role :: list()) -> ok.
notify_contact_about_user(UserId, _Server, UserId, _Role) ->
    ok;
notify_contact_about_user(UserId, Server, ContactId, Role) ->
    Normalized = get_phone(UserId),
    Contact = #contact{userid = UserId, normalized = Normalized, role = Role},
    SubEls = [#contact_list{type = normal, xmlns = ?NS_NORM, contacts = [Contact]}],
    Stanza = #message{from = jid:make(Server),
                      to = jid:make(ContactId, Server),
                      sub_els = SubEls},
    ?DEBUG("Notifying contact: ~p about user: ~p using stanza: ~p",
                                                [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).


%%====================================================================
%% check for friends
%%====================================================================


%% Checks if the both the user and the contact are connected on halloapp or not.
-spec is_bidirectional_contact(UserId :: binary(), ContactId :: binary()) -> boolean().
is_bidirectional_contact(UserId, ContactId) ->
    UserPhone = get_phone(UserId),
    ContactPhone = get_phone(ContactId),
    is_bidirectional_contact_internal(UserId, ContactId, UserPhone, ContactPhone).


%% Checks if the both the user and the contact are connected on halloapp or not.
-spec is_bidirectional_contact_internal(
        UserId :: binary(), ContactId :: binary(),
        UserPhone :: binary(), ContactPhone :: binary()) -> boolean().
is_bidirectional_contact_internal(UserId, ContactId, UserPhone, ContactPhone) ->
    is_contact(UserId, ContactPhone) andalso is_contact(ContactId, UserPhone).

