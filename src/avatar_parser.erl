-module(avatar_parser).

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
    ProtoContent = case element(1, SubEl) of
        avatar -> xmpp_to_proto_avatar(SubEl);
        avatars -> xmpp_to_proto_avatars(SubEl)
    end, 
    ProtoContent.


xmpp_to_proto_avatar(SubEl) -> 
    #pb_avatar{
        id = SubEl#avatar.id,
        uid = binary_to_integer(SubEl#avatar.userid),
        data = base64:decode(SubEl#avatar.cdata)
    }.


xmpp_to_proto_avatars(SubEl) -> 
    Avatars = SubEl#avatars.avatars,
    ProtoAvatars = lists:map(fun xmpp_to_proto_avatar/1, Avatars),
    #pb_avatars{
        avatars = ProtoAvatars
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoPayload) ->
    SubEl = case element(1, ProtoPayload) of
        pb_avatar -> proto_to_xmpp_avatar(ProtoPayload);
        pb_avatars -> proto_to_xmpp_avatars(ProtoPayload)
    end, 
    SubEl.


proto_to_xmpp_avatar(ProtoPayload) -> 
    #avatar{
        id = ProtoPayload#pb_avatar.id,
        userid = integer_to_binary(ProtoPayload#pb_avatar.uid),
        cdata = base64:encode(ProtoPayload#pb_avatar.data)
    }.


proto_to_xmpp_avatars(ProtoPayload) ->   
    PbAvatars = ProtoPayload#pb_avatars.avatars,
    XmppAvatars = lists:map(fun proto_to_xmpp_avatar/1, PbAvatars),
    #avatars{
        avatars = XmppAvatars
    }.

