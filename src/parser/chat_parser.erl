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
    {Content, EncryptedContent, PublicKey, OneTimePreKeyId} = lists:foldl(
        fun(SubElement, {S1, Enc, PKey, OtpKeyId}) ->
            case SubElement#xmlel.name of
                <<"s1">> -> {fxml:get_tag_cdata(SubElement), Enc, PKey, OtpKeyId};
                <<"enc">> ->
                    Cdata = fxml:get_tag_cdata(SubElement),
                    Attr1 = fxml:get_tag_attr_s(<<"identity_key">>, SubElement),
                    Attr2 = fxml:get_tag_attr_s(<<"one_time_pre_key_id">>, SubElement),
                    {S1, Cdata, Attr1, binary_to_integer(Attr2)}
            end
        end, {<<>>, <<>>, <<>>, <<>>}, SubEl#chat.sub_els),
    #pb_chat{
        timestamp = binary_to_integer(SubEl#chat.timestamp),
        payload = Content,
        enc_payload = EncryptedContent,
        public_key = PublicKey,
        one_time_pre_key_id = OneTimePreKeyId
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoPayload) ->
    Attrs = [{<<"identity_key">>, ProtoPayload#pb_chat.public_key},
            {<<"one_time_pre_key_id">>, integer_to_binary(ProtoPayload#pb_chat.one_time_pre_key_id)}],
    Content = {xmlel,<<"s1">>,[],[{xmlcdata, ProtoPayload#pb_chat.payload}]},
    EncryptedContent = {xmlel,<<"enc">>, Attrs, [{xmlcdata, ProtoPayload#pb_chat.enc_payload}]},
    #chat{
        xmlns = <<"halloapp:chat:messages">>,
        timestamp = integer_to_binary(ProtoPayload#pb_chat.timestamp),
        sub_els = [Content, EncryptedContent]
    }.

