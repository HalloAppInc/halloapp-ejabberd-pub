%%%-------------------------------------------------------------------
%%% @copyright (C) 2022, Halloapp Inc.
%%%-------------------------------------------------------------------
-module(websocket_handler).
-author("vipin").

-include("ha_types.hrl").
-include("logger.hrl").
-include("packets.hrl").
-include("ejabberd_sm.hrl").

%% Websocket callbacks
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

%% API
-export([
    route/1,
    route/2,
    close_current_sessions_static_key/1,
    close_current_sessions_uid/1,
    add_key_to_session/3,  %% for testing
    delete_key_from_session/2  %% for testing
]).


%% TODO(vipin): Reduce logging level once things are working in this file.

init(Req, State) ->
    ?DEBUG("Peer: ~p, Req: ~p", [cowboy_req:peer(Req), Req]),
    ForwardIP = cowboy_req:header(<<"x-forwarded-for">>, Req),
    {cowboy_websocket, Req, State#{peer => cowboy_req:peer(Req), forward_ip => ForwardIP},
        #{idle_timeout => 30000}}.

websocket_init(#{peer := Peer, forward_ip := ForwardIP} = State) ->
    ?INFO("Opened websocket connection, Peer: ~p, Forward ip: ~p", [Peer, ForwardIP]),
    erlang:start_timer(5000, self(), pid_to_list(self())),
    {[], State}.

websocket_handle({text, Msg}, State) ->
    ?INFO("Msg: ~p", [Msg]),
    {[{text, << "Text packet recvd ", Msg/binary >>}], State};
websocket_handle({binary, BinMsg}, State) ->
    ?DEBUG("Bin msg: ~p", [base64:encode(BinMsg)]),
    case enif_protobuf:decode(BinMsg, pb_packet) of
        {error, _} ->
            stat:count("HA/websocket", "recv_packet", 1, [{result, error}]),
            ?ERROR("Failed to decode packet ~p", [BinMsg]),
            {stop, State};
        #pb_packet{} = Pkt ->
            stat:count("HA/websocket", "recv_packet", 1, [{result, ok}]),
            {Pkt2, State2} = process_incoming_packet(Pkt#pb_packet.stanza, State),
            Pkt3 = #pb_packet{stanza = Pkt2},
            case enif_protobuf:encode(Pkt3) of
                {error, _Reason} ->
                    ?ERROR("Failed to encode packet ~p", [Pkt3]),
                    stat:count("HA/websocket", "send_packet", 1, [{result, error}]),
                    {stop, State2};
                BinPkt ->
                    stat:count("HA/websocket", "send_packet", 1, [{result, ok}]),
                    {[{binary, BinPkt}], State2}
            end
    end;
websocket_handle(_Data, State) ->
    {[], State}.

websocket_info(replaced, State) ->
    ?INFO("Replaced info", []),
    {stop, State};
websocket_info({timeout, _Ref, Msg}, State) ->
    ?INFO("Timeout info, msg: ~p, state: ~p", [Msg, State]),
    erlang:start_timer(5000, self(), pid_to_list(self())),
    {[{text, Msg}], State};
websocket_info({route, #pb_msg{payload = #pb_web_stanza{}} = Msg}, State) ->
    ?DEBUG("Sending msg: ~p, state: ~p", [Msg, State]),
    Pkt = #pb_packet{stanza = Msg},
    case enif_protobuf:encode(Pkt) of
        {error, _Reason} ->
            ?ERROR("Failed to encode packet ~p", [Pkt]),
            stat:count("HA/websocket", "send_packet", 1, [{result, error}]),
            {stop, State};
        BinPkt ->
            stat:count("HA/websocket", "send_packet", 1, [{result, ok}]),
            {[{binary, BinPkt}], State}
    end;
websocket_info({route, Msg}, State) ->
    ?ERROR("Dropping msg: ~p", [Msg]),
    {[], State};
websocket_info(_Info, State) ->
    {[], State}.

terminate(Reason, _Req, #{static_key := StaticKey, sid := Sid} = _State) ->
    ?INFO("Reason: ~p", [Reason]),
    delete_key_from_session(StaticKey, Sid);
terminate(Reason, _Req, _State) ->
    ?INFO("Reason: ~p", [Reason]).

-spec route(#pb_msg{}) -> any().
route(#pb_msg{payload = #pb_web_stanza{static_key = StaticKey}} = Packet) ->
    case model_session:get_static_key_sessions(StaticKey) of
        [] ->
            ?INFO("No active websocket session for: ~p, dropping packet",
                [base64:encode(StaticKey)]),
            ok;
        Ss ->
            Session = lists:max(Ss),
            Pid = element(2, Session#session.sid),
            MsgId = pb:get_id(Packet),
            LUser = pb:get_to(Packet),
            ?INFO("route To: ~s -> pid ~p MsgId: ~s", [LUser, Pid, MsgId]),
            % NOTE: message will be lost if the dest PID dies while routing
            route(Pid, {route, Packet})
    end;
route(_Packet) ->
    ok.

-spec route(pid(), term()) -> boolean().
route(Pid, Term) when is_pid(Pid) ->
    ?DEBUG("Pid: ~p, Term: ~p", [Pid, Term]),
    ejabberd_cluster:send(Pid, Term).

%%====================================================================
%% Internal functions
%%====================================================================

process_incoming_packet(Pkt, State) ->
    case Pkt of
        #pb_iq{} -> process_iq(Pkt, State);
        #pb_msg{} -> process_msg(Pkt, State);
        _ -> {#pb_ha_error{reason = <<"invalid_packet">>}, State}
    end.

%% TODO(vipin): Figure out a way to not return State.
process_iq(#pb_iq{type = get,
    payload = #pb_web_client_info{action = is_key_authenticated, static_key = StaticKey}} = IQ,
    State) ->
    stat:count("HA/websocket", "is_key_authenticated", 1),
    case model_auth:get_static_key_uid(StaticKey) of
        {ok, undefined} ->
            stat:count("HA/websocket", "is_key_authenticated", 1, [{result, error}]),
            ?INFO("StaticKey: ~p not authenticated", [base64:encode(StaticKey)]),
            {pb:make_iq_result(IQ, #pb_web_client_info{result = not_authenticated}), State};
        {ok, Uid} ->
            stat:count("HA/websocket", "is_key_authenticated", 1, [{result, ok}]),
            ?INFO("StaticKey: ~p authenticated, UId: ~p", [base64:encode(StaticKey), Uid]),
            {pb:make_iq_result(IQ, #pb_web_client_info{result = authenticated}), State}
    end;

process_iq(#pb_iq{type = set,
    payload = #pb_web_client_info{action = add_key, static_key = StaticKey}} = IQ,
    #{peer := Peer, forward_ip := ForwardIP} = State) ->
    Sid = ejabberd_sm:make_sid(),
    IP = case ForwardIP of
        undefined ->
            {IP1, _} = Peer,
            IP1;
        _ -> ForwardIP
    end,
    State2 = State#{static_key => StaticKey, sid => Sid},
    case add_key_to_session(StaticKey, Sid, IP) of
        ok ->
            {pb:make_iq_result(IQ, #pb_web_client_info{result = ok}), State2};
        {error, Reason} ->
            ?ERROR("Add static key error: ~p", [Reason]),
            {pb:make_error(IQ, util:err(Reason)), State2}
    end;
process_iq(IQ, State) ->
    {IQ, State}.

process_msg(#pb_msg{id = MsgId, payload = #pb_web_stanza{}} = Msg, State) ->
    %% TODO(vipin): Return error if Msg's static key does not match
    %% static key present in the State.
    StaticKey = Msg#pb_msg.payload#pb_web_stanza.static_key,
    case model_auth:get_static_key_uid(StaticKey) of
        {ok, undefined} ->
            stat:count("HA/websocket", "process_msg", 1, [{result, error}]),
            ?INFO("Static Key: ~p not authenticated", [base64:encode(StaticKey)]),
            {pb:make_error(Msg, util:err(not_authenticated)), State};
        {ok, Uid} ->
            %% TODO(vipin): We can cache the Uid in the State.
            stat:count("HA/websocket", "process_msg", 1, [{result, ok}]),
            ?INFO("Processed Msg for static key: ~p", [base64:encode(StaticKey)]),
            ejabberd_router:route(Msg#pb_msg{to_uid = Uid}),
            {#pb_ack{id = MsgId, to_uid = Uid, timestamp = util:now()}, State}
    end;

process_msg(_Msg, State) ->
    ?ERROR("Invalid packet received", []),
    {#pb_ha_error{reason = <<"invalid_packet">>}, State}.

-spec add_key_to_session(StaticKey :: binary(), Sid :: term(), IP :: binary()) -> ok.
add_key_to_session(StaticKey, Sid, IP) ->
    close_current_sessions_static_key(StaticKey),
    ?INFO("Static Key: ~p, sid: ~p, ip: ~p", [base64:encode(StaticKey), Sid, IP]),
    %% TODO(vipin): Add uid, sid, resource, mode and info -- which includes clientVersion/ip.
    %% TODO(vipin): Add hooks.
    Session = #session{sid = Sid, info = [{ip, IP}]},
    ok = model_session:set_static_key_session(StaticKey, Session),
    ok.

-spec close_current_sessions_static_key(StaticKey :: binary()) -> ok.
close_current_sessions_static_key(StaticKey) ->
    {ok, Uid} = model_auth:get_static_key_uid(StaticKey),
    close_current_sessions_uid(Uid),
    close_all_sessions(StaticKey).

-spec close_current_sessions_uid(Uid :: binary()) -> ok.
close_current_sessions_uid(Uid) ->
    case Uid of
        undefined -> ok;
        _ ->
            {ok, StaticKeysList} = model_auth:get_static_keys(Uid),
            lists:foreach(
                fun(SKey) ->
                    close_all_sessions(SKey)
                end, StaticKeysList)
    end.

close_all_sessions(StaticKey) ->
    SessionsList = model_session:get_static_key_sessions(StaticKey), 
    ?DEBUG("Closing all sessions for Key: ~p, List: ~p", [StaticKey, SessionsList]),
    lists:foreach(
        fun(Session) ->
            #session{sid = Sid} = Session,
            {_, Pid} = Sid,
            route(Pid, replaced),
            %% Delete the Sid just in case Pid is not alive.
            delete_key_from_session(StaticKey, Sid)
        end, SessionsList).
 
 -spec delete_key_from_session(StaticKey :: binary(), Sid :: binary()) -> ok.
delete_key_from_session(StaticKey, Sid) ->
    ?INFO("Static Key: ~s, sid: ~p", [base64:encode(StaticKey), Sid]),
    Session = #session{sid = Sid},
    ok = model_session:del_static_key_session(StaticKey, Session),
    ok.

