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
    is_valid_client_version/2,
    handle_stream_end/2,
    handle_authenticated_packet/2,
    handle_auth_success/4,
    handle_auth_failure/4,
    handle_send/3,
    handle_recv/3
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
-include("logger.hrl").
-include("translate.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(NOISE_STATIC_KEY, <<"static_key">>).
-define(NOISE_SERVER_CERTIFICATE, <<"server_certificate">>).

-type state() :: halloapp_stream_in:state().
-export_type([state/0]).


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
    Pkt1 = fix_from_to(Pkt, State),
    case ejabberd_hooks:run_fold(c2s_filter_send, LServer, {Pkt1, State}, []) of
        {drop, State1} -> State1;
        {Pkt2, State1} -> halloapp_stream_in:send(State1, Pkt2)
    end.


-spec send_error(state(), xmpp_element(), binary()) -> state().
send_error(#{lserver := LServer} = State, Pkt, Err) ->
    case ejabberd_hooks:run_fold(c2s_filter_send, LServer, {Pkt, State}, []) of
        {drop, State1} -> State1;
        {Pkt1, State1} -> halloapp_stream_in:send_error(State1, Pkt1, Err)
    end.


-spec send_error(state(), binary()) -> state().
send_error(State, Err) ->
    halloapp_stream_in:send_error(State, Err).


-spec route(pid(), term()) -> boolean().
route(Pid, Term) ->
    ejabberd_cluster:send(Pid, Term).


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
open_session(#{user := U, server := S, resource := R, sid := SID, client_version := ClientVersion,
        ip := IP, auth_module := AuthModule, mode := Mode} = State) ->
    JID = jid:make(U, S, R),
    State1 = change_shaper(State),
    Conn = get_conn_type(State1),
    State2 = State1#{conn => Conn, resource => R, jid => JID},
    Priority = 0,
    Info = [{ip, IP}, {conn, Conn}, {auth_module, AuthModule},
            {mode, Mode}, {client_version, ClientVersion}],
    ejabberd_sm:open_session(SID, U, S, R, Priority, Info),
    halloapp_stream_in:establish(State2).


%%%===================================================================
%%% Hooks
%%%===================================================================

upgrade_packet(#message{type = chat, sub_els = [SubEl]} = Message) ->
    case SubEl of
        #chat{} -> Message;
        #rerequest_st{} -> Message;
        #silent_chat{chat = ChatSubEl} ->
            Message#message{sub_els = [#silent_chat{chat = fix_chat_subel(ChatSubEl)}]};
        ChatSubEl ->
            NewChatSubEl = fix_chat_subel(ChatSubEl),
            Message#message{sub_els = [NewChatSubEl]}
    end;
upgrade_packet(Packet) -> Packet.


fix_chat_subel(ChatSubEl) ->
    case ChatSubEl of
        #chat{} -> ChatSubEl;
        {chat, Xmlns, Timestamp, SenderName, ChatSubEls} ->
            %% add missing field.
            #chat{
                xmlns = Xmlns,
                timestamp = Timestamp,
                sender_name = SenderName,
                sub_els = ChatSubEls
            };
        {chat, Xmlns, Timestamp, SenderName, _SenderLogInfo, ChatSubEls} ->
            %% remove additional field.
            #chat{
                xmlns = Xmlns,
                timestamp = Timestamp,
                sender_name = SenderName,
                sub_els = ChatSubEls
            };
        _ ->
            ?ERROR("invalid sub_element: ~p", [ChatSubEl]),
            ChatSubEl
    end.


process_info(#{lserver := LServer} = State, {route, Packet}) ->
    NewPacket = upgrade_packet(Packet),
    {Pass, State1} = case NewPacket of
        #presence{} -> process_presence_in(State, NewPacket);
        #message{} -> process_message_in(State, NewPacket);
        #iq{} -> process_iq_in(State, NewPacket);
        #ack{} -> {true, State};
        #chat_state{} -> {true, State}
    end,
    if
        Pass ->
            %% TODO(murali@): remove temp counts after clients transition.
            stat:count("HA/user_receive_packet", "protobuf"),
            {Packet1, State2} = ejabberd_hooks:run_fold(
                    user_receive_packet, LServer, {NewPacket, State1}, []),
            case Packet1 of
                drop -> State2;
                _ -> send(State2, Packet1)
            end;
        true ->
            State1
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


process_auth_result(#{socket := Socket,
        ip := IP, lserver := LServer} = State, true, User) ->
    ?INFO("(~ts) Accepted c2s authentication for ~ts@~ts from ~ts",
            [halloapp_socket:pp(Socket), User, LServer,
            ejabberd_config:may_hide_data(misc:ip_to_list(IP))]),
    State;
