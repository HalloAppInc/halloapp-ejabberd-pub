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
        end, {<<>>, <<>>, <<>>, 0}, SubEl#chat.sub_els),
    #pb_chat{
        timestamp = util_parser:maybe_convert_to_integer(SubEl#chat.timestamp),
        payload = base64:decode(Content),
        enc_payload = base64:decode(EncryptedContent),
        public_key = base64:decode(PublicKey),
        one_time_pre_key_id = OneTimePreKeyId
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoPayload) ->
    Content = {xmlel,<<"s1">>,[],[{xmlcdata, base64:encode(ProtoPayload#pb_chat.payload)}]},
    FinalSubEls = case ProtoPayload#pb_chat.enc_payload of
        undefined -> [Content];
        <<>> -> [Content];
        _ ->
            Attrs = [{<<"identity_key">>, base64:encode(ProtoPayload#pb_chat.public_key)},
            {<<"one_time_pre_key_id">>, util_parser:maybe_convert_to_binary(ProtoPayload#pb_chat.one_time_pre_key_id)}],
            EncryptedContent = {xmlel,<<"enc">>, Attrs, [{xmlcdata, base64:encode(ProtoPayload#pb_chat.enc_payload)}]},
            [Content, EncryptedContent]
    end,
    #chat{
        xmlns = <<"halloapp:chat:messages">>,
        timestamp = util_parser:maybe_convert_to_binary(ProtoPayload#pb_chat.timestamp),
        sub_els = FinalSubEls
    }.

