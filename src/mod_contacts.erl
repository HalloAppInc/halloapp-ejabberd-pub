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
%%% Type = set/add
%%% The module expects a "contact_list" containing "raw" phone numbers of the
%%% "contacts" of the user.
%%% Client can access/delete/modify any contact using the normalized phone number of the contact.
%%% The module normalizes these phone numbers using the rules defined in the
%%% phone_number_metadata.xml resource file using the phone_number_util module,
%%% inserts these contacts of the users into an mnesia table, checks if the user and
%%% its contacts are connected on halloapp or not, generates user ids for the user and its contact
%%% if necessary, sets the appropriate affiliations to the users pubsub nodes,
%%% subscribes the user to all the pubsub nodes of its contacts,
%%% subscribes all the friend contacts to the user's pubsub node.
%%% Returns a result to the user in an IQ packet: containing the raw number of the contact,
%%% userid of the contact, normalized phone number of the contact and
%%% role indicating if the user and contact are connected on halloapp indicating "friends" in
%%% the role xml element, else indicates "none".
%%% If the type is set, we delete all the previous contacts of the user and start afresh.
%%% If the type is add, then we just handle these new list of contacts.
%%% Type = delete
%%% When a user has been deleted, we delete the user's contact, remove it from the contact
%%% from user's pubsub nodes list of affiliations, we unsubscribe the user to all contact's nodes
%%% and vice-versa. We delete the contact in the user_contacts mnesia table for the user.
%%% Currently, phone number normalization has been tested with the US phone numbers.
%%% TODO(murali@): test this module for other international countries.
%%%----------------------------------------------------------------------

-module(mod_contacts).
-author('murali').
-behaviour(gen_mod).

-include("phone_number.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("user_info.hrl").

-define(NS_NORM, <<"halloapp:user:contacts">>).

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% IQ handlers and hooks.
-export([process_local_iq/1, remove_user/2]).
%% api
-export([is_friend/3]).

%% exports for console debug manual use
-export([normalize_verify_and_subscribe/4, normalize/1, parse/1, insert_syncid/3, insert_contact/4,
        handle_delta_contacts/4, subscribe_to_each_others_nodes/4, subscribe_to_each_others_node/4,
        subscribe_to_node/4, check_if_friends/3, is_friend_internal/3,
        check_if_friends_internal/5, fetch_syncid/2,
        obtain_user_id/1, delete_all_contacts/2, delete_contact/3,
        unsubscribe_to_each_others_nodes/3, unsubscribe_to_each_others_node/4,
        unsubscribe_to_node/4, notify_contact_about_user/3, check_and_send_message_to_contact/5,
        delete_old_contacts/3]).

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

process_local_iq(#iq{from = #jid{luser = UserId, lserver = Server}, type = set,
                    sub_els = [#contact_list{type = full, contacts = Contacts,
                                            syncid = SyncId, index = Index, last = Last}]} = IQ) ->
    case Index of
        0 -> insert_syncid(UserId, Server, SyncId);
        _ -> ok
    end,
    ResultIQ = case Contacts of
        [] -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal});
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM,
                    syncid = SyncId, type = normal,
                    contacts = normalize_verify_and_subscribe(UserId, Server, Contacts, SyncId)})
    end,
    case Last of
        false -> ok;
        true -> delete_old_contacts(UserId, Server, SyncId)
    end,
    ResultIQ;

process_local_iq(#iq{from = #jid{luser = UserId, lserver = Server}, type = set,
                    sub_els = [#contact_list{type = delta, contacts = Contacts,
                                            index = _Index, last = Last}]} = IQ) ->
    UserSyncId = fetch_syncid(UserId, Server),
    ResultIQ = case Contacts of
        [] -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal});
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM,
                    syncid = UserSyncId, type = normal,
                    contacts = handle_delta_contacts(UserId, Server, Contacts, UserSyncId)})
    end,
    case Last of
        false -> ok;
        true -> delete_old_contacts(UserId, Server, UserSyncId)
    end,
    ResultIQ.


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

