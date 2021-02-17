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
    ha_client:send(C1, #pb_packet{
        % the {msg} part is annoying
        stanza = #pb_msg{
            id = <<"msgid1">>,
            type = chat,
            from_uid = ?UID1,
            to_uid = ?UID2,
            payload = #pb_chat_stanza{payload = <<"HELLO">>}}}),
    % TODO: use send_recv
    Ack = ha_client:wait_for(C1,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_ack{id = Id}} -> true;
                _Any -> false
            end
        end),
    #pb_packet{
        stanza = #pb_ack{id = <<"msgid1">>, timestamp = _ServerTs}
    } = Ack,
    RecvMsg = ha_client:wait_for(C2,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{id = <<"msgid1">>}} -> true;
                _Any -> false
            end
        end),
    #pb_packet{
        stanza = #pb_msg{
            id = <<"msgid1">>,
            type = chat,
            from_uid = ?UID1,
            to_uid = ?UID2,
            payload = #pb_chat_stanza{
                payload = <<"HELLO">>,
                sender_name = ?NAME1}}
    } = RecvMsg,
    ok.


