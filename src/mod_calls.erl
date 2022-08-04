%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloApp Inc.
%%% @doc
%%% Audio Video 1v1 calls erlang API.
%%% @end
%%% Created : 11. Oct 2021 4:48 PM
%%%-------------------------------------------------------------------
-module(mod_calls).
-author("nikola").
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("account.hrl").
-include("ha_types.hrl").

%% API
-export([
    get_call_servers/4,
    get_call_config/3,
    start_call/7,
    user_receive_packet/1,
    user_send_packet/1,
    push_message_always_hook/1,
    set_presence_hook/4
]).

%% gen_mod api
-export([start/2, stop/1, mod_options/1, depends/2]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   gen_mod API                                                                              %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(Host, _Opts) ->
    ?INFO("start"),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:add(push_message_always_hook, Host, ?MODULE, push_message_always_hook, 50),
    ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, set_presence_hook, 50),
    ok.

stop(Host) ->
    ?INFO("stop"),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:delete(push_message_always_hook, Host, ?MODULE, push_message_always_hook, 50),
    ejabberd_hooks:delete(set_presence_hook, Host, ?MODULE, set_presence_hook, 50),
    ok.

depends(_Host, _Opts) -> [].

mod_options(_Host) -> [].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   API                                                                                      %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_call_servers(CallId :: binary(), Uid :: uid(), PeerUid :: uid(), CallType :: 'CallType'())
        -> {ok, {list(pb_stun_server()), list(pb_turn_server())}}.
get_call_servers(CallId, Uid, PeerUid, CallType) ->
    % Nothing fency for now.
    stat:count("HA/call", "get_call_servers"),
    mod_call_servers:get_stun_turn_servers(CallId, Uid, PeerUid, CallType).


-spec start_call(CallId :: call_id(), Uid :: uid(), PeerUid :: uid(),
    CallType :: 'CallType'(), Offer :: pb_web_rtc_session_description(),
    RerequestCount :: integer(), Caps :: pb_call_capabilities())
        -> {ok, {list(pb_stun_server()), list(pb_turn_server())}}.
start_call(CallId, Uid, PeerUid, CallType, Offer, RerequestCount, Caps) ->
    % TODO: (nikola): check if we should allow Uid to call Ouid. For now everything is allowed.
    count_start_call(Uid, CallType, RerequestCount),
    {StunServers, TurnServers} = mod_call_servers:get_stun_turn_servers(CallId, Uid, PeerUid, CallType),
    {ok, CallConfig} = get_call_config(Uid, PeerUid, CallType),
    IncomingCallMsg = #pb_incoming_call{
        call_id = CallId,
        call_type = CallType,
        webrtc_offer = Offer,
        stun_servers = StunServers,
        turn_servers = TurnServers,
        timestamp_ms = util:now_ms(),
        server_sent_ts_ms = util:now_ms(),       % time at which the server sent the packet
        call_config = CallConfig,
        call_capabilities = Caps
    },
    MsgId = util_id:new_msg_id(),
    Packet = #pb_msg{
        id = MsgId,
        type = call,
        from_uid = Uid,
        to_uid = PeerUid,
        payload = IncomingCallMsg,
        rerequest_count = RerequestCount
    },

    ejabberd_router:route(Packet),

    {ok, {StunServers, TurnServers}}.

