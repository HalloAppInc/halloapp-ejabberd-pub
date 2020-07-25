-module(whisper_keys_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(SubEl) ->
    #pb_whisper_keys{
        uid = binary_to_integer(SubEl#whisper_keys.uid),
        action = SubEl#whisper_keys.type,
        identity_key = SubEl#whisper_keys.identity_key,
        signed_key = SubEl#whisper_keys.signed_key,
        otp_key_count = binary_to_integer(SubEl#whisper_keys.otp_key_count),
        one_time_keys = SubEl#whisper_keys.one_time_keys
    }.


proto_to_xmpp(ProtoPayload) ->
    #whisper_keys{
        uid = integer_to_binary(ProtoPayload#pb_whisper_keys.uid),
        type = ProtoPayload#pb_whisper_keys.action,
        identity_key = ProtoPayload#pb_whisper_keys.identity_key,
        signed_key = ProtoPayload#pb_whisper_keys.signed_key,
        otp_key_count = integer_to_binary(ProtoPayload#pb_whisper_keys.otp_key_count),
        one_time_keys = ProtoPayload#pb_whisper_keys.one_time_keys
    }.

