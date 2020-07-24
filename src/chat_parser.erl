-module(chat_parser).

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
    [SubElContent] = SubEl#chat.sub_els,
    #pb_chat{
        timestamp = binary_to_integer(SubEl#chat.timestamp),
        payload = fxml:get_tag_cdata(SubElContent)
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoPayload) ->
    #chat{
        timestamp = integer_to_binary(ProtoPayload#pb_chat.timestamp),
        sub_els = [{xmlel,<<"s1">>,[],[{xmlcdata, ProtoPayload#pb_chat.payload}]}]
    }.

