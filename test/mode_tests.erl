-module(mode_tests).

-compile([nowarn_export_all, export_all]).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

group() ->
    {mode, [sequence], [
        mode_dummy_test,
        mode_send_recv_im_test,
        mode_send_no_recv_im_test
    ]}.

dummy_test(_Conf) ->
    ok.

send_recv_im_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1, #{mode => active}),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, #{mode => active}),
    ha_client:wait_for_eoq(C1),
    ha_client:wait_for_eoq(C2),
    ha_client:clear_queue(C1),
    ha_client:clear_queue(C2),

    ok = ha_client:send_msg(C1, chat, ?UID2, #pb_chat_stanza{payload = <<"HELLO">>}),
    RecvMsg = ha_client:wait_for_msg(C2),
    #pb_packet{
        stanza = #pb_msg{
            type = chat,
            from_uid = ?UID1,
            to_uid = ?UID2,
            payload = #pb_chat_stanza{
                payload = <<"HELLO">>,
                sender_name = ?NAME1}}
    } = RecvMsg,
    ok.


send_no_recv_im_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1, #{mode => active}),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, #{mode => passive}),
    ha_client:wait_for_eoq(C1),
    ha_client:clear_queue(C1),

    ok = ha_client:send_msg(C1, chat, ?UID2, #pb_chat_stanza{payload = <<"HELLO">>}),

    % Uid2 - C2 is not supposed to get the message because it is connected in passive mode.
    ?assertEqual(undefined, ha_client:recv(C2, 200)),
    ok.


send_no_recv_im2_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1, #{mode => active}),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, #{mode => passive}),
    ha_client:wait_for_eoq(C1),
    ha_client:clear_queue(C1),

    Id1 = <<"id1">>,
    ok = ha_client:send_msg(C1, Id1, chat, ?UID2, #pb_chat_stanza{payload = <<"HELLO1">>}),
    ok = ha_client:send_msg(C1, chat, ?UID2, #pb_chat_stanza{payload = <<"HELLO2">>}),

    % Uid2 - C2 is not supposed to get the message because it is connected in passive mode.
    ?assertEqual(undefined, ha_client:recv(C2, 200)),
    %% Inspite of acking the message here. no messages should be received by C2.
    ha_client:send_ack(C2, Id1),
    ?assertEqual(undefined, ha_client:recv(C2, 200)),
    ok.

