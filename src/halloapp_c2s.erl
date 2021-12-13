%%%-------------------------------------------------------------------
%%% File    : halloapp_c2s.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-------------------------------------------------------------------

-module(halloapp_c2s).
-author('yexin').
-author('murali').
-behaviour(halloapp_stream_in).
-behaviour(ejabberd_listener).


%% ejabberd_listener callbacks
-export([start/3, start_link/3, accept/1, listen_opt_type/1, listen_options/0]).

%% halloapp_stream_in callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([
    tls_options/1,
    noise_options/1,
    bind/2,
    check_password_fun/2,
    get_client_version_ttl/2,
    handle_stream_end/2,
    handle_authenticated_packet/2,
    handle_auth_result/4,
    handle_send/4,
    handle_recv/3,
    upgrade_packet/1
]).

%% Hooks
-export([
    handle_unexpected_cast/2,
    handle_unexpected_call/3,
    process_auth_result/3,
    process_closed/2,
    process_terminated/2,
    process_info/2
]).

%% API
-export([
    open_session/1,
    call/3,
    cast/2,
    send/2,
    close/1,
    close/2,
    stop/1,
    reply/2,
    set_timeout/2,
    route/2,
    format_reason/2,
    host_up/1,
    host_down/1,
    bounce_message_queue/2
]).

-include("xmpp.hrl").
-include("packets.hrl").
-include("logger.hrl").
-include("translate.hrl").
-include("ha_types.hrl").
-include_lib("stdlib/include/assert.hrl").

-type state() :: halloapp_stream_in:state().
-export_type([state/0]).

-define(BUGGY_ANDROID_VERSION, <<"HalloApp/Android0.147">>).

%%%===================================================================
%%% ejabberd_listener API
%%%===================================================================


start(SockMod, Socket, Opts) ->
    halloapp_stream_in:start(?MODULE, [{SockMod, Socket}, Opts],
            ejabberd_config:fsm_limit_opts(Opts)).


start_link(SockMod, Socket, Opts) ->
    halloapp_stream_in:start_link(?MODULE, [{SockMod, Socket}, Opts],
            ejabberd_config:fsm_limit_opts(Opts)).


accept(Ref) ->
    halloapp_stream_in:accept(Ref).


%%%===================================================================
%%% Common API
%%%===================================================================


-spec call(pid(), term(), non_neg_integer() | infinity) -> term().
call(Ref, Msg, Timeout) ->
    halloapp_stream_in:call(Ref, Msg, Timeout).


-spec cast(pid(), term()) -> ok.
cast(Ref, Msg) ->
    halloapp_stream_in:cast(Ref, Msg).


reply(Ref, Reply) ->
    halloapp_stream_in:reply(Ref, Reply).


-spec close(pid()) -> ok;
       (state()) -> state().
close(Ref) ->
    halloapp_stream_in:close(Ref).


-spec close(pid(), atom()) -> ok.
close(Ref, Reason) ->
    halloapp_stream_in:close(Ref, Reason).


-spec stop(pid()) -> ok;
      (state()) -> no_return().
stop(Ref) ->
    halloapp_stream_in:stop(Ref).


-spec send(pid(), xmpp_element()) -> ok;
      (state(), xmpp_element()) -> state().
send(Pid, Pkt) when is_pid(Pid) ->
    halloapp_stream_in:send(Pid, Pkt);
