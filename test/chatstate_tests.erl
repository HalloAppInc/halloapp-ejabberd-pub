-module(chatstate_tests).

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").


group() ->
    {chatstate, [sequence], [
        chatstate_recv_chatstate_test,
        chatstate_block_chatstate_test
    ]}.


recv_chatstate_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),
    % UID4 and UID1 are not friends; UID5 has blocked UID1

    %% Wait and clear out all messages in the queue.
    ha_client:wait_for_eoq(C1),
    ha_client:wait_for_eoq(C2),

    TypingChatState = #pb_packet{
        stanza = #pb_chat_state{
            type = typing,
            thread_id = ?UID2
        }
    },
    ok = ha_client:send(C1, TypingChatState),

    RecvChatState = ha_client:wait_for(C2,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_chat_state{}} -> true;
                _Any -> false
            end
        end),
    ?assertEqual(typing, RecvChatState#pb_packet.stanza#pb_chat_state.type),
    ?assertEqual(?UID1, RecvChatState#pb_packet.stanza#pb_chat_state.thread_id),

    ha_client:stop(C2),
    {ok, C2_2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),
    %% This is used so that when we call recv with a timeout - we get the latest packet.
    ha_client:wait_for_eoq(C2_2),
    ha_client:clear_queue(C2_2),
    %% ensure you dont get anything here.
    ?assertEqual(undefined, ha_client:recv(C2_2, 100)),
    ok.


block_chatstate_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    {ok, C4} = ha_client:connect_and_login(?UID4, ?PASSWORD4),
    {ok, C5} = ha_client:connect_and_login(?UID5, ?PASSWORD5),
    % UID4 and UID1 are not friends; UID5 has blocked UID1

    %% Wait and clear out all messages in the queue.
    %% This is used so that when we call recv with a timeout - we get the latest packet.
    ha_client:wait_for_eoq(C1),
    ha_client:wait_for_eoq(C4),
    ha_client:wait_for_eoq(C5),
    ha_client:clear_queue(C4),
    ha_client:clear_queue(C5),


    TypingChatState = #pb_packet{
        stanza = #pb_chat_state{
            type = typing,
            thread_id = ?UID1
        }
    },

    ok = ha_client:send(C1, TypingChatState),

    %% ensure you dont get anything here, since C4 and C1 are not friends.
    ?assertEqual(undefined, ha_client:recv(C4, 100)),
    ?assertEqual(undefined, ha_client:recv(C5, 100)),
    ok.

