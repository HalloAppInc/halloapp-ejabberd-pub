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
%%% from user's pubsub nodes list of affiliations, we unsubscribe the user to contact's feed node
%%% and vice-versa. We delete the contact in the user_contacts mnesia table for the user.
%%% Currently, phone number normalization has been tested with the US phone numbers.
%%% Type = get
%%% yet to be done!
%%% Type = update
%%% yet to be done!
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
%% IQ handlers.
-export([process_local_iq/1]).

%% exports for console debug manual use
-export([normalize_verify_and_subscribe/3, normalize_and_verify_contacts/4,
        normalize_and_verify_contact/3, normalize/1, parse/1, insert_contact/3,
        subscribe_to_each_others_feed/4, subscribe_to_feed/3, certify/3, validate/3,
        obtain_user_id/2, delete_all_contacts/2, delete_contact/3,
        unsubscribe_to_each_others_feed/3, unsubscribe_to_feed/3, remove_affiliation/3,
        notify_contact_about_user/3, check_and_send_message_to_contact/5]).

start(Host, Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_NORM, ?MODULE, process_local_iq),
    phone_number_util:init(Host, Opts),
    mod_contacts_mnesia:init(Host, Opts),
    ok.

stop(Host) ->
    mod_contacts_mnesia:close(),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_NORM),
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
%% TODO(murali@): Complete this to handle stanzas with type = get.
process_local_iq(#iq{from = #jid{luser = _User, lserver = _Server}, type = get,
                    sub_els = [#contact_list{ type = get, contacts = _Contacts}]} = IQ) ->
    xmpp:make_iq_result(IQ);

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = set,
                    sub_els = [#contact_list{ type = set, contacts = Contacts}]} = IQ) ->
    delete_all_contacts(User, Server),
    case Contacts of
        [] -> xmpp:make_iq_result(IQ);
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal,
                    contacts = normalize_verify_and_subscribe(User, Server, Contacts)})
    end;

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = set,
                    sub_els = [#contact_list{ type = add, contacts = Contacts}]} = IQ) ->
    case Contacts of
        [] -> xmpp:make_iq_result(IQ);
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal,
                    contacts = normalize_verify_and_subscribe(User, Server, Contacts)})
    end;

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = set,
                    sub_els = [#contact_list{ type = delete, contacts = Contacts}]} = IQ) ->
    case Contacts of
        [] -> xmpp:make_iq_result(IQ);
        _ELse -> xmpp:make_iq_result(IQ, #contact_list{xmlns = ?NS_NORM, type = normal,
                    contacts = delete_contacts_iq(User, Server, Contacts)})
    end;
