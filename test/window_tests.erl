-module(window_tests).

-compile([nowarn_export_all, export_all]).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(OPTIONS1, #{auto_send_acks => true, resource => <<"android">>}).
-define(OPTIONS2, #{auto_send_acks => false, resource => <<"android">>}).

group() ->
    {window, [sequence], [
        window_dummy_test,
        window_end_of_queue_test,
        window_message_order_test,
        window_offline_msg1_test,
        window_offline_msg2_test
    ]}.

dummy_test(_Conf) ->
    ok.


end_of_queue_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1, ?OPTIONS1),
    recv_eoq(C1),
    ha_client:stop(C1),
    ok.


message_order_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1, ?OPTIONS1),
    wait_until_eoq(C1),
    send_message(C1, ?UID1, ?UID2, 1, 100, []),
    recv_acks(C1, 1, 100),

    %% First login.
    %% retry_count is still 1, so we will have to receive all 100 of them.
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, ?OPTIONS2),
    %% Send 5 new messages when C2 is online.
    send_message(C1, ?UID1, ?UID2, 101, 105, []),
    %% Make sure to receive 100 messages first,
    %% then end of queue and only then the remaining 5 messages.
    recv_messages(C2, 1, 100),
    recv_eoq(C2),
    recv_messages(C2, 101, 105),
    ha_client:stop(C2),

    %% Second login.
    %% retry_count is now 2, so we will get only 64 messages now.
    {ok, C2_2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, ?OPTIONS2),
    %% Send 5 new messages again when C2 is online.
    send_message(C1, ?UID1, ?UID2, 106, 110, []),
    recv_messages(C2_2, 1, 64),
    %% ensure you dont get an end_of_queue here.
    ?assertEqual(undefined, ha_client:recv(C2_2, 100)),
    %% Ack all 64 messages.
    send_acks(C2_2, 1, 64),
    %% Ensure you get all the remaining messages in-order.
    recv_messages(C2_2, 65, 110),
    %% Ensure that you get end of queue now only after receiving all the messages.
    recv_eoq(C2_2),
    send_acks(C2_2, 65, 110),

    ha_client:stop(C2_2),
    ha_client:stop(C1),

    %% clear out all offline messages for C1.
    {ok, C1_2} = ha_client:connect_and_login(?UID1, ?KEYPAIR1, ?OPTIONS1),
    wait_until_eoq(C1_2),
    ok.



offline_msg1_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1, ?OPTIONS1),
    wait_until_eoq(C1),
    send_message(C1, ?UID1, ?UID2, 1, 100, []),
    recv_acks(C1, 1, 100),

    %% retry_count is still 1, so we will have to receive all 100 of them.
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, ?OPTIONS2),
    recv_messages(C2, 1, 100),
    recv_eoq(C2),
    ha_client:stop(C2),

    %% retry_count is now 2, so we will get only 64 messages now.
    {ok, C2_2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, ?OPTIONS2),
    recv_messages(C2_2, 1, 64),
    %% ensure you dont get an end_of_queue here.
    ?assertEqual(undefined, ha_client:recv(C2_2, 100)),
    ha_client:stop(C2_2),

    %% retry_count is now 3, so we will get only 8 messages now.
    {ok, C2_3} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, ?OPTIONS2),
    recv_messages(C2_3, 1, 8),
    %% ensure you dont get an end_of_queue here.
    ?assertEqual(undefined, ha_client:recv(C2_3, 100)),
    ha_client:stop(C2_3),

    %% retry_count is now 4, so we will get only 1 messages now.
    {ok, C2_4} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, ?OPTIONS2),
    recv_messages(C2_4, 1, 1),
    %% ensure you dont get an end_of_queue here.
    ?assertEqual(undefined, ha_client:recv(C2_4, 100)),
    ha_client:stop(C2_4),

    %% retry_count is now 5, so we will get only 1 messages now.
    {ok, C2_5} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, ?OPTIONS2),
    recv_messages(C2_5, 1, 1),
    %% ensure you dont get an end_of_queue here.
    ?assertEqual(undefined, ha_client:recv(C2_5, 100)),
    ha_client:stop(C2_5),

    ok.


