-module(chat_state_parser_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").


setup() ->
    stringprep:start(),
    ok.

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%


chat_state_xmpp_to_proto_test() ->
    setup(),

    FromJid = jid:make(?UID1, ?SERVER),
    ToJid = jid:make(?UID2, ?SERVER),
    XmppChatState = struct_util:create_chat_state(ToJid, FromJid, typing, ?UID1, chat),
    ExpectedPbChatState = struct_util:create_pb_chat_state(typing, ?UID1, chat, ?UID1_INT),
    ActualPbChatState = chat_state_parser:xmpp_to_proto(XmppChatState),

    ?assertEqual(true, is_record(ActualPbChatState, pb_chat_state)),
    ?assertEqual(ExpectedPbChatState, ActualPbChatState).


chat_state_proto_to_xmpp_test() ->
    setup(),

    FromJid = jid:make(?UID2, ?SERVER),
    ToJid = jid:make(?SERVER),
    ExpectedXmppChatState = struct_util:create_chat_state(ToJid, FromJid, available, ?GID1, group_chat),
    PbChatState = struct_util:create_pb_chat_state(available, ?GID1, group_chat, ?UID2_INT),
    ActualXmppChatState = chat_state_parser:proto_to_xmpp(PbChatState),

    ?assertEqual(true, is_record(ActualXmppChatState, chat_state)),
    ?assertEqual(ExpectedXmppChatState, ActualXmppChatState).

