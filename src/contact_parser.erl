-module(contact_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(SubEl) ->
    Contacts = SubEl#contact_list.contacts,
    ProtoContacts = lists:map(
        fun(Contact) -> 
            #pb_contact{
                action = Contact#contact.type,
                raw = Contact#contact.raw,
                normalized = Contact#contact.normalized,
                uid = binary_to_integer(Contact#contact.userid),
                avatarid = Contact#contact.avatarid,
                role = xmpp_to_proto_role(Contact#contact.role)
            }
        end, 
        Contacts),
    #pb_contact_list{
        type = SubEl#contact_list.type,
        syncid = SubEl#contact_list.syncid,
        index = SubEl#contact_list.index,
        is_last = SubEl#contact_list.last,
        contacts = ProtoContacts
    }.


xmpp_to_proto_role(XmppRole) ->
    PbRole = case XmppRole of
        <<>> -> undefined;
        _ -> util:to_atom(XmppRole)
    end,
    PbRole.


proto_to_xmpp(ProtoPayload) ->
    ContactList = ProtoPayload#pb_contact_list.contacts,
    XmppContacts = lists:map(
        fun(Contact) -> 
            #contact{
                type = Contact#pb_contact.action,
                raw = Contact#pb_contact.raw,
                normalized = Contact#pb_contact.normalized,
                userid = integer_to_binary(Contact#pb_contact.uid),
                avatarid = Contact#pb_contact.avatarid,
                role = proto_to_xmpp_role(Contact#pb_contact.role)
            }
        end, 
        ContactList),
    #contact_list{
        type = ProtoPayload#pb_contact_list.type,
        syncid = ProtoPayload#pb_contact_list.syncid,
        index = ProtoPayload#pb_contact_list.index, 
        last = ProtoPayload#pb_contact_list.is_last,
        contacts = XmppContacts
    }.


proto_to_xmpp_role(PbRole) ->
    XmppRole = case PbRole of 
        undefined -> <<>>;
        _ -> util:to_binary(PbRole)
    end,
    XmppRole.
    
    