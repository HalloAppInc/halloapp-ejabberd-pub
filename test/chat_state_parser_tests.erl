-module(chat_state_parser_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").


-define(UID1, <<"1">>).
-define(UID1_INT, 1).
-define(UID2, <<"2">>).
-define(UID2_INT, 2).
-define(SERVER, <<"s.halloapp.net">>).
-define(GID1, <<"GID1">>).

create_chat_state(ToJid, FromJid, Type, ThreadId, ThreadType) ->
    #chat_state{
        to = ToJid,
        from = FromJid,
        type = Type,
        thread_id = ThreadId,
        thread_type = ThreadType
    }.


create_pb_chat_state(Type, ThreadId, ThreadType, FromUid) ->
    #pb_chat_state{
        type = Type,
        thread_id = ThreadId,
        thread_type = ThreadType,
        from_uid = FromUid
    }.


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
    XmppChatState = create_chat_state(ToJid, FromJid, typing, ?UID1, chat),
    ExpectedPbChatState = create_pb_chat_state(typing, ?UID1, chat, ?UID1_INT),
    ActualPbChatState = chat_state_parser:xmpp_to_proto(XmppChatState),

    ?assertEqual(true, is_record(ActualPbChatState, pb_chat_state)),
    ?assertEqual(ExpectedPbChatState, ActualPbChatState).


chat_state_proto_to_xmpp_test() ->
    setup(),

    FromJid = jid:make(?UID2, ?SERVER),
    ToJid = jid:make(?SERVER),
    ExpectedXmppChatState = create_chat_state(ToJid, FromJid, available, ?GID1, group_chat),
    PbChatState = create_pb_chat_state(available, ?GID1, group_chat, ?UID2_INT),
    ActualXmppChatState = chat_state_parser:proto_to_xmpp(PbChatState),

    ?assertEqual(true, is_record(ActualXmppChatState, chat_state)),
    ?assertEqual(ExpectedXmppChatState, ActualXmppChatState).

