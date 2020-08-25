-module(contact_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).

%% -------------------------------------------- %%
%% XMPP to Protobuf
%% -------------------------------------------- %%

xmpp_to_proto(SubEl) ->
    ProtoContent = case SubEl#contact_list.contact_hash of
        [] -> xmpp_to_proto_contact_list(SubEl);
        [_] -> xmpp_to_proto_contact_hash(SubEl)
    end,
    ProtoContent.


xmpp_to_proto_contact_list(SubEl) ->
    Contacts = SubEl#contact_list.contacts,
    ProtoContacts = lists:map(
        fun(Contact) ->
            Uid = util_parser:xmpp_to_proto_uid(Contact#contact.userid),
            #pb_contact{
                action = Contact#contact.type,
                raw = Contact#contact.raw,
                normalized = Contact#contact.normalized,
                uid = Uid,
                avatar_id = Contact#contact.avatarid,
                name = Contact#contact.name,
                role = xmpp_to_proto_role(Contact#contact.role)
            }
        end,
        Contacts),
    #pb_contact_list{
        type = SubEl#contact_list.type,
        sync_id = SubEl#contact_list.syncid,
        batch_index = SubEl#contact_list.index,
        is_last = SubEl#contact_list.last,
        contacts = ProtoContacts
    }.


xmpp_to_proto_role(XmppRole) ->
    PbRole = case XmppRole of
        <<>> -> undefined;
        _ -> util:to_atom(XmppRole)
    end,
    PbRole.


xmpp_to_proto_contact_hash(SubEl) ->
    [HashValue] = SubEl#contact_list.contact_hash,
    #pb_contact_hash{
        hash = base64:decode(HashValue)
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%

proto_to_xmpp(ProtoPayload) ->
    SubEl = case element(1, ProtoPayload) of
        pb_contact_list -> proto_to_xmpp_contact_list(ProtoPayload);
        pb_contact_hash -> proto_to_xmpp_contact_hash(ProtoPayload)
    end,
    SubEl.


proto_to_xmpp_contact_list(ProtoPayload) ->
    ContactList = ProtoPayload#pb_contact_list.contacts,
    XmppContacts = lists:map(
        fun(Contact) ->
            Uid = util_parser:proto_to_xmpp_uid(Contact#pb_contact.uid),
            #contact{
                type = Contact#pb_contact.action,
                raw = Contact#pb_contact.raw,
                normalized = Contact#pb_contact.normalized,
                userid = Uid,
                avatarid = Contact#pb_contact.avatar_id,
                name = Contact#pb_contact.name,
                role = proto_to_xmpp_role(Contact#pb_contact.role)
            }
        end,
        ContactList),
    #contact_list{
        xmlns = <<"halloapp:user:contacts">>,
        type = ProtoPayload#pb_contact_list.type,
        syncid = ProtoPayload#pb_contact_list.sync_id,
        index = ProtoPayload#pb_contact_list.batch_index,
        last = ProtoPayload#pb_contact_list.is_last,
        contacts = XmppContacts
    }.


proto_to_xmpp_role(PbRole) ->
    XmppRole = case PbRole of
        undefined -> <<>>;
        _ -> util:to_binary(PbRole)
    end,
    XmppRole.


proto_to_xmpp_contact_hash(ProtoPayload) ->
    #contact_list{
        xmlns = <<"halloapp:user:contacts">>,
        contact_hash = [base64:encode(ProtoPayload#pb_contact_hash.hash)]
    }.

