-module(groups_parser).

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


xmpp_to_proto(SubEl) when is_record(SubEl, groups) ->
    GroupStanzas = lists:map(fun(GroupSt) -> xmpp_to_proto(GroupSt) end, SubEl#groups.groups),
    #pb_groups_stanza{
        action = SubEl#groups.action,
        group_stanzas = GroupStanzas
    };

xmpp_to_proto(SubEl) when is_record(SubEl, group_st) ->
    Members = lists:map(
        fun(MemberSt) ->
            #pb_group_member {
                action = MemberSt#member_st.action,
                uid = MemberSt#member_st.uid,
                type = MemberSt#member_st.type,
                name = MemberSt#member_st.name,
                avatar_id = MemberSt#member_st.avatar,
                result = util_parser:maybe_convert_to_binary(MemberSt#member_st.result),
                reason = util_parser:maybe_convert_to_binary(MemberSt#member_st.reason)
            }
        end, SubEl#group_st.members),
    #pb_group_stanza {
        action = SubEl#group_st.action,
        gid = SubEl#group_st.gid,
        name = SubEl#group_st.name,
        avatar_id = SubEl#group_st.avatar,
        sender_uid = SubEl#group_st.sender,
        sender_name = SubEl#group_st.sender_name,
        members = Members
    };

xmpp_to_proto(SubEl) when is_record(SubEl, group_chat) ->
    [ChatPayload] = SubEl#group_chat.sub_els,
    #pb_group_chat {
        gid = SubEl#group_chat.gid,
        name = SubEl#group_chat.name,
        avatar_id = SubEl#group_chat.avatar,
        sender_uid = SubEl#group_chat.sender,
        sender_name = SubEl#group_chat.sender_name,
        timestamp = util_parser:maybe_convert_to_integer(SubEl#group_chat.timestamp),
        payload = util_parser:maybe_base64_decode(fxml:get_tag_cdata(ChatPayload))
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%

proto_to_xmpp(ProtoPayload) when is_record(ProtoPayload, pb_group_chat) ->
    #group_chat {
        xmlns = <<"halloapp:groups">>,
        gid = ProtoPayload#pb_group_chat.gid,
        name = ProtoPayload#pb_group_chat.name,
        avatar = ProtoPayload#pb_group_chat.avatar_id,
        sender = ProtoPayload#pb_group_chat.sender_uid,
        sender_name = ProtoPayload#pb_group_chat.sender_name,
        timestamp = util_parser:maybe_convert_to_binary(ProtoPayload#pb_group_chat.timestamp),
        sub_els = [
                {xmlel,<<"s1">>,[],
                [{xmlcdata, util_parser:maybe_base64_encode_binary(ProtoPayload#pb_group_chat.payload)}]}
        ]
    };

proto_to_xmpp(ProtoPayload) when is_record(ProtoPayload, pb_group_stanza) ->
    MembersSt = lists:map(
        fun(PbMember) ->
            #member_st {
                action = PbMember#pb_group_member.action,
                uid = PbMember#pb_group_member.uid,
                type = PbMember#pb_group_member.type,
                name = PbMember#pb_group_member.name,
                avatar = PbMember#pb_group_member.avatar_id
            }
        end, ProtoPayload#pb_group_stanza.members),
    #group_st {
        action = ProtoPayload#pb_group_stanza.action,
        gid = ProtoPayload#pb_group_stanza.gid,
        name = ProtoPayload#pb_group_stanza.name,
        avatar = ProtoPayload#pb_group_stanza.avatar_id,
        sender = ProtoPayload#pb_group_stanza.sender_uid,
        sender_name = ProtoPayload#pb_group_stanza.sender_name,
        members = MembersSt
    };

proto_to_xmpp(ProtoPayload) when is_record(ProtoPayload, pb_groups_stanza) ->
    GroupSts = lists:map(
        fun(PbGroup) -> proto_to_xmpp(PbGroup) end,
        ProtoPayload#pb_groups_stanza.group_stanzas),
    #groups{
        action = ProtoPayload#pb_groups_stanza.action,
        groups = GroupSts
    };

proto_to_xmpp(ProtoPayload) when is_record(ProtoPayload, pb_upload_group_avatar) ->
    CData = case ProtoPayload#pb_upload_group_avatar.data of
        undefined -> <<>>;
        Data -> base64:encode(Data)
    end,
    #group_avatar{
        gid = ProtoPayload#pb_upload_group_avatar.gid,
        cdata = CData
    }.

