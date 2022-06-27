-module(presence_tests).

-compile([nowarn_export_all, export_all]).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").


group() ->
    {presence, [sequence], [
        presence_recv_presence_test,
        presence_block1_presence_test,
        presence_block2_presence_test
    ]}.


%% UID2 must receive presence status of UID1 only after subscribing to it.
recv_presence_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),
    % UID4 does not have contact of UID1; UID5 has blocked UID1

    %% Wait and clear out all messages in the queue.
    ha_client:wait_for_eoq(C1),
    ha_client:wait_for_eoq(C2),
    ha_client:clear_queue(C2),

    Available = #pb_packet{
        stanza = #pb_presence{
            id = <<"id1">>,
            type = available
        }
    },

    ok = ha_client:send(C1, Available),

    Subscribe = #pb_packet{
        stanza = #pb_presence{
            id = <<"id1">>,
            type = subscribe,
            to_uid = ?UID1
        }
    },

    ok = ha_client:send(C2, Subscribe),
    RecvPresence1 = ha_client:wait_for(C2,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_presence{}} -> true;
                _Any -> false
            end
        end),
    ?assertEqual(available, RecvPresence1#pb_packet.stanza#pb_presence.type),
    ?assertEqual(?UID1, RecvPresence1#pb_packet.stanza#pb_presence.from_uid),

    Away = #pb_packet{
        stanza = #pb_presence{
            id = <<"id2">>,
            type = away
        }
    },
    ok = ha_client:send(C1, Away),

    RecvPresence2 = ha_client:wait_for(C2,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_presence{}} -> true;
                _Any -> false
            end
        end),
    ?assertEqual(away, RecvPresence2#pb_packet.stanza#pb_presence.type),
    ?assertEqual(?UID1, RecvPresence2#pb_packet.stanza#pb_presence.from_uid),

    ha_client:stop(C2),
    ok.


%% UID4 and UID5 must receive presence of UID2 only after they subscribe to it.
%% They will not receive presence of UID1 because they dont have their phonenumbers - even if they subscribe.
%% tests receiving presence of blocked contact only in 1 direction.
block1_presence_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),
    {ok, C4} = ha_client:connect_and_login(?UID4, ?KEYPAIR4),
    {ok, C5} = ha_client:connect_and_login(?UID5, ?KEYPAIR5),
    % UID4 does not have UID1's contact; UID5 has blocked UID1
    %% UID2 has UID4's contact.
    %% UID2 has UID5's contact.

    %% Wait and clear out all messages in the queue.
    ha_client:wait_for_eoq(C1),
    ha_client:wait_for_eoq(C4),
    ha_client:wait_for_eoq(C5),
    ha_client:clear_queue(C4),
    ha_client:clear_queue(C5),

    Available = #pb_packet{
        stanza = #pb_presence{
            id = <<"id1">>,
            type = available
        }
    },

    Subscribe1 = #pb_packet{
        stanza = #pb_presence{
            id = <<"id2">>,
            type = subscribe,
            to_uid = ?UID1
        }
    },

    Subscribe2 = #pb_packet{
        stanza = #pb_presence{
            id = <<"id3">>,
            type = subscribe,
            to_uid = ?UID2
        }
    },

    ok = ha_client:send(C1, Available),
    ok = ha_client:send(C2, Available),

    % We need to give some time for the requests on C1 and C2 to get processed
    timer:sleep(100),

    ok = ha_client:send(C4, Subscribe1),
    ok = ha_client:send(C5, Subscribe1),

    ok = ha_client:send(C4, Subscribe2),
    ok = ha_client:send(C5, Subscribe2),

    PresenceWaitFun = fun (P) ->
        case P of
            #pb_packet{stanza = #pb_presence{}} -> true;
            _Any -> false
        end
    end,

    %% ensure you get C2's presence fine.
    RecvPresence4 = ha_client:wait_for(C4, PresenceWaitFun),
    ?assertEqual(available, RecvPresence4#pb_packet.stanza#pb_presence.type),
    ?assertEqual(?UID2, RecvPresence4#pb_packet.stanza#pb_presence.from_uid),

    %% ensure you get C2's presence fine.
    RecvPresence5 = ha_client:wait_for(C5, PresenceWaitFun),
    ?assertEqual(available, RecvPresence5#pb_packet.stanza#pb_presence.type),
    ?assertEqual(?UID2, RecvPresence5#pb_packet.stanza#pb_presence.from_uid),
    ok.


%% UID1 and UID5 must not receive presence of each other when they block it.
%% tests subscribing in both directions.
block2_presence_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C5} = ha_client:connect_and_login(?UID5, ?KEYPAIR5),
    % UID5 has blocked UID1

    Available = #pb_packet{
        stanza = #pb_presence{
            id = <<"id1">>,
            type = available
        }
    },

    ok = ha_client:send(C1, Available),
    ok = ha_client:send(C5, Available),

    % We need to give some time for the requests on C1 and C5 to get processed
    timer:sleep(100),

    %% Wait and clear out all messages in the queue.
    ha_client:wait_for_eoq(C1),
    ha_client:wait_for_eoq(C5),
    ha_client:clear_queue(C1),
    ha_client:clear_queue(C5),

    Subscribe1 = #pb_packet{
        stanza = #pb_presence{
            id = <<"id2">>,
            type = subscribe,
            to_uid = ?UID5
        }
    },

    Subscribe2 = #pb_packet{
        stanza = #pb_presence{
            id = <<"id3">>,
            type = subscribe,
            to_uid = ?UID1
        }
    },

    ok = ha_client:send(C1, Subscribe1),
    ok = ha_client:send(C5, Subscribe2),

    timer:sleep(100),

    ?assertEqual(undefined, ha_client:recv(C1, 200)),
    ?assertEqual(undefined, ha_client:recv(C5, 200)),

    ha_client:stop(C1),
    ha_client:stop(C5),
    ok.


%% TODO(murali@): add a test that UID5 unblocks UID1 and receives only the last presence.

