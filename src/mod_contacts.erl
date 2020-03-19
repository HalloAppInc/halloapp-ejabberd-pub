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

%% exports for console debug manual use
-export([normalize_verify_and_subscribe/4, normalize_and_verify_contacts/5,
        normalize_and_verify_contact/4, normalize/1, parse/1, insert_syncid/3, insert_contact/4,
        handle_delta_contacts/4, subscribe_to_each_others_nodes/4, subscribe_to_each_others_node/4,
        subscribe_to_node/3, certify/3, validate/3, fetch_syncid/2,
        fetch_contacts/2, fetch_contacts/3, fetch_contact_info/3, obtain_contact_record/3,
        obtain_user_id/2, delete_all_contacts/2, delete_contact/3,
        unsubscribe_to_each_others_nodes/3, unsubscribe_to_each_others_node/4,
        unsubscribe_to_node/3, remove_affiliation_for_all_user_nodes/3, remove_affiliation/4,
        notify_contact_about_user/3, check_and_send_message_to_contact/5,
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

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = set,
                    sub_els = [#contact_list{type = full, contacts = Contacts,
                                            syncid = SyncId, index = Index, last = Last}]} = IQ) ->
    case Index of
        0 -> insert_syncid(User, Server, SyncId);
        _ -> ok
    end,
    ResultIQ = case Contacts of
        [] -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal});
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM,
                    syncid = SyncId, type = normal,
                    contacts = normalize_verify_and_subscribe(User, Server, Contacts, SyncId)})
    end,
    case Last of
        false -> ok;
        true -> delete_old_contacts(User, Server, SyncId)
    end,
    ResultIQ;

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = set,
                    sub_els = [#contact_list{type = delta, contacts = Contacts,
                                            index = _Index, last = Last}]} = IQ) ->
    UserSyncId = fetch_syncid(User, Server),
    ResultIQ = case Contacts of
        [] -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal});
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM,
                    syncid = UserSyncId, type = normal,
                    contacts = handle_delta_contacts(User, Server, Contacts, UserSyncId)})
    end,
    case Last of
        false -> ok;
        true -> delete_old_contacts(User, Server, UserSyncId)
    end,
    ResultIQ;

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = get,
                    sub_els = [#contact_list{ type = get, contacts = Contacts}]} = IQ) ->
    case Contacts of
        [] -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal,
                                contacts = fetch_contacts(User, Server)});
        _Else -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal,
                                contacts = fetch_contacts(User, Server, Contacts)})
    end;

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = set,
                    sub_els = [#contact_list{type = set, contacts = Contacts,
                                            syncid = SyncId, last = Last}]} = IQ) ->
    insert_syncid(User, Server, SyncId),
    ResultIQ = case Contacts of
        [] -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal});
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM,
                    syncid = SyncId, type = normal,
                    contacts = normalize_verify_and_subscribe(User, Server, Contacts, SyncId)})
    end,
    case Last of
        false -> ok;
        true -> delete_old_contacts(User, Server, SyncId)
    end,
    ResultIQ;

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = set,
                    sub_els = [#contact_list{type = add, contacts = Contacts,
                                            syncid = _SyncId, last = Last}]} = IQ) ->
    UserSyncId = fetch_syncid(User, Server),
    ResultIQ = case Contacts of
        [] -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal});
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM,
                    syncid = UserSyncId, type = normal,
                    contacts = normalize_verify_and_subscribe(User, Server, Contacts, UserSyncId)})
    end,
    case Last of
        false -> ok;
        true -> delete_old_contacts(User, Server, UserSyncId)
    end,
    ResultIQ;

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = set,
                    sub_els = [#contact_list{ type = delete, contacts = Contacts}]} = IQ) ->
    case Contacts of
        [] -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal});
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal,
                    contacts = delete_contacts_iq(User, Server, Contacts)})
    end.


%% remove_user hook deletes all contacts of the user
%% which involves removing all the subscriptions and affiliations and notifying the contacts.
remove_user(User, Server) ->
    delete_all_contacts(User, Server).


%%====================================================================
%% internal functions
%%====================================================================

