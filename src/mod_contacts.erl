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

-include("phone_number.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("user_info.hrl").

-define(NS_NORM, <<"halloapp:user:contacts">>).

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% IQ handlers and hooks.
-export([process_local_iq/1, remove_user/2]).
%% export this for async use.
-export([finish_sync/3]).
%% api
-export([is_friend/3, migrate_all_contacts/0]).


start(Host, Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_NORM, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    phone_number_util:init(Host, Opts),
    mod_contacts_mnesia:init(Host, Opts),
    ok.

stop(Host) ->
    mod_contacts_mnesia:close(),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_NORM),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 40),
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
    case SyncId of
        undefined ->
            Txt = ?T("Invalid syncid in the request"),
            ?WARNING_MSG("process_local_iq: ~p, ~p", [IQ, Txt]),
            ResultIQ = xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        _ ->
            case Index of
                0 -> insert_syncid(UserId, Server, SyncId);
                _ -> ok
            end,
            ResultIQ = xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM,
                            syncid = SyncId, type = normal,
                            contacts = add_contacts(UserId, Server, Contacts, full, SyncId)})
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


%% remove_user hook deletes all contacts of the user
%% which involves removing all the subscriptions and affiliations and notifying the contacts.
remove_user(UserId, Server) ->
    delete_all_contacts(UserId, Server).


%%====================================================================
%% API
%%====================================================================

-spec is_friend(binary(), binary(), binary()) -> boolean().
is_friend(UserId, Server, ContactId) ->
    is_friend_internal(UserId, Server, ContactId).


%%====================================================================
%% internal functions
%%====================================================================

-spec get_role_value(atom()) -> list().
get_role_value(true) ->
    "friends";
get_role_value(false) ->
    "none".


%% Obtains the user for a user: uses the id if it already exists, else creates one.
-spec obtain_user_id(binary()) -> binary() | undefined.
obtain_user_id(Phone) ->
    ejabberd_auth_halloapp:get_uid(Phone).


-spec get_phone(UserId :: binary()) -> binary().
get_phone(UserId) ->
    ejabberd_auth_halloapp:get_phone(UserId).


-spec is_contact(UserId :: binary(), Server :: binary(), ContactNumber :: binary()) -> boolean().
is_contact(UserId, Server, ContactNumber) ->
    %%model_contacts:is_contact(UserId, ContactNumber).
    mod_contacts_mnesia:check_if_contact_exists({UserId, Server}, {ContactNumber, Server}).


-spec add_contacts(UserId :: binary(), Server :: binary(), ContactList :: [contact()],
                    SyncType :: full | delta, SyncId :: undefined | binary()) -> [contact()].
add_contacts(UserId, Server, Contacts, SyncType, SyncId) ->
    lists:map(fun(Contact) -> add_contact(UserId, Server, Contact, SyncType, SyncId) end, Contacts).


%% Handle delta contact sync requests.
%% Always delete contacts first and only then add contacts.
-spec handle_delta_contacts(UserId :: binary(), Server :: binary(),
                            Contacts :: [contact()]) -> [contact()].
