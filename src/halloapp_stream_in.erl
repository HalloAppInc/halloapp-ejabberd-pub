%%%-------------------------------------------------------------------
%%% File    : halloapp_stream_in.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-------------------------------------------------------------------

-module(halloapp_stream_in).
-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).
-author('yexin').
-author('murali').

-protocol({rfc, 6120}).
-protocol({xep, 114, '1.6'}).

%% gen_server callbacks
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).

%% API
-export([
    start/3,
    start_link/3,
    call/3,
    cast/2,
    reply/2,
    stop/1,
    accept/1,
    send/2,
    close/1,
    close/2,
    send_error/3,
    establish/1,
    get_transport/1,
    change_shaper/2,
    set_timeout/2,
    format_error/1
]).


%%-define(DBGFSM, true).
-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.


-include("xmpp.hrl").
-include("logger.hrl").
-type state() :: #{
    owner := pid(),
    mod := module(),
    socket := halloapp_socket:socket(),
    socket_mod => halloapp_socket:sockmod(),
    socket_opts => [proplists:property()],
    socket_monitor => reference(),
    stream_timeout := {integer(), integer()} | infinity,
    stream_state := stream_state(),
    stream_direction => in | out,
    stream_id => binary(),
    stream_version => {non_neg_integer(), non_neg_integer()},
    stream_authenticated => boolean(),
    ip => {inet:ip_address(), inet:port_number()},
    codec_options => [xmpp:decode_option()],
    xmlns => binary(),
    lang => binary(),
    user => binary(),
    server => binary(),
    resource => binary(),
    lserver => binary(),
    remote_server => binary(),
    mode => active | passive,
    _ => _
}.
-type stream_state() :: accepting | wait_for_stream | wait_for_authentication | established | disconnected.
-type stop_reason() :: {stream, reset | {in | out, stream_error()}} |
               {tls, inet:posix() | atom() | binary()} |
               {socket, inet:posix() | atom()} |
               internal_failure.
-type noreply() :: {noreply, state(), timeout()}.
-type next_state() :: noreply() | {stop, term(), state()}.
-export_type([state/0, stop_reason/0]).
-callback init(list()) -> {ok, state()} | {error, term()} | ignore.
-callback handle_cast(term(), state()) -> state().
-callback handle_call(term(), term(), state()) -> state().
-callback handle_info(term(), state()) -> state().
-callback terminate(term(), state()) -> any().
-callback code_change(term(), state(), term()) -> {ok, state()} | {error, term()}.
-callback handle_stream_established(state()) -> state().
-callback handle_stream_end(stop_reason(), state()) -> state().
-callback handle_authenticated_packet(xmpp_element(), state()) -> state().
-callback handle_auth_success(binary(), binary(), module(), state()) -> state().
-callback handle_auth_failure(binary(), binary(), binary(), state()) -> state().
-callback handle_send(xmpp_element(), ok | {error, inet:posix()}, state()) -> state().
-callback handle_recv(fxml:xmlel(), xmpp_element() | {error, term()}, state()) -> state().
-callback handle_timeout(state()) -> state().
-callback check_password_fun(xmpp_sasl:mechanism(), state()) -> fun().
-callback bind(binary(), state()) -> {ok, state()} | {error, stanza_error(), state()}.
-callback is_valid_client_version(binary(), state()) -> true | false.
-callback tls_options(state()) -> [proplists:property()].


%% Some callbacks are optional
-optional_callbacks([
    handle_stream_established/1,
    handle_stream_end/2,
    handle_auth_success/4,
    handle_auth_failure/4,
    handle_send/3,
    handle_recv/3,
    handle_timeout/1
]).


%%%===================================================================
%%% API
%%%===================================================================


start(Mod, Args, Opts) ->
    ?GEN_SERVER:start(?MODULE, [Mod|Args], Opts ++ ?FSMOPTS).


start_link(Mod, Args, Opts) ->
    ?GEN_SERVER:start_link(?MODULE, [Mod|Args], Opts ++ ?FSMOPTS).


call(Ref, Msg, Timeout) ->
    ?GEN_SERVER:call(Ref, Msg, Timeout).


cast(Ref, Msg) ->
    ?GEN_SERVER:cast(Ref, Msg).


reply(Ref, Reply) ->
    ?GEN_SERVER:reply(Ref, Reply).


-spec stop(pid()) -> ok;
        (state()) -> no_return().