process_auth_result(#{socket := Socket,ip := IP, lserver := LServer} = State,
        {false, Reason}, User) ->
    ?WARNING("(~ts) Failed c2s authentication ~tsfrom ~ts: ~ts",
            [halloapp_socket:pp(Socket),
            if User /= <<"">> -> ["for ", User, "@", LServer, " "];
                true -> ""
            end, ejabberd_config:may_hide_data(misc:ip_to_list(IP)), Reason]),
    State.


process_closed(State, Reason) ->
    stop(State#{stop_reason => Reason}).


process_terminated(#{sid := SID, socket := Socket,
        jid := JID, user := Uid, server := Server, resource := Resource} = State,
        Reason) ->
    Status = format_reason(State, Reason),
    ?INFO("(~ts) Closing c2s session for ~ts: ~ts",
            [halloapp_socket:pp(Socket), jid:encode(JID), Status]),
    State1 = case maps:is_key(pres_last, State) of
        true ->
            ejabberd_sm:close_session(SID, Uid, Server, Resource),
            ejabberd_hooks:run(unset_presence_hook, Server, [Uid, Server, Resource, Status]),
            State;
        false ->
            ejabberd_sm:close_session(SID, Uid, Server, Resource),
            State
    end,
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


tls_options(#{lserver := LServer, tls_options := DefaultOpts}) ->
    TLSOpts = case ejabberd_pkix:get_certfile(LServer) of
        error -> DefaultOpts;
        {ok, CertFile} -> lists:keystore(certfile, 1, DefaultOpts, {certfile, CertFile})
    end,
    TLSOpts.

noise_options(#{lserver := _LServer, noise_options := DefaultOpts}) ->
    DefaultOpts.


check_password_fun(_Mech, #{lserver := _LServer}) ->
    fun(U, _AuthzId, P) ->
        ejabberd_auth:check_password(U, P)
    end.


bind(<<"">>, State) ->
    bind(new_uniq_id(), State);
bind(R, #{user := U, server := S, access := Access, lang := Lang,
      lserver := LServer, socket := Socket,
      ip := IP} = State) ->
    case resource_conflict_action(U, S, R) of
    closenew ->
        {error, xmpp:err_conflict(), State};
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
            Txt = ?T("Access denied by service policy"),
            {error, xmpp:err_not_allowed(Txt, Lang), State}
        end
    end.


is_valid_client_version(ClientVersion, _State) ->
    % TODO(Nikola): clean up this print once we figure out the different versions bug
    ?INFO("halloapp_c2s ClientVersion: ~p", [ClientVersion]),
    mod_client_version:is_valid_version(ClientVersion).


handle_stream_end(Reason, #{lserver := LServer} = State) ->
    State1 = State#{stop_reason => Reason},
    ejabberd_hooks:run_fold(pb_c2s_closed, LServer, State1, [Reason]).


handle_auth_success(User, _Mech, AuthModule,
            #{lserver := LServer} = State) ->
    State1 = State#{auth_module => AuthModule},
    ejabberd_hooks:run_fold(pb_c2s_auth_result, LServer, State1, [true, User]).


handle_auth_failure(User, _Mech, Reason, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_auth_result, LServer, State, [{false, Reason}, User]).


handle_authenticated_packet(Pkt, #{lserver := LServer} = State) when not ?is_stanza(Pkt) ->
    ejabberd_hooks:run_fold(c2s_authenticated_packet, LServer, State, [Pkt]);
handle_authenticated_packet(Pkt, #{lserver := LServer, jid := JID,
                   ip := {IP, _}} = State) ->
    Pkt1 = xmpp:put_meta(Pkt, ip, IP),
    State1 = ejabberd_hooks:run_fold(c2s_authenticated_packet,
                     LServer, State, [Pkt1]),
    #jid{luser = _LUser} = JID,
    %% TODO(murali@): remove temp counts after clients transition.
    stat:count("HA/user_send_packet", "protobuf"),
    {Pkt2, State2} = ejabberd_hooks:run_fold(
               user_send_packet, LServer, {Pkt1, State1}, []),
    case Pkt2 of
    drop ->
        State2;
    #iq{type = set, sub_els = [_]} ->
        try xmpp:try_subtag(Pkt2, #xmpp_session{}) of
        #xmpp_session{} ->
            send(State2, xmpp:make_iq_result(Pkt2));
        _ ->
            check_privacy_then_route(State2, Pkt2)
        catch _:{xmpp_codec, _Why} ->
            send_error(State2, Pkt2, <<"bad_request">>)
        end;
    #presence{} ->
        process_presence_out(State2, Pkt2);
    #ack{} ->
        State2;
    #chat_state{} ->
        State2;
    _ ->
        check_privacy_then_route(State2, Pkt2)
    end.


handle_recv(El, Pkt, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_handle_recv, LServer, State, [El, Pkt]).


handle_send(Pkt, Result, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(c2s_handle_send, LServer, State, [Pkt, Result]).


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
        tls ->
            TLSOpts1 = lists:filter(
                fun({certfile, _}) -> true;
                    (_) -> false
                end, Opts),
            State1#{tls_options => TLSOpts1};
        noise ->
            {NoiseStaticKey, NoiseCertificate} = get_noise_info(),

            [{_, ServerPublic, _}, {_, ServerSecret, _}] = public_key:pem_decode(NoiseStaticKey),
            ServerKeypair = enoise_keypair:new(dh25519, ServerSecret, ServerPublic),

            [{_, Certificate, _}] = public_key:pem_decode(NoiseCertificate),
        
            NoiseOpts = [{noise_static_key, ServerKeypair},
                         {noise_server_certificate, Certificate}],
            State1#{noise_options => NoiseOpts}
    end,
    Timeout = ejabberd_option:negotiation_timeout(),
    State3 = halloapp_stream_in:set_timeout(State2, Timeout),
    ejabberd_hooks:run_fold(c2s_init, {ok, State3}, [Opts]).


%% TODO(vipin): Try and cache the key and certificate.
get_noise_info() ->
    [{?NOISE_STATIC_KEY, NoiseStaticKey}, {?NOISE_SERVER_CERTIFICATE, NoiseCertificate}] = 
        jsx:decode(mod_aws:get_secret(config:get_noise_secret_name())),
    {base64:decode(NoiseStaticKey), base64:decode(NoiseCertificate)}.


handle_call(Request, From, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_handle_call, LServer, State, [Request, From]).


handle_cast(Msg, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_handle_cast, LServer, State, [Msg]).


handle_info(replaced, State) ->
    send_error(State, <<"session_replaced">>);
handle_info(kick, State) ->
    send_error(State, <<"session_kicked">>);
handle_info({exit, Reason}, #{user := User} = State) ->
    ?ERROR("Uid: ~s, session exit reason: ~p", [User, Reason]),
    send_error(State, <<"server_error">>);
handle_info(activate_session, #{user := Uid, mode := active} = State) ->
    ?WARNING("Uid: ~s, mode is already active in c2s_state", [Uid]),
    State;
handle_info(activate_session, #{user := Uid, mode := passive} = State) ->
    ?INFO("Uid: ~s, pid: ~p, Updating mode from passive to active in c2s_state", [Uid, self()]),
    State#{mode => active};
handle_info({offline_queue_cleared, LastMsgOrderId},
        #{user := Uid, lserver := Server} = State) ->
    ?INFO("Uid: ~s, offline_queue is now cleared", [Uid]),
    NewState = State#{offline_queue_cleared => true},
    ejabberd_hooks:run(offline_queue_cleared, Server, [Uid, Server, LastMsgOrderId]),
    NewState;
handle_info(Info, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_handle_info, LServer, State, [Info]).


terminate(Reason, #{lserver := LServer} = State) ->
    ejabberd_hooks:run_fold(pb_c2s_terminated, LServer, State, [Reason]).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================


-spec process_iq_in(state(), iq()) -> {boolean(), state()}.
process_iq_in(State, #iq{} = IQ) ->
    case privacy_check_packet(State, IQ, in) of
    allow ->
        {true, State};
    deny ->
        ?ERROR("failed_privacy_rules, packet received: ~p", [IQ]),
        Err = util:err(service_unavailable),
        ErrorIq = xmpp:make_error(IQ, Err),
        ejabberd_router:route(ErrorIq),
        {false, State}
    end.


-spec process_message_in(state(), message()) -> {boolean(), state()}.
process_message_in(State, #message{type = T} = Msg) ->
    %% This function should be as simple as process_iq_in/2,
    %% however, we don't route errors to MUC rooms in order
    %% to avoid kicking us, because having a MUC room's JID blocked
    %% most likely means having only some particular participant
    %% blocked, i.e. room@conference.server.org/participant.
    case privacy_check_packet(State, Msg, in) of
    allow ->
        {true, State};
    deny when T == groupchat; T == headline ->
        {false, State};
    deny ->
        ?INFO("failed_privacy_rules, packet received: ~p", [Msg]),
        %% Log and silently ignore these packets.
        %% No, need to route any errors back to the clients.
        {false, State}
    end.


-spec process_presence_in(state(), presence()) -> {boolean(), state()}.
process_presence_in(#{lserver := LServer} = State0, #presence{} = Pres) ->
    State = ejabberd_hooks:run_fold(c2s_presence_in, LServer, State0, [Pres]),
    case privacy_check_packet(State, Pres, in) of
        allow ->
            {true, State};
        deny ->
            {false, State}
    end.


%% TODO(murali@): move the presence-filter logic to mod_presence or something like that.
-spec process_presence_out(state(), presence()) -> state().
process_presence_out(#{user := User, server := Server} = State,
        #presence{type = Type} = Presence) when Type == subscribe; Type == unsubscribe ->
    %% We run the presence_subs_hook hook,
    %% since these presence stanzas are about updating user's activity status.
    ejabberd_hooks:run(presence_subs_hook, Server, [User, Server, Presence]),
    State;

process_presence_out(#{sid := _SID, user := Uid, lserver := Server, resource := Resource} = State,
        #presence{type = Type} = Presence) when Type == available; Type == away ->
    %% We run the set_presence_hook,
    %% since these presence stanzas are about updating user's activity status.
    ejabberd_hooks:run(set_presence_hook, Server, [Uid, Server, Resource, Presence]),
    State#{pres_last => Presence, pres_timestamp_ms => util:now_ms()};

process_presence_out(State, _Pres) ->
    %% We dont expect this to happen.
    ?ERROR("Invalid presence stanza: ~p, state: ~p", [_Pres, State]),
    State.


-spec check_privacy_then_route(state(), stanza()) -> state().
check_privacy_then_route(State, Pkt) ->
    case privacy_check_packet(State, Pkt, out) of
        deny ->
            ?INFO("failed_privacy_rules, packet received: ~p", [Pkt]),
            State;
        allow ->
            ejabberd_router:route(Pkt),
            State
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


-spec fix_from_to(xmpp_element(), state()) -> stanza().
fix_from_to(Pkt, #{jid := JID}) when ?is_stanza(Pkt) ->
    #jid{luser = U, lserver = S, lresource = R} = JID,
    case xmpp:get_from(Pkt) of
        undefined ->
            Pkt;
        From ->
            From1 = case jid:tolower(From) of
                {U, S, R} -> JID;
                {U, S, _} -> jid:replace_resource(JID, From#jid.resource);
                _ -> From
                end,
            xmpp:set_from_to(Pkt, From1, JID)
    end;
fix_from_to(Pkt, _State) ->
    Pkt.


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

listen_opt_type(noise_static_key) ->
    econf:any();
listen_opt_type(noise_server_certificate) ->
    econf:any();
listen_opt_type(crypto) ->
    econf:enum([tls, noise]).

listen_options() ->
    [{access, all},
    {shaper, none},
    {max_stanza_size, infinity},
    {max_fsm_queue, 5000},
    {noise_static_key, undefined},
    {noise_server_certificate, undefined},
    {crypto, tls}].

