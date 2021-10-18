%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloApp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 12. Oct 2021 11:02 AM
%%%-------------------------------------------------------------------
-module(call_tests).
-author("nikola").

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").

group() ->
    {call, [sequence], [
        call_dummy_test,
        call_start_call_test,
        call_get_call_servers_test,
        call_call_ringing_test,
        call_answer_call_test,
        call_end_call_test
    ]}.

dummy_test(_Conf) ->
    ok.

start_call_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),

    CallId = util_id:new_msg_id(),
    Offer = #pb_web_rtc_session_description{
        enc_payload = util:random_str(100),
        public_key = util:random_str(10),
        one_time_pre_key_id = 1
    },
    Payload = #pb_start_call{
        call_id = CallId,
        call_type = audio,
        peer_uid = ?UID2,
        webrtc_offer = Offer
    },

    Result = ha_client:send_iq(C1, set, Payload),

    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = ResultPayload
        }
    } = Result,

    {StunServers, TurnServers} = mod_calls:get_stun_turn_servers(),

    #pb_start_call_result{
        result = ok,
        stun_servers = StunServers,
        turn_servers = TurnServers
    } = ResultPayload,


    IncomingCallMsg = ha_client:wait_for(C2,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{payload = #pb_incoming_call{call_id = CallId}}} -> true;
                _Any -> false
            end
        end),

    #pb_packet{
        stanza = #pb_msg{
            payload = IncomingCall
        }
    } = IncomingCallMsg,

    #pb_incoming_call{
        call_id = CallId,
        call_type = audio,
        webrtc_offer = Offer,
        stun_servers = [StunServer],
        turn_servers = [TurnServer]
    } = IncomingCall,

    ok = ha_client:stop(C1),
    ok = ha_client:stop(C2),
    ok.

get_call_servers_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),

    CallId = util_id:new_msg_id(),
    Payload = #pb_get_call_servers{
        call_id = CallId,
        call_type = audio,
        peer_uid = ?UID2
    },

    Result = ha_client:send_iq(C1, set, Payload),

    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = ResultPayload
        }
    } = Result,

    {StunServers, TurnServers} = mod_calls:get_stun_turn_servers(),

    #pb_get_call_servers_result{
        result = ok,
        stun_servers = StunServers,
        turn_servers = TurnServers
    } = ResultPayload,

    ok = ha_client:stop(C1),
    ok.

call_ringing_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),

    CallId = util_id:new_msg_id(),
    Payload = #pb_call_ringing{
        call_id = CallId
    },

    MsgId = util_id:new_msg_id(),
    ok = ha_client:send_msg(C2, MsgId, call, ?UID1, Payload),

    Msg = ha_client:wait_for_msg(C1, pb_call_ringing),

    #pb_packet{
        stanza = #pb_msg{
            payload = #pb_call_ringing{
                call_id = CallId,
                timestamp_ms = Ts
            }
        }
    } = Msg,

    ok = ha_client:stop(C1),
    ok = ha_client:stop(C2),
    ok.

answer_call_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),

    CallId = util_id:new_msg_id(),
    Answer = #pb_web_rtc_session_description{
        enc_payload = util:random_str(100),
        public_key = util:random_str(10),
        one_time_pre_key_id = 1
    },
    Payload = #pb_answer_call{
        call_id = CallId,
        webrtc_answer = Answer
    },

    MsgId = util_id:new_msg_id(),
    ok = ha_client:send_msg(C2, MsgId, call, ?UID1, Payload),

    Msg = ha_client:wait_for_msg(C1, pb_answer_call),

    #pb_packet{
        stanza = #pb_msg{
            payload = #pb_answer_call{
                call_id = CallId,
                webrtc_answer = Answer,
                timestamp_ms = Ts
            }
        }
    } = Msg,

    ok = ha_client:stop(C1),
    ok = ha_client:stop(C2),
    ok.


end_call_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),

    CallId = util_id:new_msg_id(),
    Payload = #pb_end_call{
        call_id = CallId,
        reason = reject
    },

    MsgId = util_id:new_msg_id(),
    ok = ha_client:send_msg(C2, MsgId, call, ?UID1, Payload),

    Msg = ha_client:wait_for_msg(C1, pb_end_call),

    #pb_packet{
        stanza = #pb_msg{
            payload = #pb_end_call{
                call_id = CallId,
                reason = reject,
                timestamp_ms = Ts
            }
        }
    } = Msg,

    ok = ha_client:stop(C1),
    ok = ha_client:stop(C2),
    ok.
