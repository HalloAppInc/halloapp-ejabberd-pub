-module(retract_parser).

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


xmpp_to_proto(#chat_retract_st{id = Id}) ->
    #pb_chat_retract{
        id = Id
    };
xmpp_to_proto(#groupchat_retract_st{id = Id, gid = Gid}) ->
    #pb_group_chat_retract{
        id = Id,
        gid = Gid
    }.

%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(#pb_chat_retract{id = Id}) ->
    #chat_retract_st{
        id = Id
    };
proto_to_xmpp(#pb_group_chat_retract{id = Id, gid = Gid}) ->
    #groupchat_retract_st{
        id = Id,
        gid = Gid
    }.