% TODO: (nikola) code is kind of duplicated..
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_incoming_call{call_id = CallId, call_type = CallType} = IncomingCall} = Message, State}) ->
    ?INFO("CallId: ~s incoming FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "incoming_call", 1, [{type, CallType}]),
    Message1 = Message#pb_msg{payload = IncomingCall#pb_incoming_call{server_sent_ts_ms = util:now_ms()}},
    {Message1, State};
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_call_ringing{call_id = CallId}}, _State} = Acc) ->
    ?INFO("CallId: ~s ringing FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_pre_answer_call{call_id = CallId}}, _State} = Acc) ->
    ?INFO("CallId: ~s pre_answer FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_answer_call{call_id = CallId}}, _State} = Acc) ->
    ?INFO("CallId: ~s answer FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_hold_call{call_id = CallId, hold = Hold}}, _State} = Acc) ->
    ?INFO("CallId: ~s hold: ~p FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Hold, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_mute_call{call_id = CallId, media_type = MediaType, muted = Muted}}, _State} = Acc) ->
    ?INFO("CallId: ~s mute: ~p media: ~p FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Muted, MediaType, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_end_call{call_id = CallId, reason = Reason}}, _State} = Acc) ->
    ?INFO("CallId: ~s end_call (~s) FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Reason, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_ice_candidate{call_id = CallId}} = _Msg, _State} = Acc) ->
    ?INFO("CallId: ~s ice_candidate FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_ice_restart_offer{call_id = CallId, idx = Idx}} = _Msg, _State} = Acc) ->
    ?INFO("CallId: ~s ice_restart_offer Idx: ~p FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Idx, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_ice_restart_answer{call_id = CallId, idx = Idx}} = _Msg, _State} = Acc) ->
    ?INFO("CallId: ~s ice_restart_answer Idx: ~p FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Idx, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet(Acc) -> Acc.

user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_call_ringing{call_id = CallId} = Payload} = Msg, State}) ->
    ?INFO("CallId: ~s ringing FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "ringing"),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_call_ringing{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_pre_answer_call{call_id = CallId} = Payload} = Msg, State}) ->
    ?INFO("CallId: ~s pre_answer FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "pre_answer"),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_pre_answer_call{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_answer_call{call_id = CallId} = Payload} = Msg, State}) ->
    ?INFO("CallId: ~s answer FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "answer"),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_answer_call{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_hold_call{call_id = CallId, hold = Hold} = Payload} = Msg, State}) ->
    ?INFO("CallId: ~s hold: ~p FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Hold, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "hold", 1, [{hold, Hold}]),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_hold_call{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_mute_call{call_id = CallId, media_type = MediaType, muted = Muted} = Payload} = Msg, State}) ->
    ?INFO("CallId: ~s mute: ~p media: ~p FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Muted, MediaType, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "mute", 1, [{muted, Muted}, {media_type, MediaType}]),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_mute_call{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_end_call{call_id = CallId, reason = Reason} = Payload} = Msg, State}) ->
    ?INFO("CallId: ~s end_call (~s) FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Reason, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "end_call"),
    stat:count("HA/call", "end_call", 1, [{reason, Reason}]),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_end_call{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_ice_candidate{call_id = CallId}} = _Msg, _State} = Acc) ->
    ?INFO("CallId: ~s ice_candidate FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    Acc;
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_ice_restart_offer{call_id = CallId, idx = Idx}} = _Msg, _State} = Acc) ->
    ?INFO("CallId: ~s ice_restart_offer Idx: ~p FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Idx, FromUid, ToUid, MsgId]),
    Acc;
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_ice_restart_answer{call_id = CallId, idx = Idx}} = _Msg, _State} = Acc) ->
    ?INFO("CallId: ~s ice_restart_answer Idx: ~p FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Idx, FromUid, ToUid, MsgId]),
    Acc;
user_send_packet(Acc) -> Acc.


-spec push_message_always_hook(Packet :: message()) -> ok.
push_message_always_hook(#pb_msg{to_uid = Uid} = Packet) ->
    %% Handle special case of voip messages for ios clients.
    case util:is_voip_incoming_message(Packet) of
        true ->
            %% ios versions upto 14.5 need some special logic here.
            %% we should always send a push in these cases as of now.
            {ok, Account} = model_accounts:get_account(Uid),
            case util_ua:is_ios(Account#account.client_version) of
                true ->
                    case Account#account.os_version of
                        undefined -> push_message(Packet);
                        Version when Version < <<"14.5">> -> push_message(Packet);
                        _ -> ok
                    end;
                false ->
                    %% Ignore for other os.
                    ok
            end;
        false -> ok
    end;
push_message_always_hook(_) -> ok.


-spec set_presence_hook(Uid :: binary(), Server :: binary(), Resource :: binary(), presence()) -> ok.
set_presence_hook(_Uid, _Server, _Resource, _) ->
    ok.


-spec push_message(Packet :: message()) -> ok.
push_message(#pb_msg{to_uid = Uid, id = MsgId} = Packet) ->
    ?INFO("Uid: ~p MsgId: ~p", [Uid, MsgId]),
    ejabberd_sm:push_message(Packet),
    ok.


-spec count_start_call(Uid :: binary(), CallType :: 'CallType'(), RerequestCount :: integer()) -> ok.
count_start_call(Uid, CallType, RerequestCount) ->
    case RerequestCount =:= 0 of
        true ->
            count_user_event(Uid, CallType),
            stat:count("HA/call", "start_call", 1, [{type, CallType}]);
        false ->
            stat:count("HA/call", "rerequest_start_call", 1, [{type, CallType}, {count, RerequestCount}])
    end,
    ok.

count_user_event(Uid, CallType) ->
    case CallType of
        audio -> ha_events:log_user_event(Uid, audio_call_started);
        video -> ha_events:log_user_event(Uid, video_call_started);
        _ -> ok
    end.
    


-spec get_call_config(Uid :: uid(), PeerUid :: uid(), CallType :: 'CallType'())
        -> {ok, pb_call_config()}.
get_call_config(Uid, PeerUid, _CallType) ->
    CallConfig1 = #pb_call_config{
        video_bitrate_max = 1000000,                    %% Android, iOS
        video_width = 1280,                             %% Android, iOS
        video_height = 720,                             %% Android, iOS
        video_fps = 30,                                 %% Android, iOS
        %% -1 means use client default 50 for both clients.
        audio_jitter_buffer_max_packets = -1,           %% Android
        %% default is false
        audio_jitter_buffer_fast_accelerate = false,    %% Android, iOS
        %% default is `all`
        ice_transport_policy = all,                     %% Android, iOS
        ice_restart_delay_ms = 2000,                    %% iOS.
        %% clients could end up opening multiple turn ports - generating a ton of ice candidates
        %% this helps minimize the number of ice candidates for negotiation.
        %% this helps reduce the number of opened ports to 1.
        prune_turn_ports = true,                        %% iOS
        %% webrtc clients by default dont generate the ice candidates until local description is set.
        %% setting a pool size will trigger the client to prefetch ice candidates.
        %% setting it to be 20 to cover ipv4/ipv6, tcp/udp, relay, public / internal ice candidates.
        ice_candidate_pool_size = 20,                   %% iOS
        %% webrtc connection has a backup ip-pair for the rtp connection that it falls back on.
        %% this parameter describes the interval to ping and check the backup connection.
        ice_backup_ping_interval_ms = 1000,             %% iOS
        %% this parameter is the timeout that client uses to determine if the current ice connection is broken.
        ice_connection_timeout_ms = 2000                %% iOS
    },
    {ok, CallConfig2} = get_uid_based_config(Uid, PeerUid, CallConfig1),
    {ok, CallConfig2}.


-spec get_uid_based_config(Uid :: uid(), PeerUid :: uid(), CallConfig :: pb_call_config()) -> {ok, pb_call_config()}.
get_uid_based_config(<<"1000000000648327036">>, _PeerUid, CallConfig) ->
    CallConfig1 = CallConfig#pb_call_config{ ice_transport_policy = relay},
    {ok, CallConfig1};
get_uid_based_config(_Uid, _PeerUid, CallConfig) ->
    {ok, CallConfig}.

