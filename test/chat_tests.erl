-module(chat_tests).

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").

group() ->
    {chat, [sequence], [
        chat_dummy_test,
        chat_send_im_test,
        chat_delete_account_msg_test
    ]}.

dummy_test(_Conf) ->
    ok.

send_im_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),
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

delete_account_msg_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    ok = model_accounts:create_account(?UID8, ?PHONE1, ?NAME3, ?UA, ?TS1),
    ok = model_phone:add_phone(?PHONE1, ?UID8),
    ok = ejabberd_auth:set_spub(?UID8, ?SPUB1),
    {ok, C2} = ha_client:connect_and_login(?UID8, ?KEYPAIR1),
    Payload = #pb_delete_account{phone = ?PHONE1},
    Result = ha_client:send_iq(C2, <<"iq_id_1">>, set, Payload),
    ha_client:send(C1, #pb_packet{
        stanza = #pb_msg{
            id = <<"msgid1">>,
            type = chat,
            from_uid = ?UID1,
            to_uid = ?UID8,
            payload = #pb_chat_stanza{payload = <<"HELLO">>}}}),
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
    RecvMsg = ha_client:wait_for(C1,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{id = <<"msgid1">>}} -> true;
                _Any -> false
            end
        end),
    #pb_packet{
        stanza = #pb_msg{
            id = <<"msgid1">>,
            type = error,
            from_uid = ?UID8,
            to_uid = ?UID1,
            payload = #pb_error_stanza{
                reason = <<"invalid_to_uid">>
            }
        }   
    } = RecvMsg,
    ok.