handle_delta_contacts(UserId, Server, Contacts) ->
    UserSyncId = fetch_syncid(UserId, Server),
    {DeleteContactsList, AddContactsList} = lists:partition(fun(#contact{type = Type}) ->
                                                                Type == delete
                                                            end, Contacts),
    delete_contacts(UserId, Server, DeleteContactsList),
    add_contacts(UserId, Server, AddContactsList, delta, UserSyncId).


%% Deletes the contacts obtained in an iq stanza from the user.
-spec delete_contacts(UserId :: binary(), Server :: binary(), Contacts :: [contact()]) -> ok.
delete_contacts(_UserId, _Server, []) ->
    [];
delete_contacts(UserId, Server, [First | Rest]) ->
    Normalized = First#contact.normalized,
    delete_contact_number(UserId, Server, Normalized),
    delete_contacts(UserId, Server, Rest).


%% Deletes all contacts of the user and all the associated information in pubsub nodes as well.
-spec delete_all_contacts(UserId :: binary(), Server :: binary()) -> ok.
delete_all_contacts(UserId, Server) ->
    {ok, ContactNumbers} = model_contacts:get_contacts(UserId),
    delete_contact_numbers(UserId, Server, ContactNumbers).


%% Finishes contact sync by updating contacts and friends lists accordingly.
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
    delete_contact_numbers(UserId, Server, sets:to_list(DeleteContactSet)),
    %% Server is updating contacts now, so we need to notify user.
    NotifyUser = true,
    add_contact_numbers(UserId, Server, sets:to_list(NewContactSet), NotifyUser, SyncId),
    model_contacts:finish_sync(UserId, SyncId),
    delete_old_contacts(UserId, Server, SyncId).

%%====================================================================
%% add_contact
%%====================================================================

-spec add_contact(
        UserId :: binary(), Server :: binary(), Contact :: contact(),
        SyncType :: full | delta, SyncId :: undefined | binary()) -> contact().
add_contact(UserId, Server, Contact, full, SyncId) ->
    Raw = Contact#contact.raw,
    ContactNumber = normalize(Raw),
    UserNumber = get_phone(UserId),
    case ContactNumber of
        undefined ->
            #contact{raw = Raw};
        _ ->
            ContactId = obtain_user_id(ContactNumber),
            model_contacts:sync_contacts(UserId, SyncId, [ContactNumber]),
            IsFriends = check_if_friends_internal(UserId, ContactId, UserNumber, ContactNumber, Server),
            Role = get_role_value(IsFriends),
            #contact{raw = Raw,
                     userid = ContactId,
                     normalized = ContactNumber,
                     role = Role}
    end;
add_contact(UserId, Server, Contact, delta, SyncId) ->
    Raw = Contact#contact.raw,
    ContactNumber = normalize(Raw),
    %% Server will respond with IQ to user: so no need to notify user.
    NotifyUser = false,
    case ContactNumber of
        undefined ->
            #contact{raw = Raw};
        _ ->
            add_contact_number(UserId, Server, Raw, ContactNumber, NotifyUser, SyncId)
    end.


-spec add_contact_numbers(
        UserId :: binary(), Server :: binary(), ContactNumbers :: [binary()],
        NotifyUser :: boolean(), SyncId :: binary()) -> ok.
add_contact_numbers(UserId, Server, ContactNumbers, NotifyUser, SyncId) ->
    lists:foreach(
            fun(ContactNumber) ->
                add_contact_number(UserId, Server, ContactNumber, NotifyUser, SyncId)
            end, ContactNumbers).


-spec add_contact_number(
        UserId :: binary(), Server :: binary(), ContactNumber :: binary(),
        NotifyUser :: boolean(), SyncId :: binary()) -> contact().
add_contact_number(UserId, Server, ContactNumber, NotifyUser, SyncId) ->
    add_contact_number(UserId, Server, ContactNumber, ContactNumber, NotifyUser, SyncId).


-spec add_contact_number(
        UserId :: binary(), Server :: binary(), Raw :: binary(), ContactNumber :: binary(),
        NotifyUser :: boolean(), SyncId :: binary()) -> contact().
add_contact_number(UserId, Server, Raw, ContactNumber, NotifyUser, SyncId) ->
    UserNumber = get_phone(UserId),
    NotifyContact = not is_contact(UserId, Server, ContactNumber),
    ContactId = obtain_user_id(ContactNumber),
    model_contacts:add_contact(UserId, ContactNumber),
    ShouldNotifyContact = insert_contact(UserId, Server, ContactNumber, SyncId),
    Result = case ContactId of
                undefined ->
                    false;
                _ ->
                    update_friends_table(UserId, ContactId, UserNumber, ContactNumber, Server)
            end,
    Role = get_role_value(Result),
    case ShouldNotifyContact =:= true andalso ContactId =/= undefined of
        true ->
            subscribe_to_each_others_nodes(UserId, Server, ContactId, Role),
            check_and_notify_contact_about_user(NotifyContact, UserId, Server, ContactId, Role),
            check_and_notify_contact_about_user(NotifyUser, ContactId, Server, UserId, Role);
        false ->
            ok
    end,
    #contact{raw = Raw,
             userid = ContactId,
             normalized = ContactNumber,
             role = Role}.


%% Check if the user and the contact are friends or not and update friends table accordingly.
%% TODO(murali@): Fix issue with model_friends gen_server process.
-spec update_friends_table(
        UserId :: binary(), ContactId :: binary(), UserNumber :: binary(),
        ContactNumber :: binary(), Server :: binary()) -> boolean().