-spec handle_delta_contacts(binary(), binary(), [#contact{}], binary()) -> [#contact{}].
handle_delta_contacts(UserId, Server, Contacts, UserSyncId) ->
    {DeleteContactsList, AddContactsList} = lists:partition(fun(#contact{type = Type}) ->
                                                                Type == delete
                                                            end, Contacts),
    delete_contacts_iq(UserId, Server, DeleteContactsList),
    normalize_verify_and_subscribe(UserId, Server, AddContactsList, UserSyncId).


%% Deletes the contacts obtained in an iq stanza from the user.
delete_contacts_iq(_UserId, _Server, []) ->
    [];
delete_contacts_iq(UserId, Server, [First | Rest]) ->
    Normalized = First#contact.normalized,
    delete_contact(UserId, Server, Normalized),
    delete_contacts_iq(UserId, Server, Rest).



%% Normalize, Verify and Subscribe the pubsub nodes for the contacts received in an iq.
normalize_verify_and_subscribe(_UserId, _Server, [], _SyncId) ->
    [];
normalize_verify_and_subscribe(UserId, Server, Contacts, SyncId) ->
    normalize_verify_and_subscribe_contacts(UserId, Server, Contacts, SyncId, []).



%% Normalizes, verifies the connection between the user and each contact in the list and returns
%% the final result.
normalize_verify_and_subscribe_contacts(_UserId, _Server, [], _SyncId, Results) ->
    Results;
normalize_verify_and_subscribe_contacts(UserId, Server, [First | Rest], SyncId, Results) ->
    Result = normalize_verify_and_subscribe_contact(UserId, Server, First, SyncId),
    normalize_verify_and_subscribe_contacts(UserId, Server, Rest, SyncId, [Result | Results]).



%% Given a user and a contact, we normalize the contact, insert this contact of the user into
%% our database, check if the user and contact are connected on halloapp (mutual connection)
%% subscribe the pubsub nodes for the contacts and then return the appropriate result.
normalize_verify_and_subscribe_contact(UserId, Server, Contact, SyncId) ->
    Raw = Contact#contact.raw,
    Normalized = normalize(Raw),
    case Normalized of
        undefined ->
            #contact{raw = Raw};
        _ ->
            ShouldNotifyContact = insert_contact(UserId, Server, Normalized, SyncId),
            ContactId = obtain_user_id(Normalized),
            case ContactId of
                undefined ->
                    #contact{raw = Raw, normalized = Normalized, role = "none"};
                _ ->
                    case ShouldNotifyContact of
                        {ok, true} ->
                            notify_contact_about_user(UserId, Server, ContactId);
                        _ ->
                            ok
                    end,
                    IsFriends = check_if_friends(UserId, Server, Normalized),
                    Role = get_role_value(IsFriends),
                    subscribe_to_each_others_nodes(UserId, Server, ContactId, Role),
                    #contact{raw = Raw,
                             userid = ContactId,
                             normalized = Normalized,
                             role = Role}
            end
    end.



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
-spec insert_contact(binary(), binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
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
            {ok, Notify};
        {error, _} = Result ->
            Result
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



%% Checks if each contact in the list is connected to the user on halloapp or not.
%% Please ensure the contact number is already inserted as a contact of the user,
%% else the test will fail.
-spec check_if_friends(binary(), binary(), binary()) -> atom().
check_if_friends(UserId, Server, ContactNumber) ->
    UserNumber = get_phone(UserId),
    ContactId = obtain_user_id(ContactNumber),
    check_if_friends_internal(UserId, Server, ContactId, UserNumber, ContactNumber).


-spec is_friend_internal(binary(), binary(), binary()) -> boolean().
is_friend_internal(UserId, Server, ContactId) ->
    UserNumber = get_phone(UserId),
    ContactNumber = get_phone(ContactId),
    check_if_friends_internal(UserId, Server, ContactId, UserNumber, ContactNumber).



%% Checks if the both the user and the contact are connected on halloapp or not.
%% Returns "friends" if they are connected, else returns "none".
-spec check_if_friends_internal(binary(), binary(), binary(), binary(), binary()) -> boolean().
check_if_friends_internal(UserId, Server, ContactId, UserNumber, ContactNumber) ->
    ActualUser = {UserNumber, Server},
    Username = {UserId, Server},
    ActualContact = {ContactNumber, Server},
    Contactname = {ContactId, Server},
    mod_contacts_mnesia:check_if_contact_exists(Contactname, ActualUser) andalso
        mod_contacts_mnesia:check_if_contact_exists(Username, ActualContact).


-spec get_role_value(atom()) -> list().
get_role_value(true) ->
    "friends";
get_role_value(false) ->
    "none".


%% Obtains the user for a user: uses the id if it already exists, else creates one.
-spec obtain_user_id(binary()) -> binary() | undefined.
obtain_user_id(Phone) ->
    ejabberd_auth_mnesia:get_uid(Phone).


-spec get_phone(UserId :: binary()) -> binary().
get_phone(UserId) ->
    ejabberd_auth_mnesia:get_phone(UserId).


%% Deletes all contacts of the user and all the associated information in pubsub nodes as well.
delete_all_contacts(UserId, Server) ->
    case mod_contacts_mnesia:fetch_contacts({UserId, Server}) of
        {ok, UserContacts} ->
            lists:foreach(fun(#user_contacts_new{contact = {ContactNumber, _}}) ->
                            delete_contact(UserId, Server, ContactNumber)
                          end, UserContacts);
        {error, _} ->
            ok
    end,
    ok.


%% Delete only the old contacts that were probably deleted by the client.
%% This is invoked only on every full-sync-of-contacts.
delete_old_contacts(UserId, Server, CurSyncId) ->
    case mod_contacts_mnesia:fetch_contacts({UserId, Server}) of
        {ok, UserContacts} ->
            lists:foreach(fun(#user_contacts_new{contact = {ContactNumber, _},
                                            syncid = ThenSyncId}) ->
                            case CurSyncId =/= ThenSyncId of
                                true ->
                                    delete_contact(UserId, Server, ContactNumber);
                                false ->
                                    ok
                            end
                          end, UserContacts);
        {error, _} ->
            ok
    end,
    ok.



%% Delete all associated info with the contact and the user.
-spec delete_contact(binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
delete_contact(UserId, Server, ContactNumber) ->
    ContactId = obtain_user_id(ContactNumber),
    case ContactId of
        undefined ->
            ok;
        _ ->
            unsubscribe_to_each_others_nodes(UserId, Server, ContactId),
            notify_contact_about_user(UserId, Server, ContactId)
    end,
    mod_contacts_mnesia:delete_contact({UserId, Server}, {ContactNumber, Server}).


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



%% Notifies contact number about the user using the UserId and the role element to indicate
%% if they are now friends or not on halloapp.
-spec notify_contact_about_user(binary(), binary(), binary()) -> ok.
notify_contact_about_user(UserId, _Server, UserId) ->
    ok;
notify_contact_about_user(UserId, Server, ContactId) ->
    UserNumber = get_phone(UserId),
    ContactNumber = get_phone(ContactId),
    check_and_send_message_to_contact(UserNumber, Server, ContactNumber, UserId, ContactId).



%% Checks the UserId, ContactUserId if available and sends a message to the contact.
-spec check_and_send_message_to_contact(binary(), binary(), binary(), binary(), binary()) -> ok.
check_and_send_message_to_contact(UserNumber, Server, _ContactNumber, UserId, ContactId) ->
    IsFriends = is_friend_internal(UserId, Server, ContactId),
    Role = get_role_value(IsFriends),
    Contact = #contact{userid = UserId, normalized = UserNumber, role = Role},
    SubEls = [#contact_list{type = normal, xmlns = ?NS_NORM, contacts = [Contact]}],
    Stanza = #message{from = jid:make(Server),
                      to = jid:make(ContactId, Server),
                      sub_els = SubEls},
    ?DEBUG("Notifying contact: ~p about user: ~p using stanza: ~p",
                                                [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).


