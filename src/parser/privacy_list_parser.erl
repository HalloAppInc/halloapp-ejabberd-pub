-module(privacy_list_parser).

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


xmpp_to_proto(SubEl) when is_record(SubEl, user_privacy_list) ->
    xmpp_to_proto_user_privacy_list(SubEl);
xmpp_to_proto(SubEl) when is_record(SubEl, user_privacy_lists) ->
    PbPrivacyLists = lists:map(
        fun(UserPrivacyList) ->
            xmpp_to_proto_user_privacy_list(UserPrivacyList)
        end, SubEl#user_privacy_lists.lists),
    #pb_privacy_lists{
        active_type = SubEl#user_privacy_lists.active_type,
        lists = PbPrivacyLists
    };
xmpp_to_proto(SubEl) when is_record(SubEl, error_st) ->
    Hash = case SubEl#error_st.hash of
        undefined -> <<>>;
        H -> base64url:decode(H)
    end,
    #pb_privacy_list_result {
        result = <<"failed">>,
        reason = util:to_binary(SubEl#error_st.reason),
        hash = Hash
    }.


xmpp_to_proto_user_privacy_list(SubEl) ->
    UidElements = lists:map(
        fun(UidEl) ->
            #pb_uid_element{
                action = UidEl#uid_el.type,
                uid = util_parser:xmpp_to_proto_uid(UidEl#uid_el.uid)
            }
        end, SubEl#user_privacy_list.uid_els),
    Hash = case SubEl#user_privacy_list.hash of
        undefined -> <<>>;
        H -> base64url:decode(H)
    end,
    #pb_privacy_list {
        type = SubEl#user_privacy_list.type,
        hash = Hash,
        uid_elements = UidElements
    }.

%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%

proto_to_xmpp(ProtoPayload) when is_record(ProtoPayload, pb_privacy_list) ->
    proto_to_xmpp_privacy_list(ProtoPayload);
proto_to_xmpp(ProtoPayload) when is_record(ProtoPayload, pb_privacy_lists) ->
    UserPrivacyLists = lists:map(
        fun(PrivacyList) ->
            proto_to_xmpp_privacy_list(PrivacyList)
        end, ProtoPayload#pb_privacy_lists.lists),
    #user_privacy_lists{
        active_type = ProtoPayload#pb_privacy_lists.active_type,
        lists = UserPrivacyLists
    }.


proto_to_xmpp_privacy_list(ProtoPayload) ->
    UidElements = lists:map(
        fun(UidElement) ->
            #uid_el{
                type = UidElement#pb_uid_element.action,
                uid = util_parser:proto_to_xmpp_uid(UidElement#pb_uid_element.uid)
            }
        end, ProtoPayload#pb_privacy_list.uid_elements),
    #user_privacy_list {
        type = ProtoPayload#pb_privacy_list.type,
        hash = base64url:encode(ProtoPayload#pb_privacy_list.hash),
        uid_els = UidElements
    }.


