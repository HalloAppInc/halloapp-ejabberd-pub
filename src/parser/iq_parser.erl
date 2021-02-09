-module(iq_parser).

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


xmpp_to_proto(XmppIQ) ->
    SubEls = XmppIQ#iq.sub_els,
    Content = case XmppIQ#iq.sub_els of
        [] ->
            undefined;
        _ ->
            [SubEl] = SubEls,
            iq_payload_mapping(SubEl)
    end,
    ProtoIQ = #pb_iq{
        id = XmppIQ#iq.id,
        type = XmppIQ#iq.type,
        payload = Content
    },
    ProtoIQ.


iq_payload_mapping(SubEl) ->
    Payload = case element(1, SubEl) of
        error_st ->
            Hash = SubEl#error_st.hash,
            case Hash =:= undefined orelse Hash =:= <<>> of
                true ->
                    #pb_error_stanza{reason = util:to_binary(SubEl#error_st.reason)};
                false ->
                    privacy_list_parser:xmpp_to_proto(SubEl)
            end;
        groups ->
            groups_parser:xmpp_to_proto(SubEl);
        group_st ->
            groups_parser:xmpp_to_proto(SubEl);
        name ->
            name_parser:xmpp_to_proto(SubEl);
        group_feed_st ->
            group_feed_parser:xmpp_to_proto(SubEl);
        stanza_error ->
            #pb_error_stanza{reason = util:to_binary(SubEl#stanza_error.reason)};
        _ ->
            uid_parser:translate_to_pb_uid(SubEl)
    end,
    Payload.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoIQ) ->
    Content = ProtoIQ#pb_iq.payload,
    SubEl = xmpp_iq_subel_mapping(Content),
    XmppIQ = #iq{
        id = ProtoIQ#pb_iq.id,
        type = ProtoIQ#pb_iq.type,
        sub_els = [SubEl]
    },
    XmppIQ.


xmpp_iq_subel_mapping(ProtoPayload) ->
    SubEl = case ProtoPayload of
        #pb_groups_stanza{} = GroupsStanzaRecord ->
            groups_parser:proto_to_xmpp(GroupsStanzaRecord);
        #pb_group_stanza{} = GroupStanzaRecord ->
            groups_parser:proto_to_xmpp(GroupStanzaRecord);
        #pb_group_feed_item{} = GroupFeedItemRecord ->
            group_feed_parser:proto_to_xmpp(GroupFeedItemRecord);
        _ ->
            uid_parser:translate_to_xmpp_uid(ProtoPayload)
    end,
    SubEl.