send(#{lserver := LServer} = State, Pkt) ->
    case ejabberd_hooks:run_fold(c2s_filter_send, LServer, {Pkt, State}, []) of
        {drop, State1} -> State1;
        {Pkt1, State1} -> halloapp_stream_in:send(State1, Pkt1)
    end.


-spec send_error(state(), binary()) -> state().
send_error(State, Err) ->
    halloapp_stream_in:send_error(State, Err).


-spec route(pid(), term()) -> boolean().
route(Pid, Term) when is_pid(Pid) ->
    ejabberd_cluster:send(Pid, Term);
route(#{owner := Owner} = State, Term) when Owner =:= self() ->
    halloapp_c2s:process_info(State, Term).


-spec set_timeout(state(), timeout()) -> state().
set_timeout(State, Timeout) ->
    halloapp_stream_in:set_timeout(State, Timeout).


-spec host_up(binary()) -> ok.
host_up(Host) ->
    ejabberd_hooks:add(pb_c2s_closed, Host, ?MODULE, process_closed, 100),
    ejabberd_hooks:add(pb_c2s_terminated, Host, ?MODULE, process_terminated, 100),
    ejabberd_hooks:add(pb_c2s_handle_info, Host, ?MODULE, process_info, 100),
    ejabberd_hooks:add(pb_c2s_auth_result, Host, ?MODULE, process_auth_result, 100),
    ejabberd_hooks:add(pb_c2s_handle_cast, Host, ?MODULE, handle_unexpected_cast, 100),
    ejabberd_hooks:add(pb_c2s_handle_call, Host, ?MODULE, handle_unexpected_call, 100).


-spec host_down(binary()) -> ok.
host_down(Host) ->
    ejabberd_hooks:delete(pb_c2s_closed, Host, ?MODULE, process_closed, 100),
    ejabberd_hooks:delete(pb_c2s_terminated, Host, ?MODULE, process_terminated, 100),
    ejabberd_hooks:delete(pb_c2s_handle_info, Host, ?MODULE, process_info, 100),
    ejabberd_hooks:delete(pb_c2s_auth_result, Host, ?MODULE, process_auth_result, 100),
    ejabberd_hooks:delete(pb_c2s_handle_cast, Host, ?MODULE, handle_unexpected_cast, 100),
    ejabberd_hooks:delete(pb_c2s_handle_call, Host, ?MODULE, handle_unexpected_call, 100).


-spec open_session(state()) -> {ok, state()} | state().
open_session(#{user := Uid, server := Server, resource := Resource,
        sid := SID, client_version := ClientVersion, ip := IP, mode := Mode} = State) ->
    JID = jid:make(Uid, Server, Resource),
    State1 = change_shaper(State),
    Conn = get_conn_type(State1),
    State2 = State1#{conn => Conn, resource => Resource, jid => JID},
    Priority = 0,
    Info = [{ip, IP}, {conn, Conn}, {client_version, ClientVersion}],
    SocketType = maps:get(socket_type, State),
    Protocol = util:get_protocol(IP),
    stat:count("HA/connections", "ip", 1, [{protocol, Protocol}]),
    stat:count("HA/connections", "socket", 1, [{socket_type, SocketType}]),
    check_first_login(Uid, Server),
    ejabberd_sm:open_session(SID, Uid, Server, Resource, Priority, Mode, Info),
    halloapp_stream_in:establish(State2).


-spec check_first_login(Uid :: binary(), Server :: binary()) -> ok.
check_first_login(Uid, Server) ->
    case model_auth:set_login(Uid) of
        true ->
            ?INFO("Uid: ~s, on_user_first_login", [Uid]),
            ejabberd_hooks:run(on_user_first_login, Server, [Uid, Server]);
        false -> ok
    end,
    ok.


%%%===================================================================
%%% Hooks
%%%===================================================================

%% all messages going to the user will go through this path.
%% now if we add a new field and update only one server:
%% then other servers cant encode this message because the record has a new field. 
%% similarly the updated server cant encode it because it is missing a field.
%% so this function helps us transform packets across servers.
upgrade_packet(#pb_msg{payload = MsgPayload} = Msg) ->
    PayloadType = util:get_payload_type(Msg),
    case PayloadType of
        pb_group_stanza ->
            NewMsgPayload = upgrade_group_stanza(MsgPayload),
            Msg#pb_msg{payload = NewMsgPayload};

        pb_rerequest ->
            NewMsgPayload = upgrade_rerequest_stanza(MsgPayload),
            Msg#pb_msg{payload = NewMsgPayload};

        _ -> Msg

    end;
upgrade_packet(Packet) -> Packet.

upgrade_group_stanza(GroupStanza) ->
    case GroupStanza of
        #pb_group_stanza{} -> GroupStanza;
        {pb_group_stanza, Action, Gid, Name, AvatarId, SenderUid, SenderName, Members, Background, AudienceHash, Description} ->
            #pb_group_stanza{
                action = Action,
                gid = Gid,
                name = Name,
                avatar_id = AvatarId,
                sender_uid = SenderUid,
                sender_name = SenderName,
                members = Members,
                background = Background,
                audience_hash = AudienceHash,
                description = Description
            };
        {pb_group_stanza, Action, Gid, Name, AvatarId, SenderUid, SenderName, Members, Background, AudienceHash, Description, _HistoryResend} ->
            #pb_group_stanza{
                action = Action,
                gid = Gid,
                name = Name,
                avatar_id = AvatarId,
                sender_uid = SenderUid,
                sender_name = SenderName,
                members = Members,
                background = Background,
                audience_hash = AudienceHash,
                description = Description
            }
    end.

