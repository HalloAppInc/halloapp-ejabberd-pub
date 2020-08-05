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
    {Content, EncryptedContent} = lists:foldl(
        fun(SubElement, {S1, Enc}) ->
            case SubElement#xmlel.name of
                <<"s1">> -> {fxml:get_tag_cdata(SubElement), Enc};
                <<"enc">> -> {S1, fxml:get_tag_cdata(SubElement)}
            end
        end, {<<>>, <<>>}, SubEl#chat.sub_els),
    #pb_chat{
        timestamp = binary_to_integer(SubEl#chat.timestamp),
        payload = Content,
        enc_payload = EncryptedContent
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoPayload) ->
    Content = {xmlel,<<"s1">>,[],[{xmlcdata, ProtoPayload#pb_chat.payload}]},
    EncryptedContent = {xmlel,<<"enc">>,[],[{xmlcdata, ProtoPayload#pb_chat.enc_payload}]},
    #chat{
        timestamp = integer_to_binary(ProtoPayload#pb_chat.timestamp),
        sub_els = [Content, EncryptedContent]
    }.