-spec handle_delta_contacts(binary(), binary(), [#contact{}], binary()) -> [#contact{}].
handle_delta_contacts(User, Server, Contacts, UserSyncId) ->
    {DeleteContactsList, AddContactsList} = lists:partition(fun(#contact{type = Type}) ->
                                                                Type == delete
                                                            end, Contacts),
    delete_contacts_iq(User, Server, DeleteContactsList),
    normalize_verify_and_subscribe(User, Server, AddContactsList, UserSyncId).



-spec fetch_contacts(binary(), binary()) -> [{binary(), binary(), binary(), binary()}].
fetch_contacts(User, Server) ->
    case mod_contacts_mnesia:fetch_contacts({User, Server}) of
        {ok, UserContacts} -> fetch_contact_info(User, Server, UserContacts);
        {error, _} -> []
    end.



-spec fetch_contacts(binary(), binary(), [{binary(), binary(), binary(), binary()}]) ->
                                                [{binary(), binary(), binary(), binary()}].
fetch_contacts(_User, _Server, []) ->
    [];
fetch_contacts(User, Server, [First | Rest]) ->
    {_, _, Normalized, _} = First,
    [obtain_contact_record(User, Server, Normalized) | fetch_contacts(User, Server, Rest)].



-spec fetch_contact_info(binary(), binary(), [#user_contacts_new{}]) ->
                                                    [{binary(), binary(), binary(), binary()}].
fetch_contact_info(_User, _Server, []) ->
    [];
fetch_contact_info(User, Server, [First | Rest]) ->
    {Normalized, _} = First#user_contacts_new.contact,
    [obtain_contact_record(User, Server, Normalized) | fetch_contact_info(User, Server, Rest)].



-spec obtain_contact_record(binary(), binary(), binary()) ->
                                                    {binary(), binary(), binary(), binary()}.
obtain_contact_record(User, Server, Normalized) ->
    UserId = obtain_user_id(Normalized, Server),
    Role = certify(User, Server, Normalized),
    #contact{userid = UserId,
            normalized = Normalized,
            role = Role}.



%% Deletes the contacts obtained in an iq stanza from the user.
delete_contacts_iq(_User, _Server, []) ->
    [];
delete_contacts_iq(User, Server, [First | Rest]) ->
    Normalized = First#contact.normalized,
    delete_contact(User, Server, Normalized),
    delete_contacts_iq(User, Server, Rest).



%% Normalize, Verify and Subscribe the pubsub nodes for the contacts received in an iq.
normalize_verify_and_subscribe(_User, _Server, [], _SyncId) ->
    [];
normalize_verify_and_subscribe(User, Server, Contacts, SyncId) ->
    ContactResults = normalize_and_verify_contacts(User, Server, Contacts, [], SyncId),
    lists:map(fun({Raw, UserId, Normalized, Role, Notify}) ->
                    case Notify of
                        true ->
                            subscribe_to_each_others_nodes(User, Server, Normalized, Role);
                        false ->
                            ok
                    end,
                    #contact{raw = Raw,
                             userid = UserId,
                             normalized = Normalized,
                             role = Role}
                end, ContactResults).



%% Normalizes, verifies the connection between the user and each contact in the list and returns
%% the final result.
normalize_and_verify_contacts(User, Server, [], Affs, _SyncId) ->
    Host = mod_pubsub:host(Server),
    FeedNode = util:get_feed_pubsub_node_name(User),
    MetadataNode = util:get_metadata_pubsub_node_name(User),
    From = jid:make(User, Server),
    Result1 = mod_pubsub:set_affiliations(Host, FeedNode, From, Affs),
    Result2 = mod_pubsub:set_affiliations(Host, MetadataNode, From, Affs),
    ?DEBUG("User: ~p tried to set affs : ~p to pubsub node: ~p, result: ~p",
                                                        [From, Affs, FeedNode, Result1]),
    ?DEBUG("User: ~p tried to set affs : ~p to pubsub node: ~p, result: ~p",
                                                        [From, Affs, MetadataNode, Result2]),
    [];
normalize_and_verify_contacts(User, Server, [First | Rest], Affs, SyncId) ->
    Result = normalize_and_verify_contact(User, Server, First, SyncId),
    NewAffs = case Result of
                {_, _, _, _, false} ->
                    Affs;
                {_, _, undefined, _, true} ->
                    Affs;
                {_, _, Normalized, _, true} ->
                    Aff = #ps_affiliation{jid = jid:make(Normalized, Server), type = member},
                    [Aff | Affs]
              end,
    [Result | normalize_and_verify_contacts(User, Server, Rest, NewAffs, SyncId)].



%% Given a user and a contact, we normalize the contact, insert this contact of the user into
%% our database, check if the user and contact are connected on halloapp (mutual connection)
%% and return the appropriate result.
normalize_and_verify_contact(User, Server, Contact, SyncId) ->
    Raw = Contact#contact.raw,
    Normalized = normalize(Raw),
    UserId = obtain_user_id(Normalized, Server),
    Notify = case insert_contact(User, Server, Normalized, SyncId) of
                {ok, true} ->
                    notify_contact_about_user(User, Server, Normalized),
                    true;
                _ ->
                    false
            end,
    Role = certify(User, Server, Normalized),
    {Raw, UserId, Normalized, Role, Notify}.



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
insert_syncid(User, Server, SyncId) ->
    Username = {User, Server},
    case mod_contacts_mnesia:insert_syncid(Username, SyncId) of
        {ok, _} ->
            ?DEBUG("Successfully inserted syncid: ~p for username: ~p", [SyncId, Username]);
        {error, _} ->
            ?ERROR_MSG("Failed to insert syncid: ~p for username: ~p", [SyncId, Username])
    end.



%% Insert these contacts as user's contacts in an mnesia table.
-spec insert_contact(binary(), binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
insert_contact(_User, _Server, undefined, _SyncId) ->
    ?ERROR_MSG("Expected a number as input: ~p", [undefined]),
    {error, invalid_contact_list};
insert_contact(User, Server, ContactNumber, SyncId) ->
    Username = {User, Server},
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
fetch_syncid(User, Server) ->
    Username = {User, Server},
    case mod_contacts_mnesia:fetch_syncid(Username) of
        {ok, [UserSyncIds | _]} ->
            UserSyncIds#user_syncids.syncid;
        {error, _} = _Result ->
            <<"">>
    end.



%% Subscribes the User to the nodes of the ContactNumber and vice-versa if they are 'friends'.
-spec subscribe_to_each_others_nodes(binary(), binary(), binary(), list()) -> ok.
subscribe_to_each_others_nodes(_User, _Server, _ContactNumber, "none") ->
    ok;
subscribe_to_each_others_nodes(User, Server, ContactNumber, "friends") ->
    subscribe_to_each_others_node(User, Server, ContactNumber, feed),
    subscribe_to_each_others_node(User, Server, ContactNumber, metadata),
    ok;
subscribe_to_each_others_nodes(User, Server, ContactNumber, Role) ->
    ?ERROR_MSG("Invalid role:~p for a contact: ~p for user: ~p",
                                                    [Role, ContactNumber, {User, Server}]),
    ok.



%% Subscribes the User to the node of the ContactNumber and vice-versa.
-spec subscribe_to_each_others_node(binary(), binary(), binary(), atom()) -> ok.
subscribe_to_each_others_node(User, Server, ContactNumber, feed) ->
    UserFeedNodeName = util:get_feed_pubsub_node_name(User),
    ContactFeedNodeName =  util:get_feed_pubsub_node_name(ContactNumber),
    subscribe_to_node(User, Server, ContactFeedNodeName),
    subscribe_to_node(ContactNumber, Server, UserFeedNodeName),
    ok;
subscribe_to_each_others_node(User, Server, ContactNumber, metadata) ->
    UserMetadataNodeName = util:get_metadata_pubsub_node_name(User),
    ContactMetadataNodeName =  util:get_metadata_pubsub_node_name(ContactNumber),
    subscribe_to_node(User, Server, ContactMetadataNodeName),
    subscribe_to_node(ContactNumber, Server, UserMetadataNodeName),
    ok.



%% subscribes the User to the node.
-spec subscribe_to_node(binary(), binary(), binary()) -> ok.
subscribe_to_node(User, Server, NodeName) ->
    Host = mod_pubsub:host(Server),
    Node = NodeName,
    From = jid:make(User, Server),
    JID = jid:make(User, Server),
    Config = [],
    Result = mod_pubsub:subscribe_node(Host, Node, From, JID, Config),
    ?DEBUG("User: ~p tried to subscribe to pubsub node: ~p, result: ~p", [From, Node, Result]),
    ok.



%% Certifies if each contact in the list is connected to the user on halloapp or not.
%% Please ensure the contact number is already inserted as a contact of the user,
%% else the test will fail.
-spec certify(binary(), binary(), binary()) -> undefined | list().
certify(_User, _Server, undefined) ->
    ?ERROR_MSG("Expected a number as input: ~p", [undefined]),
    undefined;
certify(User, Server, ContactNumber) ->
    validate(User, Server, ContactNumber).



%% Validates if the both the user and the contact are connected on halloapp or not.
%% Returns "friends" if they are connected, else returns "none".
-spec validate(binary(), binary(), binary()) -> list().
validate(User, Server, ContactNumber) ->
    Username = {User, Server},
    Contact = {ContactNumber, Server},
    case mod_contacts_mnesia:check_if_contact_exists(Contact, Username) == true andalso
        mod_contacts_mnesia:check_if_contact_exists(Username, Contact) == true of
        true -> "friends";
        false -> "none"
    end.



%% Obtains the user for a user: uses the id if it already exists, else creates one.
-spec obtain_user_id(binary(), binary()) -> binary() | undefined.
obtain_user_id(undefined, _) ->
    undefined;
obtain_user_id(User, Server) ->
    case ejabberd_auth_mnesia:get_user_id(User, Server) of
        {ok, Id} ->
            Id;
        {error, _} ->
            undefined
    end.


%% Deletes all contacts of the user and all the associated information in pubsub nodes as well.
delete_all_contacts(User, Server) ->
    case mod_contacts_mnesia:fetch_contacts({User, Server}) of
        {ok, UserContacts} ->
            lists:foreach(fun(#user_contacts_new{contact = {ContactNumber, _}}) ->
                            delete_contact(User, Server, ContactNumber)
                          end, UserContacts);
        {error, _} ->
            ok
    end,
    ok.


%% Delete only the old contacts that were probably deleted by the client.
%% This is invoked only on every full-sync-of-contacts.
%% TODO(murali@): Handle contacts being sent in batches.
delete_old_contacts(User, Server, CurSyncId) ->
    case mod_contacts_mnesia:fetch_contacts({User, Server}) of
        {ok, UserContacts} ->
            lists:foreach(fun(#user_contacts_new{contact = {ContactNumber, _},
                                            syncid = ThenSyncId}) ->
                            case CurSyncId =/= ThenSyncId of
                                true ->
                                    delete_contact(User, Server, ContactNumber);
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
delete_contact(User, Server, ContactNumber) ->
    unsubscribe_to_each_others_nodes(User, Server, ContactNumber),
    remove_affiliation_for_all_user_nodes(User, Server, ContactNumber),
    mod_contacts_mnesia:delete_contact({User, Server}, {ContactNumber, Server}),
    notify_contact_about_user(User, Server, ContactNumber).


%% Unsubscribes the User to the nodes of the ContactNumber and vice-versa.
-spec unsubscribe_to_each_others_nodes(binary(), binary(), binary()) -> ok.
unsubscribe_to_each_others_nodes(User, Server, ContactNumber) ->
    unsubscribe_to_each_others_node(User, Server, ContactNumber, feed),
    unsubscribe_to_each_others_node(User, Server, ContactNumber, metadata),
    ok.



%% Unsubscribes the User to the node of the ContactNumber and vice-versa.
-spec unsubscribe_to_each_others_node(binary(), binary(), binary(), atom()) -> ok.
unsubscribe_to_each_others_node(User, Server, ContactNumber, feed) ->
    UserFeedNodeName = util:get_feed_pubsub_node_name(User),
    ContactFeedNodeName =  util:get_feed_pubsub_node_name(ContactNumber),
    unsubscribe_to_node(User, Server, ContactFeedNodeName),
    unsubscribe_to_node(ContactNumber, Server, UserFeedNodeName),
    ok;
unsubscribe_to_each_others_node(User, Server, ContactNumber, metadata) ->
    UserMetadataNodeName = util:get_metadata_pubsub_node_name(User),
    ContactMetadataNodeName =  util:get_metadata_pubsub_node_name(ContactNumber),
    unsubscribe_to_node(User, Server, ContactMetadataNodeName),
    unsubscribe_to_node(ContactNumber, Server, UserMetadataNodeName),
    ok.



%% Unsubscribes the User to the node.
-spec unsubscribe_to_node(binary(), binary(), binary()) -> ok.
unsubscribe_to_node(User, Server, NodeName) ->
    Host = mod_pubsub:host(Server),
    Node = NodeName,
    From = jid:make(User, Server),
    JID = jid:make(User, Server),
    SubId = all,
    Result = mod_pubsub:unsubscribe_node(Host, Node, From, JID, SubId),
    ?DEBUG("User: ~p tried to unsubscribe to pubsub node: ~p, result: ~p", [From, Node, Result]),
    ok.


%% Remove affiliation for the ContactNumber on all user's nodes.
-spec remove_affiliation_for_all_user_nodes(binary(), binary(), binary()) -> ok.
remove_affiliation_for_all_user_nodes(User, Server, ContactNumber) ->
    FeedNodeName = util:get_feed_pubsub_node_name(User),
    MetadataNodeName = util:get_metadata_pubsub_node_name(User),
    remove_affiliation(User, Server, ContactNumber, FeedNodeName),
    remove_affiliation(User, Server, ContactNumber, MetadataNodeName).



%% Remove affiliation for the ContactNumber on the user's node with the nodename.
-spec remove_affiliation(binary(), binary(), binary(), binary()) -> ok.
remove_affiliation(User, Server, ContactNumber, NodeName) ->
    Affs = [#ps_affiliation{jid = jid:make(ContactNumber, Server), type = none}],
    Host = mod_pubsub:host(Server),
    Node = NodeName,
    From = jid:make(User, Server),
    Result = mod_pubsub:set_affiliations(Host, Node, From, Affs),
    ?DEBUG("User: ~p tried to set affs : ~p to pubsub node: ~p, result: ~p",
                                                        [From, Affs, Node, Result]),
    ok.



%% Notifies contact number about the user using the UserId and the role element to indicate
%% if they are now friends or not on halloapp.
-spec notify_contact_about_user(binary(), binary(), binary()) -> ok.
notify_contact_about_user(User, _Server, User) ->
    ok;
notify_contact_about_user(User, Server, ContactNumber) ->
    UserId = obtain_user_id(User, Server),
    ContactUserId = obtain_user_id(ContactNumber, Server),
    check_and_send_message_to_contact(User, Server, ContactNumber, UserId, ContactUserId).



%% Checks the UserId, ContactUserId if available and sends a message to the contact.
-spec check_and_send_message_to_contact(binary(), binary(), binary(), binary(), binary()) -> ok.
check_and_send_message_to_contact(User, Server, ContactNumber, undefined, _) ->
    ?DEBUG("Ignore notifying contact: ~p about user: ~p", [{ContactNumber, Server}, User]),
    ok;
check_and_send_message_to_contact(User, Server, ContactNumber, _, undefined) ->
    ?DEBUG("Ignore notifying contact: ~p about user: ~p", [{ContactNumber, Server}, User]),
    ok;
check_and_send_message_to_contact(User, Server, ContactNumber, UserId, _ContactUserId) ->
    Role = certify(ContactNumber, Server, User),
    Contact = #contact{userid = UserId, normalized = User, role = Role},
    SubEls = [#contact_list{ type = normal, xmlns = ?NS_NORM, contacts = [Contact]}],
    Stanza = #message{from = jid:make(mod_pubsub:host(Server)),
                      to = jid:make(ContactNumber, Server),
                      sub_els = SubEls},
    ?DEBUG("Notifying contact: ~p about user: ~p using stanza: ~p",
                                                [{ContactNumber, Server}, User, Stanza]),
    ejabberd_router:route(Stanza).