offline_msg2_test(_Conf) ->
    %% message with max_retry_count = 5 is dropped now.

    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2, ?OPTIONS2),

    %% window = 1
    %% retry_count of head message is now 5.
    %% pending_acks = 0
    %% new_window = 1.
    %% sending 1 messages.
    recv_messages(C2, 2, 2),

    %% window = 1, pending_acks = 1
    send_acks(C2, 2, 2),

    %% window = 1
    %% retry_count of head message is now 4.
    %% pending_acks = 1
    %% new_window = 1.
    %% sending 1 messages.
    recv_messages(C2, 3, 3),

    %% window = 1, pending_acks = 1
    send_acks(C2, 3, 3),

    %% window = 1
    %% retry_count of head message is now 4.
    %% pending_acks = 1
    %% new_window = 1.
    %% sending 1 messages.
    recv_messages(C2, 4, 4),

    %% window = 1, pending_acks = 1
    send_acks(C2, 4, 4),

    %% window = 1
    %% retry_count of head message is now 4.
    %% pending_acks = 1
    %% new_window = 1.
    %% sending 1 messages.
    recv_messages(C2, 5, 5),

    %% window = 1, pending_acks = 1
    send_acks(C2, 5, 5),

    %% window = 1
    %% retry_count of head message is now 4.
    %% pending_acks = 1
    %% new_window = 1.
    %% sending 1 messages.
    recv_messages(C2, 6, 6),

    %% window = 1, pending_acks = 1
    send_acks(C2, 6, 6),

    %% window = 1
    %% retry_count of head message is now 4.
    %% pending_acks = 1
    %% new_window = 1.
    %% sending 1 messages.
    recv_messages(C2, 7, 7),

    %% window = 1, pending_acks = 1
    send_acks(C2, 7, 7),

    %% window = 1
    %% retry_count of head message is now 4.
    %% pending_acks = 1
    %% new_window = 1.
    %% sending 1 messages.
    recv_messages(C2, 8, 8),

    %% window = 1, pending_acks = 1
    send_acks(C2, 8, 8),

    %% window = 1
    %% retry_count of head message is now 3.
    %% pending_acks = 0
    %% new_window = 8.
    %% sending 1 messages.
    recv_messages(C2, 9, 9),

    %% window = 8, pending_acks = 1
    send_acks(C2, 9, 9),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 0
    %% new_window = 8.
    %% sending 8 messages.
    recv_messages(C2, 10, 17),

    %% window = 8, pending_acks = 8
    send_acks(C2, 10, 13),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 18, 21),

    %% window = 8, pending_acks = 8
    send_acks(C2, 14, 17),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 22, 25),

    %% window = 8, pending_acks = 8
    send_acks(C2, 18, 21),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 26, 29),

    %% window = 8, pending_acks = 8
    send_acks(C2, 22, 25),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 30, 33),

    %% window = 8, pending_acks = 8
    send_acks(C2, 26, 29),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 34, 37),

    %% window = 8, pending_acks = 8
    send_acks(C2, 30, 33),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 38, 41),

    %% window = 8, pending_acks = 8
    send_acks(C2, 34, 37),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 42, 45),

    %% window = 8, pending_acks = 8
    send_acks(C2, 38, 41),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 46, 49),

    %% window = 8, pending_acks = 8
    send_acks(C2, 42, 45),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 50, 53),

    %% window = 8, pending_acks = 8
    send_acks(C2, 46, 49),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 54, 57),

    %% window = 8, pending_acks = 8
    send_acks(C2, 50, 53),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 58, 61),

    %% window = 8, pending_acks = 8
    send_acks(C2, 54, 57),

    %% window = 8
    %% retry_count of head message is now 3.
    %% pending_acks = 4
    %% new_window = 8.
    %% sending 4 messages.
    recv_messages(C2, 62, 65),

    %% window = 8, pending_acks = 8
    send_acks(C2, 58, 61),

    %% window = 8
    %% retry_count of head message is now 2.
    %% pending_acks = 4
    %% new_window = 64.
    %% sending 4 messages.
    recv_messages(C2, 66, 69),

    %% window = 64, pending_acks = 8
    send_acks(C2, 62, 62),

    %% window = 64
    %% retry_count of head message is now 2.
    %% pending_acks = 7
    %% new_window = 64.
    %% sending 57 messages.
    recv_messages(C2, 70, 100),

    send_acks(C2, 63, 100),
    ha_client:stop(C2),
    ok.