upgrade_rerequest_stanza(RerequestStanza) ->
    case RerequestStanza of
        #pb_rerequest{} -> RerequestStanza;
        {pb_rerequest, Id, IdentityKey, SignedPreKeyId, OneTimeKeyId, SessionKey, EphemeralKey} ->
            #pb_rerequest{
                id = Id,
                identity_key = IdentityKey,
                signed_pre_key_id = SignedPreKeyId,
                one_time_pre_key_id = OneTimeKeyId,
                session_setup_ephemeral_key = SessionKey,
                message_ephemeral_key = EphemeralKey
            };
        {pb_rerequest, Id, IdentityKey, SignedPreKeyId, OneTimeKeyId, SessionKey, EphemeralKey, _ContentType} ->
            #pb_rerequest{
                id = Id,
                identity_key = IdentityKey,
                signed_pre_key_id = SignedPreKeyId,
                one_time_pre_key_id = OneTimeKeyId,
                session_setup_ephemeral_key = SessionKey,
                message_ephemeral_key = EphemeralKey
            }
    end.


process_info(#{lserver := LServer} = State, {route, Packet}) ->
    NewPacket = upgrade_packet(Packet),
    % TODO: Remove enif_protobuf:encode(...) after upgrade is done.
    case enif_protobuf:encode(NewPacket) of
        {error, Reason} ->
            ?ERROR("Error encoding packet: ~p, reason: ~p, Orig: ~p", [NewPacket, Reason, Packet]);
        _ ->
            ok
    end,
    case verify_incoming_packet(State, NewPacket) of
        allow ->
            %% TODO(murali@): remove temp counts after clients transition.
            stat:count("HA/user_receive_packet", "protobuf"),
            {Packet1, State1} = ejabberd_hooks:run_fold(
                    user_receive_packet, LServer, {NewPacket, State}, []),
            case Packet1 of
                drop -> State1;
                _ -> send(State1, Packet1)
            end;
        deny -> State
    end;

process_info(State, Info) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    State.


handle_unexpected_call(State, From, Msg) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Msg]),
    State.


handle_unexpected_cast(State, Msg) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    State.


-spec process_auth_result(State :: state(), true | {false, Reason :: atom()},
        User :: uid()) -> state().
