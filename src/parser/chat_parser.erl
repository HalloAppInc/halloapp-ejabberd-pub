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
                    EncData = case Cdata of
                        <<>> -> undefined;
                        undefined -> undefined;
                        _ -> base64:decode(Cdata)
                    end,
                    PKeyAttr = case Attr1 of
                        <<>> -> undefined;
                        undefined -> undefined;
                        _ -> base64:decode(Attr1)
                    end,
                    OtpKeyIdAttr = case Attr2 of
                        <<>> -> undefined;
                        0 -> undefined;
                        undefined -> undefined;
                        _ -> binary_to_integer(Attr2)
                    end,

                    {S1, EncData, PKeyAttr, OtpKeyIdAttr}
            end
        end, {<<>>, undefined, undefined, undefined}, SubEl#chat.sub_els),
    #pb_chat_stanza{
        timestamp = util_parser:maybe_convert_to_integer(SubEl#chat.timestamp),
        sender_name = SubEl#chat.sender_name,
        payload = base64:decode(Content),
        enc_payload = EncryptedContent,
        public_key = PublicKey,
        one_time_pre_key_id = OneTimePreKeyId
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoPayload) ->
    Content = {xmlel,<<"s1">>,[],[{xmlcdata, base64:encode(ProtoPayload#pb_chat_stanza.payload)}]},
    FinalSubEls = case ProtoPayload#pb_chat_stanza.enc_payload of
        undefined -> [Content];
        <<>> -> [Content];
        _ ->
            PkeyAttr = case ProtoPayload#pb_chat_stanza.public_key of
                undefined -> [];
                Pkey -> [{<<"identity_key">>, base64:encode(Pkey)}]
            end,
            OtpKeyIdAttr = case ProtoPayload#pb_chat_stanza.one_time_pre_key_id of
                undefined -> [];
                OtpKeyId -> [{<<"one_time_pre_key_id">>, util_parser:maybe_convert_to_binary(OtpKeyId)}]
            end,
            Attrs = PkeyAttr ++ OtpKeyIdAttr,
            EncryptedContent = {xmlel,<<"enc">>, Attrs, [{xmlcdata, base64:encode(ProtoPayload#pb_chat_stanza.enc_payload)}]},
            [Content, EncryptedContent]
    end,
    #chat{
        xmlns = <<"halloapp:chat:messages">>,
        timestamp = util_parser:maybe_convert_to_binary(ProtoPayload#pb_chat_stanza.timestamp),
        sender_name = ProtoPayload#pb_chat_stanza.sender_name,
        sub_els = FinalSubEls
    }.

