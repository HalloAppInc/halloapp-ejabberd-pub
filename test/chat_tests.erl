-module(chat_tests).

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").

group() ->
    {chat, [sequence], [
        chat_dummy_test,
        chat_send_im_test
    ]}.

dummy_test(_Conf) ->
    ok.

send_im_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),
    Uid1 = binary_to_integer(?UID1),
    Uid2 = binary_to_integer(?UID2),
    ha_client:send(C1, #pb_packet{
        % the {msg} part is annoying
        stanza = #pb_msg{
            id = <<"msgid1">>,
            type = chat,
            from_uid = Uid1,
            to_uid = Uid2,
            payload = #pb_chat_stanza{payload = <<"HELLO">>}}}),
    RecvMsg = ha_client:recv(C2),
    #pb_packet{
        stanza = #pb_msg{
            id = <<"msgid1">>,
            type = chat,
            from_uid = Uid1,
            to_uid = Uid2,
            payload = #pb_chat_stanza{
                payload = <<"HELLO">>,
                sender_name = ?NAME1}}
    } = RecvMsg,
    ok.