process_auth_result(#{socket := Socket, ip := IP} = State, true, User) ->
    ?INFO("(~ts) Accepted c2s authentication for ~ts from ~ts",
        [halloapp_socket:pp(Socket), User,
            ejabberd_config:may_hide_data(misc:ip_to_list(IP))]),
    stat:count("HA/auth", "success", 1),
    State;
process_auth_result(#{socket := Socket, ip := IP, lserver := _LServer} = State,
        {false, Reason}, User) ->
    ClientVersion = maps:get(client_version, State, undefined),
    Format = "(~ts) Failed c2s authentication ~ts from ~ts: v:~ts Reason: ~ts",
    Args = [halloapp_socket:pp(Socket), User,
        ejabberd_config:may_hide_data(misc:ip_to_list(IP)), ClientVersion, Reason],
    case {Reason, ClientVersion} of
        {_, undefined} ->
            ?WARNING(Format, Args);
        {invalid_client_version, _} ->
            % Android before v0.147 would not disconnect and stop connecting
            IsOldAndroid = util_ua:is_android(ClientVersion) andalso
                    util_ua:is_version_less_than(ClientVersion, ?BUGGY_ANDROID_VERSION),
            case IsOldAndroid of
                true -> ?INFO(Format, Args);
                false -> ?WARNING(Format, Args)
            end;
        _ ->
            ?WARNING(Format, Args)
    end,
    stat:count("HA/auth", "failure", 1, [{reason, Reason}]),
    State.


process_closed(State, Reason) ->
    stop(State#{stop_reason => Reason}).


%% TODO (murali@): Fix reason to be an atom and cleanup.
process_terminated(#{sid := SID, socket := Socket, mode := Mode,
        jid := JID, user := Uid, server := Server, resource := Resource} = State,
        Reason) ->
    Status = format_reason(State, Reason),
    ?INFO("(~ts) Closing c2s session for ~ts: ~ts",
            [halloapp_socket:pp(Socket), Uid, Status]),
    ejabberd_sm:close_session(SID, Uid, Server, Resource),
    case maps:is_key(pres_last, State) of
        true ->
            ejabberd_hooks:run(unset_presence_hook, Server, [Uid, Mode, Resource, Reason]);
        false ->
            ok
    end,
    State1 = ejabberd_hooks:run_fold(c2s_session_closed, Server, State, []),
    bounce_message_queue(SID, JID),
    State1;
process_terminated(#{socket := Socket, stop_reason := {tls, _}} = State, Reason) ->
    ?WARNING("(~ts) Failed to secure c2s connection: ~ts",
            [halloapp_socket:pp(Socket), format_reason(State, Reason)]),
    State;
process_terminated(State, _Reason) ->
    State.


%%%===================================================================
%%% halloapp_stream_in callbacks
%%%===================================================================


tls_options(#{tls_options := DefaultOpts}) ->
    DefaultOpts.

noise_options(#{lserver := _LServer, noise_options := DefaultOpts}) ->
    DefaultOpts.


check_password_fun(_Mech, #{lserver := _LServer}) ->
    fun(U, _AuthzId, P) ->
        ejabberd_auth:check_password(U, P)
    end.

% TODO: make those constants
bind(R, State) when R =/= <<"android">>, R =/= <<"iphone">> ->
    {error, {invalid_resource, R}, State};
bind(R, #{user := U, server := S, access := Access,
        lserver := LServer, socket := Socket,
        ip := IP} = State) ->
    case resource_conflict_action(U, S, R) of
        closenew ->
            {error, <<"resource_conflict">>, State};
        {accept_resource, Resource} ->
            JID = jid:make(U, S, Resource),
            case acl:match_rule(LServer, Access,
                    #{usr => jid:split(JID), ip => IP}) of
                allow ->
                    State1 = open_session(State#{resource => Resource,
                                 sid => ejabberd_sm:make_sid()}),
                    State2 = ejabberd_hooks:run_fold(
                           c2s_session_opened, LServer, State1, []),
                    ?INFO("(~ts) Opened c2s session for ~ts",
                          [halloapp_socket:pp(Socket), jid:encode(JID)]),
                    {ok, State2};
                deny ->
                    ejabberd_hooks:run(forbidden_session_hook, LServer, [JID]),
                    ?WARNING("(~ts) Forbidden c2s session for ~ts",
                         [halloapp_socket:pp(Socket), jid:encode(JID)]),
                    {error, <<"denied_Access">>, State}
            end
    end.


get_client_version_ttl(ClientVersion, _State) ->
    mod_client_version:get_version_ttl(ClientVersion).


handle_stream_end(Reason, #{lserver := LServer} = State) ->
    State1 = State#{stop_reason => Reason},
    ejabberd_hooks:run_fold(pb_c2s_closed, LServer, State1, [Reason]).

handle_auth_result(Uid, Result, _PBAuthResult, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_auth_result, LServer, State, [Result, Uid]).

%% TODO(murali@): fix this hook - need not be called for auth request.
handle_authenticated_packet(Pkt, #{lserver := LServer} = State) when is_record(Pkt, pb_auth_request) ->
    ejabberd_hooks:run_fold(c2s_authenticated_packet, LServer, State, [Pkt]);
handle_authenticated_packet(Pkt1, #{lserver := LServer, jid := JID} = State) ->
    State1 = ejabberd_hooks:run_fold(c2s_authenticated_packet,
                     LServer, State, [Pkt1]),
    #jid{luser = _LUser} = JID,
    %% TODO(murali@): remove temp counts after clients transition.
    stat:count("HA/user_send_packet", "protobuf"),
    {Pkt2, State2} = ejabberd_hooks:run_fold(
               user_send_packet, LServer, {Pkt1, State1}, []),
    case Pkt2 of
        drop -> State2;
        #pb_iq{} -> process_iq_out(State2, Pkt2);
        #pb_ack{} -> process_ack_out(State2, Pkt2);
        #pb_chat_state{} -> check_privacy_then_route(State2, Pkt2);
        #pb_msg{} -> check_privacy_then_route(State2, Pkt2);
        #pb_presence{} -> check_privacy_then_route(State2, Pkt2)
    end.


handle_recv(BinPkt, Pkt, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_handle_recv, LServer, State, [BinPkt, Pkt]).


handle_send(BinPkt, Pkt, Result, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_handle_send, LServer, State, [BinPkt, Pkt, Result]).


init([State, Opts]) ->
    Access = proplists:get_value(access, Opts, all),
    Shaper = proplists:get_value(shaper, Opts, none),
    Crypto = proplists:get_value(crypto, Opts, tls),
    State1 = State#{
        lang => ejabberd_option:language(),
        server => ejabberd_config:get_myname(),
        lserver => ejabberd_config:get_myname(),
        access => Access,
        shaper => Shaper,
        crypto => Crypto
    },
    State2 = case Crypto of
        none -> State1;
        tls ->
            TLSOpts1 = lists:filter(
                fun({certfile, _}) -> true;
                    (_) -> false
                end, Opts),
            State1#{tls_options => TLSOpts1};
        noise ->
            {ServerKeypair, Certificate} = util:get_noise_key_material(),
            NoiseOpts = [{noise_static_key, ServerKeypair},
                         {noise_server_certificate, Certificate}],
            State1#{noise_options => NoiseOpts}
    end,
    Timeout = ejabberd_option:negotiation_timeout(),
    State3 = halloapp_stream_in:set_timeout(State2, Timeout),
    ejabberd_hooks:run_fold(c2s_init, {ok, State3}, [Opts]).


handle_call(Request, From, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_handle_call, LServer, State, [Request, From]).


handle_cast(Msg, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_handle_cast, LServer, State, [Msg]).


handle_info(replaced, State) ->
    send_error(State, session_replaced);
handle_info(kick, State) ->
    send_error(State, session_kicked);
handle_info({exit, Reason}, #{user := User} = State) ->
    ?ERROR("Uid: ~s, session exit reason: ~p", [User, Reason]),
    send_error(State, server_error);
handle_info(activate_session, #{user := Uid, mode := active} = State) ->
    ?WARNING("Uid: ~s, mode is already active in c2s_state", [Uid]),
    State;
handle_info(activate_session, #{user := Uid, server := Server, mode := passive, sid := SID} = State) ->
    ?INFO("Uid: ~s, pid: ~p, Updating mode from passive to active in c2s_state", [Uid, self()]),
    State1 = State#{mode => active},
    State2 = ejabberd_hooks:run_fold(user_session_activated, Server, State1, [Uid, SID]),
    State2;
handle_info({offline_queue_check, LastMsgOrderId, RetryCount, LeftOverMsgIds},
        #{user := Uid, lserver := Server} = State) ->
    ?INFO("Uid: ~s, offline_queue_check, LastMsgOrderId: ~p, RetryCount: ~p, LeftOverMsgIds: ~p",
        [Uid, LastMsgOrderId, RetryCount, LeftOverMsgIds]),
    ejabberd_hooks:run_fold(offline_queue_check, Server, State,
        [Uid, LastMsgOrderId, RetryCount, LeftOverMsgIds]);
handle_info(Info, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_handle_info, LServer, State, [Info]).


terminate(Reason, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_terminated, LServer, State, [Reason]).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================


%% TODO(murali@): move the presence-filter logic to mod_presence or something like that.
-spec process_presence_out(state(), presence()) -> state().
process_presence_out(#{user := User, server := Server} = State,
        #pb_presence{type = Type} = Presence) when Type == subscribe; Type == unsubscribe ->
    %% We run the presence_subs_hook hook,
    %% since these presence stanzas are about updating user's activity status.
    ejabberd_hooks:run(presence_subs_hook, Server, [User, Server, Presence]),
    State;

process_presence_out(#{sid := _SID, user := Uid, lserver := Server, resource := Resource} = State,
        #pb_presence{type = Type} = Presence) when Type == available; Type == away ->
    ?INFO("Uid: ~p, Resource: ~p, Type: ~p", [Uid, Resource, Type]),
    %% We run the set_presence_hook,
    %% since these presence stanzas are about updating user's activity status.
    ejabberd_hooks:run(set_presence_hook, Server, [Uid, Server, Resource, Presence]),
    State#{pres_last => Presence, presence => Type, pres_timestamp_ms => util:now_ms()};

process_presence_out(State, _Pres) ->
    %% We dont expect this to happen.
    ?ERROR("Invalid presence stanza: ~p, state: ~p", [_Pres, State]),
    State.


process_iq_out(#{user := _Uid, lserver := _Server} = State, #pb_iq{to_uid = ToUid} = Pkt) ->
    %% TODO(murali@): move this into a common iq handler.
    case ejabberd_iq:dispatch(Pkt) of
        %% If the Pkt was a response to an iq request by the server.
        true -> State;
        false ->
            %% If the Pkt is a new request from the client.
            case ToUid =:= <<>> of
                true -> gen_iq_handler:handle(State, Pkt);
                false ->
                    ?ERROR("Invalid packet received: ~p", [Pkt]),
                    State
            end
    end.


process_ack_out(#{user := _Uid, lserver := Server} = State, #pb_ack{} = Pkt) ->
    %% We run the user_send_ack hook for the offline module to act on it.
    ejabberd_hooks:run_fold(user_send_ack, Server, State, [Pkt]).


process_chatstate_out(#{user := _Uid, lserver := Server} = State, #pb_chat_state{} = Pkt) ->
    %% We run the user_send_chatstate hook for the chat_state module to act on it.
    ejabberd_hooks:run_fold(user_send_chatstate, Server, State, [Pkt]).


-spec check_privacy_then_route(state(), stanza()) -> state().
check_privacy_then_route(State, Pkt)
        when is_record(Pkt, pb_presence); is_record(Pkt, message);
        is_record(Pkt, pb_msg); is_record(Pkt, pb_chat_state) ->
    case privacy_check_packet(State, Pkt, out) of
        deny ->
            ?INFO("failed_privacy_rules, packet received: ~p", [Pkt]),
            State;
        allow ->
            %% Now route packets properly.
            %% Think about the way we are routing presence stanzas.
            case Pkt of
                #pb_presence{} -> process_presence_out(State, Pkt);
                #pb_chat_state{} -> process_chatstate_out(State, Pkt);
                #pb_msg{} ->
                    ejabberd_router:route(Pkt),
                    State
            end
    end.


-spec verify_incoming_packet(state(), stanza()) -> allow | deny.
verify_incoming_packet(State, Pkt) ->
    case verify_incoming_packet_to(State, Pkt) of
        allow ->
            privacy_check_packet_in(State, Pkt);
        deny -> deny
    end.


-spec verify_incoming_packet_to(State :: state(), Pkt :: stanza()) -> allow | deny.
verify_incoming_packet_to(#{user := LUser, stream_state := StreamState} = State, Pkt) ->
    ToUid = pb:get_to(Pkt),
    case StreamState of
        established ->
            case LUser =/= ToUid of
                true ->
                    ?ERROR("PANIC received packet not for me Pkt: ~p, State: ~p", [Pkt, State]),
                    % TODO: (nikola): when we make sure the above error is not happening
                    % change to deny
                    allow;
                false ->
                    allow
            end;
        _ ->
            ?ERROR("unexpected incoming packets before establish "
                "Pkt: ~p StreamState: ~p", [Pkt, StreamState]),
            % TODO: Update to deny once it looks ok.
            allow
    end.


%% Privacy checks are being run on the receiver's process.
%% We dont expect being denied based on privacy rules for messages/iqs/ack stanzas.
%% For acks/iqs: server is sending them to the client: so they should never be denied.
%% For messages: these are already in the offline queue of the user:
%%     meaning sender's process has already checked the privacy settings here.
-spec privacy_check_packet_in(State :: state(), Pkt :: stanza()) -> allow | deny.
privacy_check_packet_in(State, Pkt) ->
    case Pkt of
        #pb_presence{} -> privacy_check_packet(State, Pkt, in);
        #pb_chat_state{} -> privacy_check_packet(State, Pkt, in);
        #pb_msg{} -> allow;
        #pb_iq{} -> allow;
        #pb_ack{} -> allow
    end.

-spec privacy_check_packet(state(), stanza(), in | out) -> allow | deny.
privacy_check_packet(#{lserver := LServer} = State, Pkt, Dir) ->
    ejabberd_hooks:run_fold(privacy_check_packet, LServer, allow, [State, Pkt, Dir]).


-spec resource_conflict_action(binary(), binary(), binary()) ->
                      {accept_resource, binary()} | closenew.
resource_conflict_action(U, S, R) ->
    OptionRaw = case ejabberd_sm:is_existing_resource(U, S, R) of
        true ->
            ejabberd_option:resource_conflict(S);
        false ->
            acceptnew
    end,
    Option = case OptionRaw of
        setresource -> setresource;
        closeold -> acceptnew; %% ejabberd_sm will close old session
        closenew -> closenew;
        acceptnew -> acceptnew
    end,
    case Option of
        acceptnew -> {accept_resource, R};
        closenew -> closenew;
        setresource ->
            Rnew = new_uniq_id(),
            {accept_resource, Rnew}
    end.


-spec bounce_message_queue(ejabberd_sm:sid(), jid:jid()) -> ok.
bounce_message_queue({_, Pid} = SID, JID) ->
    {U, S, R} = jid:tolower(JID),
    SIDs = ejabberd_sm:get_session_sids(U, S, R),
    case lists:member(SID, SIDs) of
    true ->
        ?WARNING("The session for ~ts@~ts/~ts is supposed to "
             "be unregistered, but session identifier ~p "
             "still presents in the 'session' table",
             [U, S, R, Pid]);
    false ->
        receive {route, Pkt} ->
            ejabberd_router:route(Pkt),
            bounce_message_queue(SID, JID)
        after 0 ->
            ok
        end
    end.


-spec new_uniq_id() -> binary().
new_uniq_id() ->
    iolist_to_binary([p1_rand:get_string(), integer_to_binary(erlang:unique_integer([positive]))]).


-spec get_conn_type(state()) -> c2s | c2s_tls | c2s_noise | websocket | http_bind.
get_conn_type(State) ->
    case halloapp_stream_in:get_transport(State) of
        tcp -> c2s;
        tls -> c2s_tls;
        noise -> c2s_noise;
        http_bind -> http_bind;
        websocket -> websocket
    end.


-spec change_shaper(state()) -> state().
change_shaper(#{shaper := ShaperName, ip := {IP, _}, lserver := LServer,
        user := U, server := S, resource := R} = State) ->
    JID = jid:make(U, S, R),
    Shaper = ejabberd_shaper:match(LServer, ShaperName,
                   #{usr => jid:split(JID), ip => IP}),
    halloapp_stream_in:change_shaper(State, ejabberd_shaper:new(Shaper)).


-spec format_reason(state(), term()) -> binary().
format_reason(#{stop_reason := Reason}, _) ->
    halloapp_stream_in:format_error(Reason);
format_reason(_, normal) ->
    <<"unknown reason">>;
format_reason(_, shutdown) ->
    <<"stopped by supervisor">>;
format_reason(_, {shutdown, _}) ->
    <<"stopped by supervisor">>;
format_reason(_, _) ->
    <<"internal server error">>.

listen_opt_type(crypto) ->
    econf:enum([tls, noise, none]).

listen_options() ->
    [{access, all},
    {shaper, none},
    {max_stanza_size, infinity},
    {max_fsm_queue, 5000},
    {crypto, tls}].