% duplicate_message_test(_Conf) ->
%     ct:timetrap({seconds, 60}),

%     {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1, ?OPTIONS1),
%     wait_until_eoq(C1),
%     send_message(C1, ?UID1, ?UID2, 1, 5, []),
%     recv_acks(C1, 1, 5),

%     %% retry_count is still 1, so we will have to receive all 100 of them.
%     {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2, ?OPTIONS2),
%     recv_messages(C2, 1, 5),
%     recv_eoq(C2),

%     %% Now C2 - has a scheduled offline queue check in a few seconds.
%     %% Send 5 new messages when C2 is online.
%     send_message(C1, ?UID1, ?UID2, 6, 10, []),

%     %% recv messages only once.
%     recv_messages(C2, 6, 10),
%     ct:sleep({seconds, 35}),

%     %% after 30 seconds - you should not be getting any more messages.
%     undefined = ha_client:recv_nb(C2),

%     ha_client:stop(C2),
%     %% clear out all offline messages for C2.
%     {ok, C2_2} = ha_client:connect_and_login(?UID2, ?PASSWORD2, ?OPTIONS1),
%     wait_until_eoq(C2_2),
%     ok.


%%%===================================================================
%%% internal functions
%%%===================================================================

-spec send_message(Client :: pid(), FromUid :: integer(), ToUid :: integer(),
        StartId :: integer(), EndId :: integer(), Msgs :: [#pb_packet{}]) -> [#pb_packet{}].
send_message(Client, FromUid, ToUid, StartId, EndId, _Msgs) ->
    MsgStanza = #pb_msg{
            type = chat,
            from_uid = FromUid,
            to_uid = ToUid,
            payload = #pb_chat_stanza{payload = <<"HELLO">>}
        },
    lists:map(
        fun(SeqId) ->
            NewStanza = MsgStanza#pb_msg{id = util:to_binary(SeqId)},
            ha_client:send(Client, #pb_packet{stanza = NewStanza})
        end,
        lists:seq(StartId, EndId)).


-spec recv_messages(Client :: pid(), StartId :: integer(), EndId :: integer()) -> ok.
recv_messages(Client, StartId, EndId) ->
    lists:map(
        fun(SeqId) ->
            RecvMsg = ha_client:wait_for_msg(Client),
            ?assertEqual(util:to_binary(SeqId), RecvMsg#pb_packet.stanza#pb_msg.id)
        end,
        lists:seq(StartId, EndId)).


-spec send_acks(Client :: pid(), StartId :: integer(), EndId :: integer()) -> ok.
send_acks(Client, StartId, EndId) ->
    lists:map(
        fun(SeqId) ->
            ok = ha_client:send_ack(Client, util:to_binary(SeqId))
        end,
        lists:seq(StartId, EndId)).


-spec recv_acks(Client :: pid(), StartId :: integer(), EndId :: integer()) -> ok.
recv_acks(Client, StartId, EndId) ->
    lists:map(
        fun(_SeqId) ->
            _RecvAck = ha_client:wait_for(Client,
                fun (P) ->
                    case P of
                        #pb_packet{stanza = #pb_ack{id = _Id}} -> true;
                        _Any -> false
                    end
                end)
        end,
        lists:seq(StartId, EndId)).


-spec recv_eoq(Client :: pid()) -> ok.
recv_eoq(Client) ->
    RecvMsg = ha_client:wait_for_msg(Client),
    ?assertEqual(#pb_end_of_queue{}, RecvMsg#pb_packet.stanza#pb_msg.payload),
    ok.


-spec wait_until_eoq(Client :: pid()) -> ok.
wait_until_eoq(Client) ->
    ha_client:wait_for_eoq(Client),
    ok.


