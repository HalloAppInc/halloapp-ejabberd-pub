-module(whisper_keys_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(#whisper_keys{} = SubEl) ->
    OneTimeKeys = lists:map(
        fun(OneTimeKey) ->
            util_parser:maybe_base64_decode(OneTimeKey)
        end, SubEl#whisper_keys.one_time_keys),
    #pb_whisper_keys{
        uid = SubEl#whisper_keys.uid,
        action = SubEl#whisper_keys.type,
        identity_key = util_parser:maybe_base64_decode(SubEl#whisper_keys.identity_key),
        signed_key = util_parser:maybe_base64_decode(SubEl#whisper_keys.signed_key),
        otp_key_count = util_parser:maybe_convert_to_integer(SubEl#whisper_keys.otp_key_count),
        one_time_keys = OneTimeKeys
    };
xmpp_to_proto(#rerequest_st{} = SubEl) ->
    #pb_rerequest{
        id = SubEl#rerequest_st.id,
        identity_key = util_parser:maybe_base64_decode(SubEl#rerequest_st.identity_key),
        signed_pre_key_id = SubEl#rerequest_st.signed_pre_key_id,
        one_time_pre_key_id = SubEl#rerequest_st.one_time_pre_key_id,
        session_setup_ephemeral_key = util_parser:maybe_base64_decode(SubEl#rerequest_st.session_setup_ephemeral_key),
        message_ephemeral_key = util_parser:maybe_base64_decode(SubEl#rerequest_st.message_ephemeral_key)
    }.


proto_to_xmpp(#pb_whisper_keys{} = ProtoPayload) ->
    OneTimeKeys = lists:map(
        fun(OneTimeKey) ->
            util_parser:maybe_base64_encode(OneTimeKey)
        end, ProtoPayload#pb_whisper_keys.one_time_keys),
    #whisper_keys{
        uid = ProtoPayload#pb_whisper_keys.uid,
        type = ProtoPayload#pb_whisper_keys.action,
        identity_key = util_parser:maybe_base64_encode(ProtoPayload#pb_whisper_keys.identity_key),
        signed_key = util_parser:maybe_base64_encode(ProtoPayload#pb_whisper_keys.signed_key),
        otp_key_count = util_parser:maybe_convert_to_binary(ProtoPayload#pb_whisper_keys.otp_key_count),
        one_time_keys = OneTimeKeys
    };
proto_to_xmpp(#pb_rerequest{} = ProtoPayload) ->
    #rerequest_st{
        id = ProtoPayload#pb_rerequest.id,
        identity_key = util_parser:maybe_base64_encode(ProtoPayload#pb_rerequest.identity_key),
        signed_pre_key_id = ProtoPayload#pb_rerequest.signed_pre_key_id,
        one_time_pre_key_id = ProtoPayload#pb_rerequest.one_time_pre_key_id,
        session_setup_ephemeral_key = util_parser:maybe_base64_encode(ProtoPayload#pb_rerequest.session_setup_ephemeral_key),
        message_ephemeral_key = util_parser:maybe_base64_encode(ProtoPayload#pb_rerequest.message_ephemeral_key)
    }.