%% TODO(murali@): Complete this to handle stanzas with type = update.
process_local_iq(#iq{from = #jid{luser = _User, lserver = _Server}, type = set,
                    sub_els = [#contact_list{ type = update, contacts = _Contacts}]} = IQ) ->
    xmpp:make_iq_result(IQ).



%%====================================================================
%% internal functions
%%====================================================================


%% Deletes the contacts obtained in an iq stanza from the user.
delete_contacts_iq(_User, _Server, []) ->
    [];
delete_contacts_iq(User, Server, [First | Rest]) ->
    {_, _, Normalized, _} = First,
    delete_contact(User, Server, Normalized),
    delete_contacts_iq(User, Server, Rest).



%% Normalize, Verify and Subscribe the pubsub nodes for the contacts received in an iq.
normalize_verify_and_subscribe(_User, _Server, []) ->
    [];
normalize_verify_and_subscribe(User, Server, Contacts) ->
    ContactResults = normalize_and_verify_contacts(User, Server, Contacts, []),
    lists:foreach(fun({_Raw, _UserId, Normalized, Role}) ->
                    subscribe_to_each_others_feed(User, Server, Normalized, Role),
                    ok
                  end, ContactResults),
    ContactResults.



%% Normalizes, verifies the connection between the user and each contact in the list and returns
%% the final result.
normalize_and_verify_contacts(User, Server, [], Affs) ->
    Host = mod_pubsub:host(Server),
    Node = util:get_feed_pubsub_node_name(User),
    From = jid:make(User, Server),
    Result = mod_pubsub:set_affiliations(Host, Node, From, Affs),
    ?DEBUG("User: ~p tried to set affs : ~p to pubsub node: ~p, result: ~p",
                                                        [From, Affs, Node, Result]),
    [];
normalize_and_verify_contacts(User, Server, [First | Rest], Affs) ->
    Result = normalize_and_verify_contact(User, Server, First),
    {_, _, Normalized, _} = Result,
    Aff = #ps_affiliation{jid = jid:make(Normalized, Server), type = member},
    [Result | normalize_and_verify_contacts(User, Server, Rest, [Aff | Affs])].



%% Given a user and a contact, we normalize the contact, insert this contact of the user into
%% our database, check if the user and contact are connected on halloapp (mutual connection)
%% and return the appropriate result.
normalize_and_verify_contact(User, Server, {Raw, _, _, _}) ->
    Normalized = normalize(Raw),
    UserId = obtain_user_id(Normalized, Server),
    insert_contact(User, Server, Normalized),
    Role = certify(User, Server, Normalized),
    notify_contact_about_user(User, Server, Normalized),
    {Raw, UserId, Normalized, Role}.



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



%% Insert these contacts as user's contacts in an mnesia table.
-spec insert_contact(binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
insert_contact(_User, _Server, undefined) ->
    ?ERROR_MSG("Expected a number as input: ~p", [undefined]),
    {error, invalid_contact_list};
insert_contact(User, Server, ContactNumber) ->
    Username = {User, Server},
    Contact = {ContactNumber, Server},
    case mod_contacts_mnesia:insert_contact(Username, Contact) of
        {ok, _} = Result->
            ?DEBUG("Inserted contact: ~p for user: ~p", [ContactNumber, {User, Server}]),
            Result;
        {error, _} = Result ->
            ?ERROR_MSG("Failed to insert contact: ~p for user: ~p",
                                                        [ContactNumber, {User, Server}]),
            Result
    end.



%% Subscribes the User to the feed of the ContactNumber and vice-versa if they are 'friends'.
-spec subscribe_to_each_others_feed(binary(), binary(), binary(), list()) -> ok.
subscribe_to_each_others_feed(_User, _Server, _ContactNumber, "none") ->
    ok;
subscribe_to_each_others_feed(User, Server, ContactNumber, "friends") ->
    subscribe_to_feed(User, Server, ContactNumber),
    subscribe_to_feed(ContactNumber, Server, User),
    ok;
subscribe_to_each_others_feed(User, Server, ContactNumber, Role) ->
    ?ERROR_MSG("Invalid role:~p for a contact: ~p for user: ~p",
                                                    [Role, ContactNumber, {User, Server}]),
    ok.



%% subscribes the User to the feed of the ContactNumber.
-spec subscribe_to_feed(binary(), binary(), binary()) -> ok.
subscribe_to_feed(User, Server, ContactNumber) ->
    Host = mod_pubsub:host(Server),
    Node = util:get_feed_pubsub_node_name(ContactNumber),
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
            lists:foreach(fun(#user_contacts{contact = {ContactNumber, _}}) ->
                            delete_contact(User, Server, ContactNumber)
                          end, UserContacts);
        {error, _} ->
            ok
    end,
    ok.



%% Delete all associated info with the contact and the user.
-spec delete_contact(binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
delete_contact(User, Server, ContactNumber) ->
    unsubscribe_to_each_others_feed(User, Server, ContactNumber),
    remove_affiliation(User, Server, ContactNumber),
    mod_contacts_mnesia:delete_contact({User, Server}, {ContactNumber, Server}),
    notify_contact_about_user(User, Server, ContactNumber).



%% Unsubscribes the User to the feed of the ContactNumber and vice-versa.
-spec unsubscribe_to_each_others_feed(binary(), binary(), binary()) -> ok.
unsubscribe_to_each_others_feed(User, Server, ContactNumber) ->
    unsubscribe_to_feed(User, Server, ContactNumber),
    unsubscribe_to_feed(ContactNumber, Server, User),
    ok.



%% Unsubscribes the User to the feed of the ContactNumber.
-spec unsubscribe_to_feed(binary(), binary(), binary()) -> ok.
unsubscribe_to_feed(User, Server, ContactNumber) ->
    Host = mod_pubsub:host(Server),
    Node = util:get_feed_pubsub_node_name(ContactNumber),
    From = jid:make(User, Server),
    JID = jid:make(User, Server),
    SubId = all,
    Result = mod_pubsub:unsubscribe_node(Host, Node, From, JID, SubId),
    ?DEBUG("User: ~p tried to unsubscribe to pubsub node: ~p, result: ~p", [From, Node, Result]),
    ok.


%% Remove affiliation for the ContactNumber on the user's feed node.
-spec remove_affiliation(binary(), binary(), binary()) -> ok.
remove_affiliation(User, Server, ContactNumber) ->
    Affs = [#ps_affiliation{jid = jid:make(ContactNumber, Server), type = none}],
    Host = mod_pubsub:host(Server),
    Node = util:get_feed_pubsub_node_name(User),
    From = jid:make(User, Server),
    Result = mod_pubsub:set_affiliations(Host, Node, From, Affs),
    ?DEBUG("User: ~p tried to set affs : ~p to pubsub node: ~p, result: ~p",
                                                        [From, Affs, Node, Result]),
    ok.



%% Notifies contact number about the user using the UserId and the role element to indicate
%% if they are now friends or not on halloapp.
-spec notify_contact_about_user(binary(), binary(), binary()) -> ok.
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
    Contact = {undefined, UserId, User, Role},
    SubEls = [#contact_list{ type = normal, xmlns = ?NS_NORM, contacts = [Contact]}],
    Stanza = #message{from = jid:make(mod_pubsub:host(Server)),
                      to = jid:make(ContactNumber, Server),
                      sub_els = SubEls},
    ?DEBUG("Notifying contact: ~p about user: ~p using stanza: ~p",
                                                [{ContactNumber, Server}, User, Stanza]),
    ejabberd_router:route(Stanza).