update_friends_table(UserId, ContactId, UserNumber, ContactNumber, Server) ->
    case check_if_friends_internal(UserId, ContactId, UserNumber, ContactNumber, Server) of
        true ->
            model_friends:add_friend(UserId, ContactId),
            true;
        false ->
            model_friends:remove_friend(UserId, ContactId),
            false
    end.


%%====================================================================
%% delete_contact
%%====================================================================


-spec delete_contact_numbers(
        UserId :: binary(), Server :: binary(), ContactNumbers :: [binary()]) -> ok.
delete_contact_numbers(UserId, Server, ContactNumbers) ->
    lists:foreach(
            fun(ContactNumber) ->
                delete_contact_number(UserId, Server, ContactNumber)
            end, ContactNumbers).


%% Delete all associated info with the contact and the user.
-spec delete_contact_number(binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
delete_contact_number(UserId, Server, ContactNumber) ->
    ContactId = obtain_user_id(ContactNumber),
    mod_contacts_mnesia:delete_contact({UserId, Server}, {ContactNumber, Server}),
    model_contacts:remove_contact(UserId, ContactNumber),
    case ContactId of
        undefined ->
            ok;
        _ ->
            remove_friend_and_notify(UserId, Server, ContactId)
    end.


-spec remove_friend_and_notify(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
remove_friend_and_notify(UserId, Server, ContactId) ->
    model_friends:remove_friend(UserId, ContactId),
    unsubscribe_to_each_others_nodes(UserId, Server, ContactId),
    notify_contact_about_user(UserId, Server, ContactId, "none").


%%====================================================================
%% pubsub: subscribe
%%====================================================================

%% Subscribes the User to the nodes of the ContactNumber and vice-versa if they are 'friends'.
-spec subscribe_to_each_others_nodes(binary(), binary(), binary(), list()) -> ok.
subscribe_to_each_others_nodes(_UserId, _Server, _ContactId, "none") ->
    ok;
subscribe_to_each_others_nodes(UserId, Server, ContactId, "friends") ->
    subscribe_to_each_others_node(UserId, Server, ContactId, feed),
    subscribe_to_each_others_node(UserId, Server, ContactId, metadata),
    ok;
subscribe_to_each_others_nodes(UserId, Server, ContactId, Role) ->
    ?ERROR_MSG("Invalid role:~p for a contact: ~p for user: ~p",
                                                    [Role, ContactId, {UserId, Server}]),
    ok.



%% Subscribes the User to the node of the ContactNumber and vice-versa.
-spec subscribe_to_each_others_node(binary(), binary(), binary(), atom()) -> ok.
subscribe_to_each_others_node(UserId, Server, ContactId, feed) ->
    UserFeedNodeName = util:get_feed_pubsub_node_name(UserId),
    ContactFeedNodeName =  util:get_feed_pubsub_node_name(ContactId),
    subscribe_to_node(UserId, Server, ContactId, ContactFeedNodeName),
    subscribe_to_node(ContactId, Server, UserId, UserFeedNodeName),
    ok;
subscribe_to_each_others_node(UserId, Server, ContactId, metadata) ->
    UserMetadataNodeName = util:get_metadata_pubsub_node_name(UserId),
    ContactMetadataNodeName =  util:get_metadata_pubsub_node_name(ContactId),
    subscribe_to_node(UserId, Server, ContactId, ContactMetadataNodeName),
    subscribe_to_node(ContactId, Server, UserId, UserMetadataNodeName),
    ok.



%% subscribes the User to the node.
-spec subscribe_to_node(binary(), binary(), binary(), binary()) -> ok.
subscribe_to_node(SubscriberId, Server, OwnerId, NodeName) ->
    Host = mod_pubsub:host(Server),
    Node = NodeName,
    %% Affiliation
    Affs = [#ps_affiliation{jid = jid:make(SubscriberId, Server), type = member}],
    OwnerJID = jid:make(OwnerId, Server),
    Result1 = mod_pubsub:set_affiliations(Host, Node, OwnerJID, Affs),
    ?DEBUG("Owner: ~p tried to set affs to pubsub node: ~p, result: ~p",
                                                        [OwnerJID, Node, Result1]),
    %% Subscription
    SubscriberJID = jid:make(SubscriberId, Server),
    Config = [],
    Result2 = mod_pubsub:subscribe_node(Host, Node, SubscriberJID, SubscriberJID, Config),
    ?DEBUG("User: ~p tried to subscribe to pubsub node: ~p, result: ~p",
                                                        [SubscriberJID, Node, Result2]),
    ok.


%%====================================================================
%% pubsub: unsubscribe
%%====================================================================

%% Unsubscribes the User to the nodes of the ContactNumber and vice-versa.
-spec unsubscribe_to_each_others_nodes(binary(), binary(), binary()) -> ok.
unsubscribe_to_each_others_nodes(UserId, Server, ContactId) ->
    unsubscribe_to_each_others_node(UserId, Server, ContactId, feed),
    unsubscribe_to_each_others_node(UserId, Server, ContactId, metadata),
    ok.



%% Unsubscribes the User to the node of the ContactNumber and vice-versa.
-spec unsubscribe_to_each_others_node(binary(), binary(), binary(), atom()) -> ok.
unsubscribe_to_each_others_node(UserId, Server, ContactId, feed) ->
    UserFeedNodeName = util:get_feed_pubsub_node_name(UserId),
    ContactFeedNodeName =  util:get_feed_pubsub_node_name(ContactId),
    unsubscribe_to_node(UserId, Server, ContactId, ContactFeedNodeName),
    unsubscribe_to_node(ContactId, Server, UserId, UserFeedNodeName),
    ok;
unsubscribe_to_each_others_node(UserId, Server, ContactId, metadata) ->
    UserMetadataNodeName = util:get_metadata_pubsub_node_name(UserId),
    ContactMetadataNodeName =  util:get_metadata_pubsub_node_name(ContactId),
    unsubscribe_to_node(UserId, Server, ContactId, ContactMetadataNodeName),
    unsubscribe_to_node(ContactId, Server, UserId, UserMetadataNodeName),
    ok.



%% Unsubscribes the User to the node.
-spec unsubscribe_to_node(binary(), binary(), binary(), binary()) -> ok.
unsubscribe_to_node(SubscriberId, Server, OwnerId, NodeName) ->
    Host = mod_pubsub:host(Server),
    Node = NodeName,
    %% Affiliation
    Affs = [#ps_affiliation{jid = jid:make(SubscriberId, Server), type = none}],
    OwnerJID = jid:make(OwnerId, Server),
    Result1 = mod_pubsub:set_affiliations(Host, Node, OwnerJID, Affs),
    ?DEBUG("Owner: ~p tried to set affs to pubsub node: ~p, result: ~p",
                                                        [OwnerJID, Node, Result1]),
    %% Subscription
    SubscriberJID = jid:make(SubscriberId, Server),
    SubId = all,
    Result2 = mod_pubsub:unsubscribe_node(Host, Node, SubscriberJID, SubscriberJID, SubId),
    ?DEBUG("User: ~p tried to unsubscribe to pubsub node: ~p, result: ~p",
                                                        [SubscriberJID, Node, Result2]),
    ok.

%%====================================================================
%% notify contact
%%====================================================================

%% Notifies contact about the user with its role element.
-spec check_and_notify_contact_about_user(NotifyContact :: boolean(), UserId :: binary(),
                                          Server :: binary(), ContactId :: binary(),
                                          Role :: list()) -> ok.
check_and_notify_contact_about_user(false, _UserId, _Server, _ContactId, _Role) ->
    ok;
check_and_notify_contact_about_user(true, UserId, Server, ContactId, Role) ->
    notify_contact_about_user(UserId, Server, ContactId, Role).


%% Notifies contact number about the user using the UserId and the role element to indicate
%% if they are now friends or not on halloapp.
-spec notify_contact_about_user(UserId :: binary(), Server :: binary(), ContactId :: binary(), Role :: list()) -> ok.
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
-spec is_friend_internal(binary(), binary(), binary()) -> boolean().
is_friend_internal(UserId, Server, ContactId) ->
    UserNumber = get_phone(UserId),
    ContactNumber = get_phone(ContactId),
    check_if_friends_internal(UserId, ContactId, UserNumber, ContactNumber, Server).



%% Checks if the both the user and the contact are connected on halloapp or not.
-spec check_if_friends_internal(binary(), binary(), binary(), binary(), binary()) -> boolean().
check_if_friends_internal(UserId, ContactId, UserNumber, ContactNumber, Server) ->
    is_contact(UserId, Server, ContactNumber) andalso is_contact(ContactId, Server, UserNumber).


%%====================================================================
%% normalize phone numbers
%%====================================================================

%% Normalizes a phone number and returns the final result.
%% Drops phone numbers that it could not normalize for now.
-spec normalize(binary()) -> binary() | undefined.
normalize(undefined) ->
    ?ERROR_MSG("Expected a number as input: ~p", [undefined]),
    undefined;
normalize(Number) ->
    Result = parse(Number),
    case Result == <<"">> of
        true ->
            undefined;
        false ->
            Result
    end.



%% Parse a phone number using the phone number util and returns a parsed phone number if
%% it turns out to be valid. Returns the result in binary format.
-spec parse(binary()) -> binary().
parse(Number) ->
    case phone_number_util:parse_phone_number(Number, <<"US">>) of
        {ok, PhoneNumberState} ->
            case PhoneNumberState#phone_number_state.valid of
                true ->
                    NewNumber = PhoneNumberState#phone_number_state.e164_value;
                _ ->
                    NewNumber = "" % Use empty string as normalized number for now.
            end;
        _ ->
            NewNumber = "" % Use empty string as normalized number for now.
    end,
    list_to_binary(NewNumber).

%%====================================================================
%% mnesia-related contact sync stuff
%%====================================================================

-spec insert_syncid(binary(), binary(), binary()) -> ok.
insert_syncid(UserId, Server, SyncId) ->
    Username = {UserId, Server},
    case mod_contacts_mnesia:insert_syncid(Username, SyncId) of
        {ok, _} ->
            ok;
        {error, _} ->
            ?ERROR_MSG("Failed to insert syncid: ~p for username: ~p", [SyncId, Username])
    end.

%% Insert these contacts as user's contacts in an mnesia table.
-spec insert_contact(binary(), binary(), binary(), binary()) -> boolean().
insert_contact(UserId, Server, ContactNumber, SyncId) ->
    Username = {UserId, Server},
    Contact = {ContactNumber, Server},
    Notify = case mod_contacts_mnesia:delete_contact(Username, Contact) of
                {ok, ok} ->
                    false;
                _ ->
                    true
             end,
    case mod_contacts_mnesia:insert_contact(Username, Contact, SyncId) of
        {ok, _} ->
            Notify;
        {error, _} ->
            false
    end.


-spec fetch_syncid(binary(), binary()) -> binary().
fetch_syncid(UserId, Server) ->
    Username = {UserId, Server},
    case mod_contacts_mnesia:fetch_syncid(Username) of
        {ok, [UserSyncIds | _]} ->
            UserSyncIds#user_syncids.syncid;
        {error, _} = _Result ->
            <<"">>
    end.


%% Delete only the old contacts that were probably deleted by the client.
%% This is invoked only on every full-sync-of-contacts.
delete_old_contacts(UserId, Server, CurSyncId) ->
    case mod_contacts_mnesia:fetch_contacts({UserId, Server}) of
        {ok, UserContacts} ->
            lists:foreach(
                    fun(#user_contacts_new{contact = {ContactNumber, _}, syncid = ThenSyncId}) ->
                        case CurSyncId =/= ThenSyncId of
                            true ->
                                mod_contacts_mnesia:delete_contact(
                                        {UserId, Server}, {ContactNumber, Server}, ThenSyncId);
                            false ->
                                ok
                        end
                    end, UserContacts);
        {error, _} ->
            ok
    end,
    ok.


-spec migrate_all_contacts() -> ok.
migrate_all_contacts() ->
    {ok, AllContacts} = mod_contacts_mnesia:fetch_all_contacts(),
    ?INFO_MSG("Migrating all contacts from mnesia to redis: ~p", [length(AllContacts)]),
    lists:foreach(
            fun(#user_contacts_new{username = {UserId, Server}, contact = {ContactNumber, _}}) ->
                migrate_contact(UserId, Server, ContactNumber)
            end, AllContacts).


-spec migrate_contact(UserId :: binary(), Server :: binary(), ContactNumber :: binary()) -> ok.
migrate_contact(UserId, Server, ContactNumber) ->
    UserNumber = get_phone(UserId),
    ContactId = obtain_user_id(ContactNumber),
    model_contacts:add_contact(UserId, ContactNumber),
    case ContactId of
        undefined -> ok;
        _ -> update_friends_table(UserId, ContactId, UserNumber, ContactNumber, Server)
    end.