stop(Pid) when is_pid(Pid) ->
    cast(Pid, stop);
stop(#{owner := Owner} = State) when Owner == self() ->
    terminate(normal, State),
    try erlang:nif_error(normal)
    catch _:_ -> exit(normal)
    end;
stop(_) ->
    erlang:error(badarg).


-spec accept(pid()) -> ok.
accept(Pid) ->
    cast(Pid, accept).


-spec send(pid(), xmpp_element()) -> ok;
        (state(), xmpp_element()) -> state().
send(Pid, Pkt) when is_pid(Pid) ->
    cast(Pid, {send, Pkt});
send(#{owner := Owner} = State, Pkt) when Owner == self() ->
    send_pkt(State, Pkt);
send(_, _) ->
    erlang:error(badarg).


-spec close(pid()) -> ok;
       (state()) -> state().
close(Pid) when is_pid(Pid) ->
    close(Pid, closed);
close(#{owner := Owner} = State) when Owner == self() ->
    close_socket(State);
close(_) ->
    erlang:error(badarg).


-spec close(pid(), atom()) -> ok.
close(Pid, Reason) ->
    cast(Pid, {close, Reason}).


-spec establish(state()) -> state().
establish(State) ->
    process_stream_established(State).


-spec set_timeout(state(), non_neg_integer() | infinity) -> state().
set_timeout(#{owner := Owner} = State, Timeout) when Owner == self() ->
    case Timeout of
        infinity -> State#{stream_timeout => infinity};
        _ ->
            Time = p1_time_compat:monotonic_time(milli_seconds),
            State#{stream_timeout => {Timeout, Time}}
    end;
set_timeout(_, _) ->
    erlang:error(badarg).


-spec get_transport(state()) -> atom().
get_transport(#{socket := Socket, owner := Owner})
  when Owner == self() ->
    halloapp_socket:get_transport(Socket);
get_transport(_) ->
    erlang:error(badarg).


-spec change_shaper(state(), none | p1_shaper:state()) -> state().
change_shaper(#{socket := Socket, owner := Owner} = State, Shaper)
  when Owner == self() ->
    Socket1 = halloapp_socket:change_shaper(Socket, Shaper),
    State#{socket => Socket1};
change_shaper(_, _) ->
    erlang:error(badarg).


-spec format_error(stop_reason()) ->  binary().
format_error({socket, Reason}) ->
    format("Connection failed: ~s", [format_inet_error(Reason)]);
format_error({stream, reset}) ->
    <<"Stream reset by peer">>;
format_error({stream, {in, #stream_error{} = Err}}) ->
    format("Stream closed by peer: ~s", [xmpp:format_stream_error(Err)]);
format_error({stream, {out, #stream_error{} = Err}}) ->
    format("Stream closed by local host: ~s", [xmpp:format_stream_error(Err)]);
format_error({tls, Reason}) ->
    format("TLS failed: ~s", [format_tls_error(Reason)]);
format_error(internal_failure) ->
    <<"Internal server error">>;
format_error(Err) ->
    format("Unrecognized error: ~w", [Err]).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Mod, {SockMod, Socket}, Opts]) ->
    Time = p1_time_compat:monotonic_time(milli_seconds),
    Timeout = timer:seconds(30),
    State = #{owner => self(),
            mod => Mod,
            socket => Socket,
            socket_mod => SockMod,
            socket_opts => Opts,
            stream_timeout => {Timeout, Time},
            stream_state => accepting
    },
    ?INFO_MSG("here is the value for process state: ~p ~n", [State]),
    {ok, State, Timeout}.


-spec handle_cast(term(), state()) -> next_state().
handle_cast(accept, #{socket := Socket, socket_mod := SockMod, socket_opts := Opts} = State) ->
    XMPPSocket = halloapp_socket:new(SockMod, Socket, Opts),
    SocketMonitor = halloapp_socket:monitor(XMPPSocket),
    case halloapp_socket:peername(XMPPSocket) of
        {ok, IP} ->
            State1 = maps:remove(socket_mod, State),
            State2 = maps:remove(socket_opts, State1),
            State3 = State2#{socket => XMPPSocket, socket_monitor => SocketMonitor, ip => IP},
            State4 = init_state(State3, Opts),
            case is_disconnected(State4) of
                true -> noreply(State4);
                false -> handle_info({tcp, Socket, <<>>}, State4)
            end;
        {error, _} ->
            stop(State)
    end;

handle_cast({send, Pkt}, State) ->
    noreply(send_pkt(State, Pkt));

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast({close, Reason}, State) ->
    State1 = close_socket(State),
    noreply(
        case is_disconnected(State) of
            true -> State1;
            false -> process_stream_end({socket, Reason}, State)
        end);

handle_cast(Cast, State) ->
    noreply(try callback(handle_cast, Cast, State)
          catch _:{?MODULE, undef} -> State
          end).


-spec handle_call(term(), term(), state()) -> next_state().
handle_call(Call, From, State) ->
    noreply(try callback(handle_call, Call, From, State)
        catch _:{?MODULE, undef} -> State
        end).


-spec handle_info(term(), state()) -> next_state().
handle_info(_, #{stream_state := accepting} = State) ->
    ?INFO_MSG("here is the value for process state: ~p ~n", [State]),
    stop(State);

handle_info({'$gen_event', {xmlstreamstart, _Name, _Attrs}},
        #{stream_state := wait_for_stream} = State) ->
    noreply(State#{stream_state => wait_for_authentication});

handle_info({'$gen_event', {xmlstreamend, _}}, State) ->
    noreply(process_stream_end({stream, reset}, State));

handle_info({'$gen_event', closed}, State) ->
    noreply(process_stream_end({socket, closed}, State));

handle_info({'$gen_event', {xmlstreamerror, Reason}}, #{lang := Lang}= State) ->
    noreply(
        case is_disconnected(State) of
            true -> State;
            false ->
                Err = case Reason of
                    <<"XML stanza is too big">> -> xmpp:serr_policy_violation(Reason, Lang);
                    {_, Txt} -> xmpp:serr_not_well_formed(Txt, Lang)
                end,
              send_pkt(State, Err)
        end);

handle_info({'$gen_event', El}, #{stream_state := wait_for_stream} = State) ->
    ?WARNING_MSG("unexpected event from XML driver: ~p; xmlstreamstart was expected", [El]),
    noreply(
        case is_disconnected(State) of
            true -> State;
            false -> send_pkt(State, xmpp:serr_invalid_xml())
        end);

handle_info({'$gen_event', {xmlstreamelement, El}},
        #{xmlns := NS, codec_options := Opts} = State) ->
    noreply(
        try xmpp:decode(El, NS, Opts) of
        Pkt ->
            State1 = try callback(handle_recv, El, Pkt, State)
               catch _:{?MODULE, undef} -> State
               end,
            case is_disconnected(State1) of
                true -> State1;
                false -> process_element(Pkt, State1)
            end
        catch _:{xmpp_codec, Why} ->
            State1 = try callback(handle_recv, El, {error, Why}, State)
               catch _:{?MODULE, undef} -> State
               end,
            case is_disconnected(State1) of
                true -> State1;
                false -> process_invalid_xml(State1, El, Why)
            end
        end);

handle_info(timeout, #{lang := Lang} = State) ->
    Disconnected = is_disconnected(State),
    noreply(try callback(handle_timeout, State)
        catch _:{?MODULE, undef} when not Disconnected ->
            Txt = <<"Idle connection">>,
            send_pkt(State, xmpp:serr_connection_timeout(Txt, Lang));
          _:{?MODULE, undef} ->
            stop(State)
        end);

handle_info({'DOWN', MRef, _Type, _Object, _Info},
        #{socket_monitor := MRef} = State) ->
    noreply(process_stream_end({socket, closed}, State));

handle_info({tcp, _, Data}, #{socket := Socket} = State) ->
    noreply(
        case halloapp_socket:recv(Socket, Data) of
            {ok, NewSocket} ->
                State#{socket => NewSocket};
            {error, Reason} when is_atom(Reason) ->
                process_stream_end({socket, Reason}, State);
            {error, Reason} ->
                %% TODO: make fast_tls return atoms
                process_stream_end({tls, Reason}, State)
        end);

handle_info({tcp_closed, _}, State) ->
    handle_info({'$gen_event', closed}, State);

handle_info({tcp_error, _, Reason}, State) ->
    noreply(process_stream_end({socket, Reason}, State));

handle_info(Info, State) ->
    noreply(try callback(handle_info, Info, State)
        catch _:{?MODULE, undef} -> State
        end).


-spec terminate(term(), state()) -> state().
terminate(_, #{stream_state := accepting} = State) ->
    ?INFO_MSG("here is the value for process state: ~p ~n", [State]),
    State;
terminate(Reason, State) ->
    ?INFO_MSG("here is the value for process state: ~p ~n", [State]),
    case get(already_terminated) of
        true ->
            State;
        _ ->
            put(already_terminated, true),
            try callback(terminate, Reason, State)
            catch _:{?MODULE, undef} -> ok
            end,
            close_socket(State)
    end.


-spec code_change(term(), state(), term()) -> {ok, state()} | {error, term()}.
code_change(OldVsn, State, Extra) ->
    callback(code_change, OldVsn, State, Extra).


%%%===================================================================
%%% Internal functions
%%%===================================================================


-spec init_state(state(), [proplists:property()]) -> state().
init_state(#{socket := Socket, mod := Mod} = State, Opts) ->
    State1 = State#{stream_direction => in,
            stream_id => xmpp_stream:new_id(),
            stream_state => wait_for_stream,
            stream_version => {1,0},
            stream_authenticated => false,
            codec_options => [ignore_els],
            xmlns => ?NS_CLIENT,
            lang => <<"">>,
            user => <<"">>,
            server => <<"">>,
            resource => <<"">>,
            lserver => <<"">>},
    case try Mod:init([State1, Opts])
    catch _:undef -> {ok, State1}
    end of
        {ok, State2} ->
            TLSOpts = try callback(tls_options, State2)
                catch _:{?MODULE, undef} -> []
                end,
            case halloapp_socket:starttls(Socket, TLSOpts) of
                {ok, TLSSocket} ->
                    State2#{socket => TLSSocket};
                {error, Reason} ->
                    process_stream_end({tls, Reason}, State2)
            end;
        {error, Reason} ->
            process_stream_end(Reason, State1);
        ignore ->
            stop(State)
    end.


-spec noreply(state()) -> noreply().
noreply(#{stream_timeout := infinity} = State) ->
    ?INFO_MSG("here is the value for process state: ~p ~n", [State]),
    {noreply, State, infinity};
noreply(#{stream_timeout := {MSecs, StartTime}} = State) ->
    ?INFO_MSG("here is the value for process state: ~p ~n", [State]),
    CurrentTime = p1_time_compat:monotonic_time(milli_seconds),
    Timeout = max(0, MSecs - CurrentTime + StartTime),
    {noreply, State, Timeout}.


-spec is_disconnected(state()) -> boolean().
is_disconnected(#{stream_state := StreamState}) ->
    StreamState == disconnected.


-spec process_invalid_xml(state(), fxml:xmlel(), term()) -> state().
process_invalid_xml(#{lang := MyLang} = State, El, Reason) ->
    Txt = xmpp:io_format_error(Reason),
    Lang = select_lang(MyLang, xmpp:get_lang(El)),
    send_error(State, El, xmpp:err_bad_request(Txt, Lang)).


-spec process_stream_end(stop_reason(), state()) -> state().
process_stream_end(_, #{stream_state := disconnected} = State) ->
    State;
process_stream_end(Reason, State) ->
    State1 = State#{stream_timeout => infinity, stream_state => disconnected},
    try callback(handle_stream_end, Reason, State1)
    catch _:{?MODULE, undef} -> stop(State1)
    end.


-spec process_element(xmpp_element(), state()) -> state().
process_element(Pkt, #{stream_state := StateName, lang := Lang} = State) ->
    FinalState = case Pkt of
        #halloapp_auth{} when StateName == wait_for_authentication ->
            process_auth_request(Pkt, State);
        #stream_error{} ->
            process_stream_end({stream, {in, Pkt}}, State);
        _ when StateName == wait_for_authentication ->
            Txt = <<"Need to authenticate">>,
            Err = xmpp:serr_policy_violation(Txt, Lang),
            send_pkt(State, Err);
        _ when StateName == established ->
            process_authenticated_packet(Pkt, State)
    end,
    ?INFO_MSG("here is the value for process state: ~p ~n", [FinalState]),
    FinalState.


-spec process_authenticated_packet(xmpp_element(), state()) -> state().
process_authenticated_packet(Pkt, State) ->
    Pkt1 = set_lang(Pkt, State),
    case set_from_to(Pkt1, State) of
        {ok, Pkt2} ->
            try callback(handle_authenticated_packet, Pkt2, State)
            catch _:{?MODULE, undef} ->
                Err = xmpp:err_service_unavailable(),
                send_error(State, Pkt, Err)
            end;
        {error, Err} ->
            send_pkt(State, Err)
    end.


%% TODO(murali@): cleanup this function.
-spec process_auth_request(halloapp_auth(), state()) -> state().
process_auth_request(#halloapp_auth{uid = Uid, pwd = Pwd, client_mode = Mode,
        client_version = ClientVersion, resource = R}, State) ->
    Resource = list_to_binary(atom_to_list(R)),
    State1 = State#{user => Uid, client_version => ClientVersion, resource => Resource, mode => Mode},
    %% Check Uid and Password. TODO(murali@): simplify this even further!
    CheckPW = check_password_fun(<<>>, State1),
    PasswordResult = CheckPW(Uid, <<>>, Pwd),
    {NewState, Result, Reason} = case PasswordResult of
        false ->
            State2 = try callback(handle_auth_failure, Uid, <<>>, <<>>, State1)
                catch _:{?MODULE, undef} -> State1
            end,
            {State2, <<"failure">>, <<"invalid uid or password">>};
        {true, AuthModule} ->
            State2 = State1#{auth_module => AuthModule},
            State3 = try callback(handle_auth_success, Uid, <<>>, AuthModule, State2)
                catch _:{?MODULE, undef} -> State2
            end,
            %% Check client_version
            case callback(is_valid_client_version, Resource, State3) of
                false ->
                    {State3, <<"failure">>, <<"invalid client version">>};
                true ->
                    %% Bind resource callback
                    case callback(bind, Resource, State3) of
                        {ok, #{resource := NewR} = State4} when NewR /= <<"">> ->
                            {State4,  <<"success">>, <<"welcome to halloapp">>};
                        {error, _, State4} ->
                            {State4, <<"failure">>, <<"invalid resource">>}
                    end
            end
    end,
    AuthResultPkt = #halloapp_auth_result{result = Result, reason = Reason},
    FinalState = send_pkt(NewState, AuthResultPkt),
    case Result of
        <<"failure">> -> stop(FinalState);
        <<"success">> -> FinalState
    end.


-spec process_stream_established(state()) -> state().
process_stream_established(#{stream_state := StateName} = State)
  when StateName == disconnected; StateName == established ->
    State;
process_stream_established(State) ->
    State1 = State#{stream_authenticated => true,
            stream_state => established,
            stream_timeout => infinity},
    try callback(handle_stream_established, State1)
    catch _:{?MODULE, undef} -> State1
    end.


-spec check_password_fun(xmpp_sasl:mechanism(), state()) -> fun().
check_password_fun(Mech, State) ->
    try callback(check_password_fun, Mech, State)
    catch _:{?MODULE, undef} -> fun(_, _, _) -> {false, undefined} end
    end.


-spec set_from_to(xmpp_element(), state()) -> {ok, xmpp_element()} |
                          {error, stream_error()}.
set_from_to(Pkt, _State) when not ?is_stanza(Pkt) ->
    {ok, Pkt};
set_from_to(Pkt, #{user := U, server := S, resource := R, lang := Lang, xmlns := ?NS_CLIENT}) ->
    JID = jid:make(U, S, R),
    From = case xmpp:get_from(Pkt) of
        undefined -> JID;
        F -> F
    end,
    if
        JID#jid.luser == From#jid.luser andalso
        JID#jid.lserver == From#jid.lserver andalso
        (JID#jid.lresource == From#jid.lresource
        orelse From#jid.lresource == <<"">>) ->
            To = case xmpp:get_to(Pkt) of
                 undefined -> jid:make(U, S);
                 T -> T
             end,
            {ok, xmpp:set_from_to(Pkt, JID, To)};
        true ->
            Txt = <<"Improper 'from' attribute">>,
            {error, xmpp:serr_invalid_from(Txt, Lang)}
    end;
set_from_to(Pkt, #{lang := Lang}) ->
    From = xmpp:get_from(Pkt),
    To = xmpp:get_to(Pkt),
    if
        From == undefined ->
            Txt = <<"Missing 'from' attribute">>,
            {error, xmpp:serr_improper_addressing(Txt, Lang)};
        To == undefined ->
            Txt = <<"Missing 'to' attribute">>,
            {error, xmpp:serr_improper_addressing(Txt, Lang)};
        true ->
            {ok, Pkt}
    end.


-spec send_pkt(state(), xmpp_element() | xmlel()) -> state().
send_pkt(State, Pkt) ->
    Result = socket_send(State, Pkt),
    State1 = try callback(handle_send, Pkt, Result, State)
         catch _:{?MODULE, undef} -> State
         end,
    case Result of
        _ when is_record(Pkt, stream_error) ->
            process_stream_end({stream, {out, Pkt}}, State1);
        ok ->
            State1;
        {error, _Why} ->
            % Queue process_stream_end instead of calling it directly,
            % so we have opportunity to process incoming queued messages before
            % terminating session.
            self() ! {'$gen_event', closed},
            State1
    end.


-spec send_error(state(), xmpp_element() | xmlel(), stanza_error()) -> state().
send_error(State, Pkt, Err) ->
    case xmpp:is_stanza(Pkt) of
        true ->
            case xmpp:get_type(Pkt) of
                result -> State;
                error -> State;
                <<"result">> -> State;
                <<"error">> -> State;
                _ ->
                    ErrPkt = xmpp:make_error(Pkt, Err),
                    send_pkt(State, ErrPkt)
            end;
        false ->
            %% Maybe add a specific xml error stanza
            State
    end.


-spec socket_send(state(), xmpp_element() | xmlel()) -> ok | {error, inet:posix()}.
socket_send(#{socket := Sock, stream_state := StateName, xmlns := NS}, Pkt) ->
    case Pkt of
        _ when StateName /= disconnected ->
            halloapp_socket:send_element(Sock, NS, Pkt);
        _ ->
            {error, closed}
    end;
socket_send(_, _) ->
    {error, closed}.


-spec close_socket(state()) -> state().
close_socket(#{socket := Socket} = State) ->
    halloapp_socket:close(Socket),
    State#{stream_timeout => infinity, stream_state => disconnected}.


-spec select_lang(binary(), binary()) -> binary().
select_lang(Lang, <<"">>) -> Lang;
select_lang(_, Lang) -> Lang.


-spec set_lang(xmpp_element(), state()) -> xmpp_element().
set_lang(Pkt, #{lang := MyLang, xmlns := ?NS_CLIENT}) when ?is_stanza(Pkt) ->
    HisLang = xmpp:get_lang(Pkt),
    Lang = select_lang(MyLang, HisLang),
    xmpp:set_lang(Pkt, Lang);
set_lang(Pkt, _) ->
    Pkt.


-spec format_inet_error(atom()) -> string().
format_inet_error(closed) ->
    "connection closed";
format_inet_error(Reason) ->
    case inet:format_error(Reason) of
    "unknown POSIX error" -> atom_to_list(Reason);
    Txt -> Txt
    end.


-spec format_tls_error(atom() | binary()) -> list().
format_tls_error(Reason) when is_atom(Reason) ->
    format_inet_error(Reason);
format_tls_error(Reason) ->
    Reason.


-spec format(io:format(), list()) -> binary().
format(Fmt, Args) ->
    iolist_to_binary(io_lib:format(Fmt, Args)).


%%%===================================================================
%%% Callbacks
%%%===================================================================


callback(F, #{mod := Mod} = State) ->
    case erlang:function_exported(Mod, F, 1) of
        true -> Mod:F(State);
        false -> erlang:error({?MODULE, undef})
    end.


callback(F, Arg1, #{mod := Mod} = State) ->
    case erlang:function_exported(Mod, F, 2) of
        true -> Mod:F(Arg1, State);
        false -> erlang:error({?MODULE, undef})
    end.


callback(code_change, OldVsn, #{mod := Mod} = State, Extra) ->
    %% code_change/3 callback is a special snowflake
    case erlang:function_exported(Mod, code_change, 3) of
        true -> Mod:code_change(OldVsn, State, Extra);
        false -> {ok, State}
    end;


callback(F, Arg1, Arg2, #{mod := Mod} = State) ->
    case erlang:function_exported(Mod, F, 3) of
        true -> Mod:F(Arg1, Arg2, State);
        false -> erlang:error({?MODULE, undef})
    end.


callback(F, Arg1, Arg2, Arg3, #{mod := Mod} = State) ->
    case erlang:function_exported(Mod, F, 4) of
        true -> Mod:F(Arg1, Arg2, Arg3, State);
        false -> erlang:error({?MODULE, undef})
    end.

