%%%-------------------------------------------------------------------
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created : 27 Jun 2013 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(suite).

%% API
-compile([nowarn_export_all, export_all]).

-include("suite.hrl").
-include_lib("kernel/include/file.hrl").
-include("packets.hrl").
-include("xmlel.hrl").
-define(NS_CLIENT, <<"jabber:client">>).
-define(NS_SERVER, <<"jabber:server">>).
-define(NS_COMPONENT, <<"jabber:component:accept">>).

%%%===================================================================
%%% API
%%%===================================================================
init_config(Config) ->
    DataDir = proplists:get_value(data_dir, Config),
    PrivDir = proplists:get_value(priv_dir, Config),
    [_, _|Tail] = lists:reverse(filename:split(DataDir)),
    BaseDir = filename:join(lists:reverse(Tail)),
    MacrosPathTpl = filename:join([DataDir, "macros.yml"]),
    ConfigPath = filename:join([DataDir, "ejabberd.yml"]),
    LogPath = filename:join([PrivDir, "ejabberd.log"]),
    SASLPath = filename:join([PrivDir, "sasl.log"]),
    MnesiaDir = filename:join([PrivDir, "mnesia"]),
    CertFile = filename:join([DataDir, "cert.pem"]),
    SelfSignedCertFile = filename:join([DataDir, "self-signed-cert.pem"]),
    CAFile = filename:join([DataDir, "ca.pem"]),
    {ok, CWD} = file:get_cwd(),
    {ok, _} = file:copy(CertFile, filename:join([CWD, "cert.pem"])),
    {ok, _} = file:copy(SelfSignedCertFile,
			filename:join([CWD, "self-signed-cert.pem"])),
    {ok, _} = file:copy(CAFile, filename:join([CWD, "ca.pem"])),
    {ok, MacrosContentTpl} = file:read_file(MacrosPathTpl),
    Password = <<"hallo">>,
    Backends = get_config_backends(),
    MacrosContent = process_config_tpl(
		      MacrosContentTpl,
		      [{c2s_port, 5222},
		       {loglevel, 4},
		       {new_schema, false},
		       {s2s_port, 5269},
		       {component_port, 5270},
		       {web_port, 5280},
		       {password, Password},
		       {mysql_server, <<"localhost">>},
		       {mysql_port, 3306},
		       {mysql_db, <<"ejabberd_test">>},
		       {mysql_user, <<"ejabberd_test">>},
		       {mysql_pass, <<"ejabberd_test">>},
		       {pgsql_server, <<"localhost">>},
		       {pgsql_port, 5432},
		       {pgsql_db, <<"ejabberd_test">>},
		       {pgsql_user, <<"ejabberd_test">>},
		       {pgsql_pass, <<"ejabberd_test">>},
		       {priv_dir, PrivDir}]),
    MacrosPath = filename:join([CWD, "macros.yml"]),
    ok = file:write_file(MacrosPath, MacrosContent),
    copy_backend_configs(DataDir, CWD, Backends),
    setup_ejabberd_lib_path(Config),
    setup_priv_dir(Config),
    case application:load(sasl) of
	ok -> ok;
	{error, {already_loaded, _}} -> ok
    end,
    case application:load(mnesia) of
	ok -> ok;
	{error, {already_loaded, _}} -> ok
    end,
    case application:load(ejabberd) of
	ok -> ok;
	{error, {already_loaded, _}} -> ok
    end,
    application:set_env(ejabberd, config, ConfigPath),
    application:set_env(ejabberd, log_path, LogPath),
    application:set_env(sasl, sasl_error_logger, {file, SASLPath}),
    application:set_env(mnesia, dir, MnesiaDir),
    [{server_port, ct:get_config(c2s_port, 5222)},
     {server_host, "localhost"},
     {component_port, ct:get_config(component_port, 5270)},
     {s2s_port, ct:get_config(s2s_port, 5269)},
     {server, ?COMMON_VHOST},
     {user, <<"1000000000000000001">>},
     {nick, <<"nick!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
     {master_nick, <<"master_nick!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
     {slave_nick, <<"slave_nick!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
     {room_subject, <<"hello, world!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
     {certfile, CertFile},
     {persistent_room, true},
     {anonymous, false},
     {type, client},
     {stream_version, {1, 0}},
     {stream_id, <<"">>},
     {stream_from, <<"">>},
     {db_xmlns, <<"">>},
     {mechs, []},
     {rosterver, false},
     {lang, <<"en">>},
     {base_dir, BaseDir},
     {receiver, undefined},
     {pubsub_node, <<"node!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
     {pubsub_node_title, <<"title!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
     {resource, <<"resource!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
     {master_resource, <<"master_resource!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
     {slave_resource, <<"slave_resource!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
     {password, Password},
     {backends, Backends}
     |Config].

copy_backend_configs(DataDir, CWD, Backends) ->
    Files = filelib:wildcard(filename:join([DataDir, "ejabberd.*.yml"])),
    lists:foreach(
      fun(Src) ->
	      File = filename:basename(Src),
	      case string:tokens(File, ".") of
		  ["ejabberd", SBackend, "yml"] ->
		      Backend = list_to_atom(SBackend),
		      Macro = list_to_atom(string:to_upper(SBackend) ++ "_CONFIG"),
		      Dst = filename:join([CWD, File]),
		      case lists:member(Backend, Backends) of
			  true ->
			      {ok, _} = file:copy(Src, Dst);
			  false ->
			      ok = file:write_file(
				     Dst, fast_yaml:encode(
					    [{define_macro, [{Macro, []}]}]))
		      end;
		  _ ->
		      ok
	      end
      end, Files).

find_top_dir(Dir) ->
    case file:read_file_info(filename:join([Dir, ebin])) of
	{ok, #file_info{type = directory}} ->
	    Dir;
	_ ->
	    find_top_dir(filename:dirname(Dir))
    end.

setup_ejabberd_lib_path(Config) ->
    case code:lib_dir(ejabberd) of
	{error, _} ->
	    DataDir = proplists:get_value(data_dir, Config),
	    {ok, CWD} = file:get_cwd(),
	    _NewEjPath = filename:join([CWD, "ejabberd-0.0.1"]),
	    TopDir = find_top_dir(DataDir),
        % TODO: this symlink is causing inf loop when running the ejabberd_SUITE
%%	    ok = file:make_symlink(TopDir, NewEjPath),
%%	    code:replace_path(ejabberd, NewEjPath);
        code:replace_path(ejabberd, TopDir);
	_ ->
	    ok
    end.

setup_priv_dir(Config) ->
    DataDir = proplists:get_value(data_dir, Config),
    TopDir = find_top_dir(DataDir),
    PrivDir = filename:join(TopDir, "priv"),
    {ok, CWD} = file:get_cwd(),
    NewPrivPath = filename:join([CWD, "priv"]),
    ok = file:make_symlink(PrivDir, NewPrivPath),
    ok.


%% Read environment variable CT_DB=mysql to limit the backends to test.
%% You can thus limit the backend you want to test with:
%%  CT_BACKENDS=mysql rebar ct suites=ejabberd
get_config_backends() ->
    EnvBackends = case os:getenv("CT_BACKENDS") of
		      false  -> ?BACKENDS;
		      String ->
			  Backends0 = string:tokens(String, ","),
			  lists:map(
			    fun(Backend) ->
				    list_to_atom(string:strip(Backend, both, $ ))
			    end, Backends0)
		  end,
    application:load(ejabberd),
    EnabledBackends = application:get_env(ejabberd, enabled_backends, EnvBackends),
    misc:intersection(EnvBackends, [mnesia, ldap | EnabledBackends]).

process_config_tpl(Content, []) ->
    Content;
process_config_tpl(Content, [{Name, DefaultValue} | Rest]) ->
    Val = case ct:get_config(Name, DefaultValue) of
              V when is_integer(V) ->
                  integer_to_binary(V);
              V when is_atom(V) ->
                  atom_to_binary(V, latin1);
              V ->
                  iolist_to_binary(V)
          end,
    NewContent = binary:replace(Content,
				<<"@@",(atom_to_binary(Name,latin1))/binary, "@@">>,
				Val, [global]),
    process_config_tpl(NewContent, Rest).

tcp_connect(Config) ->
    case ?config(receiver, Config) of
	undefined ->
	    Owner = self(),
	    NS = case ?config(type, Config) of
		     client -> ?NS_CLIENT;
		     server -> ?NS_SERVER;
		     component -> ?NS_COMPONENT
		 end,
	    Server = ?config(server_host, Config),
	    Port = ?config(server_port, Config),
	    ReceiverPid = spawn(fun() ->
					start_receiver(NS, Owner, Server, Port)
				end),
	    set_opt(receiver, ReceiverPid, Config);
	_ ->
	    Config
    end.

disconnect(Config) ->
    ct:comment("Disconnecting"),
    try
	send_text(Config, ?STREAM_TRAILER)
    catch exit:normal ->
	    ok
    end,
    receive {xmlstreamend, <<"stream:stream">>} -> ok end,
    flush(Config),
    ok = recv_call(Config, close),
    ct:comment("Disconnected"),
    set_opt(receiver, undefined, Config).

close_socket(Config) ->
    ok = recv_call(Config, close),
    Config.

re_register(Config) ->
    User = ?config(user, Config),
    Server = ?config(server, Config),
    Pass = ?config(password, Config),
    ok = ejabberd_auth:try_register(User, Server, Pass).

match_failure(Received, [Match]) when is_list(Match)->
    ct:fail("Received input:~n~n~p~n~ndon't match expected patterns:~n~n~s", [Received, Match]);
match_failure(Received, Matches) ->
    ct:fail("Received input:~n~n~p~n~ndon't match expected patterns:~n~n~p", [Received, Matches]).

recv(_Config) ->
    receive
	{fail, El, Why} ->
	    ct:fail("recv failed: ~p->~n~s",
		    [El, xmpp:format_error(Why)]);
	Event ->
	    Event
    end.

decode_stream_element(NS, El) ->
    decode(El, NS, []).

format_element(El) ->
    case erlang:function_exported(ct, log, 5) of
	true -> ejabberd_web_admin:pretty_print_xml(El);
	false -> io_lib:format("~p~n", [El])
    end.

decode(El, NS, Opts) ->
    try
	Pkt = xmpp:decode(El, NS, Opts),
	ct:pal("RECV:~n~s~n~s",
	       [format_element(El), xmpp:pp(Pkt)]),
	Pkt
    catch _:{xmpp_codec, Why} ->
	    ct:pal("recv failed: ~p->~n~s",
		   [El, xmpp:format_error(Why)]),
	    erlang:error({xmpp_codec, Why})
    end.

send_text(Config, Text) ->
    recv_call(Config, {send_text, Text}).


sasl_new(<<"PLAIN">>, {User, Server, Password}) ->
    {<<User/binary, $@, Server/binary, 0, User/binary, 0, Password/binary>>,
     fun (_) -> {error, <<"Invalid SASL challenge">>} end};
sasl_new(<<"EXTERNAL">>, {User, Server, _Password}) ->
    {jid:encode(jid:make(User, Server)),
     fun(_) -> ct:fail(sasl_challenge_is_not_expected) end};
sasl_new(<<"ANONYMOUS">>, _) ->
    {<<"">>,
     fun(_) -> ct:fail(sasl_challenge_is_not_expected) end};
sasl_new(<<"DIGEST-MD5">>, {User, Server, Password}) ->
    {<<"">>,
     fun (ServerIn) ->
	     case xmpp_sasl_digest:parse(ServerIn) of
	       bad -> {error, <<"Invalid SASL challenge">>};
	       KeyVals ->
		   Nonce = fxml:get_attr_s(<<"nonce">>, KeyVals),
		   CNonce = id(),
                   Realm = proplists:get_value(<<"realm">>, KeyVals, Server),
		   DigestURI = <<"xmpp/", Realm/binary>>,
		   NC = <<"00000001">>,
		   QOP = <<"auth">>,
		   AuthzId = <<"">>,
		   MyResponse = response(User, Password, Nonce, AuthzId,
					 Realm, CNonce, DigestURI, NC, QOP,
					 <<"AUTHENTICATE">>),
                   SUser = << <<(case Char of
                                     $" -> <<"\\\"">>;
                                     $\\ -> <<"\\\\">>;
                                     _ -> <<Char>>
                                 end)/binary>> || <<Char>> <= User >>,
		   Resp = <<"username=\"", SUser/binary, "\",realm=\"",
			    Realm/binary, "\",nonce=\"", Nonce/binary,
			    "\",cnonce=\"", CNonce/binary, "\",nc=", NC/binary,
			    ",qop=", QOP/binary, ",digest-uri=\"",
			    DigestURI/binary, "\",response=\"",
			    MyResponse/binary, "\"">>,
		   {Resp,
		    fun (ServerIn2) ->
			    case xmpp_sasl_digest:parse(ServerIn2) of
			      bad -> {error, <<"Invalid SASL challenge">>};
			      _KeyVals2 ->
                                    {<<"">>,
                                     fun (_) ->
                                             {error,
                                              <<"Invalid SASL challenge">>}
                                     end}
			    end
		    end}
	     end
     end}.

hex(S) ->
    p1_sha:to_hexlist(S).

response(User, Passwd, Nonce, AuthzId, Realm, CNonce,
	 DigestURI, NC, QOP, A2Prefix) ->
    A1 = case AuthzId of
	   <<"">> ->
	       <<((erlang:md5(<<User/binary, ":", Realm/binary, ":",
				Passwd/binary>>)))/binary,
		 ":", Nonce/binary, ":", CNonce/binary>>;
	   _ ->
	       <<((erlang:md5(<<User/binary, ":", Realm/binary, ":",
				Passwd/binary>>)))/binary,
		 ":", Nonce/binary, ":", CNonce/binary, ":",
		 AuthzId/binary>>
	 end,
    A2 = case QOP of
	   <<"auth">> ->
	       <<A2Prefix/binary, ":", DigestURI/binary>>;
	   _ ->
	       <<A2Prefix/binary, ":", DigestURI/binary,
		 ":00000000000000000000000000000000">>
	 end,
    T = <<(hex((erlang:md5(A1))))/binary, ":", Nonce/binary,
	  ":", NC/binary, ":", CNonce/binary, ":", QOP/binary,
	  ":", (hex((erlang:md5(A2))))/binary>>,
    hex((erlang:md5(T))).

my_jid(Config) ->
    jid:make(?config(user, Config),
	     ?config(server, Config),
	     ?config(resource, Config)).

server_jid(Config) ->
    jid:make(<<>>, ?config(server, Config), <<>>).

pubsub_jid(Config) ->
    Server = ?config(server, Config),
    jid:make(<<>>, <<"pubsub.", Server/binary>>, <<>>).

proxy_jid(Config) ->
    Server = ?config(server, Config),
    jid:make(<<>>, <<"proxy.", Server/binary>>, <<>>).

upload_jid(Config) ->
    Server = ?config(server, Config),
    jid:make(<<>>, <<"upload.", Server/binary>>, <<>>).

muc_jid(Config) ->
    Server = ?config(server, Config),
    jid:make(<<>>, <<"conference.", Server/binary>>, <<>>).

muc_room_jid(Config) ->
    Server = ?config(server, Config),
    jid:make(<<"test">>, <<"conference.", Server/binary>>, <<>>).

my_muc_jid(Config) ->
    Nick = ?config(nick, Config),
    RoomJID = muc_room_jid(Config),
    jid:replace_resource(RoomJID, Nick).

peer_muc_jid(Config) ->
    PeerNick = ?config(peer_nick, Config),
    RoomJID = muc_room_jid(Config),
    jid:replace_resource(RoomJID, PeerNick).

alt_room_jid(Config) ->
    Server = ?config(server, Config),
    jid:make(<<"alt">>, <<"conference.", Server/binary>>, <<>>).

mix_jid(Config) ->
    Server = ?config(server, Config),
    jid:make(<<>>, <<"mix.", Server/binary>>, <<>>).

mix_room_jid(Config) ->
    Server = ?config(server, Config),
    jid:make(<<"test">>, <<"mix.", Server/binary>>, <<>>).

id() ->
    id(<<>>).

id(<<>>) ->
    p1_rand:get_string();
id(ID) ->
    ID.

set_opt(Opt, Val, Config) ->
    [{Opt, Val}|lists:keydelete(Opt, 1, Config)].

wait_for_master(Config) ->
    put_event(Config, peer_ready),
    case get_event(Config) of
	peer_ready ->
	    ok;
	Other ->
	    suite:match_failure(Other, peer_ready)
    end.

wait_for_slave(Config) ->
    put_event(Config, peer_ready),
    case get_event(Config) of
	peer_ready ->
	    ok;
	Other ->
	    suite:match_failure(Other, peer_ready)
    end.


set_roster(Config, Subscription, Groups) ->
    PeerJID = ?config(peer, Config),
    PeerBareJID = jid:remove_resource(PeerJID),
    ct:comment("Adding ~s to roster with subscription '~s' in groups ~p",
	       [jid:encode(PeerBareJID), Subscription, Groups]),
    Config.

del_roster(Config) ->
    del_roster(Config, ?config(peer, Config)).

del_roster(Config, PeerJID) ->
    MyJID = my_jid(Config),
    {U, S, _} = jid:tolower(MyJID),
    PeerBareJID = jid:remove_resource(PeerJID),
    PeerLJID = jid:tolower(PeerBareJID),
    ct:comment("Removing ~s from roster", [jid:encode(PeerBareJID)]),
    {atomic, _} = mod_roster:del_roster(U, S, PeerLJID),
    Config.

get_roster(Config) ->
    {LUser, LServer, _} = jid:tolower(my_jid(Config)),
    mod_roster:get_roster(LUser, LServer).

recv_call(Config, Msg) ->
    Receiver = ?config(receiver, Config),
    Ref = make_ref(),
    Receiver ! {Ref, Msg},
    receive
	{Ref, Reply} ->
	    Reply
    end.

start_receiver(NS, Owner, Server, Port) ->
    MRef = erlang:monitor(process, Owner),
    {ok, Socket} = xmpp_socket:connect(
		     Server, Port,
		     [binary, {packet, 0}, {active, false}], infinity),
    receiver(NS, Owner, Socket, MRef).

receiver(NS, Owner, Socket, MRef) ->
    receive
	{Ref, reset_stream} ->
	    Socket1 = xmpp_socket:reset_stream(Socket),
	    Owner ! {Ref, ok},
	    receiver(NS, Owner, Socket1, MRef);
	{Ref, {starttls, Certfile}} ->
	    {ok, TLSSocket} = xmpp_socket:starttls(
				Socket,
				[{certfile, Certfile}, connect]),
	    Owner ! {Ref, ok},
	    receiver(NS, Owner, TLSSocket, MRef);
	{Ref, compress} ->
	    {ok, ZlibSocket} = xmpp_socket:compress(Socket),
	    Owner ! {Ref, ok},
	    receiver(NS, Owner, ZlibSocket, MRef);
	{Ref, {send_text, Text}} ->
	    Ret = xmpp_socket:send(Socket, Text),
	    Owner ! {Ref, Ret},
	    receiver(NS, Owner, Socket, MRef);
	{Ref, close} ->
	    xmpp_socket:close(Socket),
	    Owner ! {Ref, ok},
	    receiver(NS, Owner, Socket, MRef);
        {'$gen_event', {xmlstreamelement, El}} ->
	    Owner ! decode_stream_element(NS, El),
	    receiver(NS, Owner, Socket, MRef);
	{'$gen_event', {xmlstreamstart, Name, Attrs}} ->
	    Owner ! decode(#xmlel{name = Name, attrs = Attrs}, <<>>, []),
	    receiver(NS, Owner, Socket, MRef);
	{'$gen_event', Event} ->
            Owner ! Event,
	    receiver(NS, Owner, Socket, MRef);
	{'DOWN', MRef, process, Owner, _} ->
	    ok;
	{tcp, _, Data} ->
	    case xmpp_socket:recv(Socket, Data) of
		{ok, Socket1} ->
		    receiver(NS, Owner, Socket1, MRef);
		{error, _} ->
		    Owner ! closed,
		    receiver(NS, Owner, Socket, MRef)
	    end;
	{tcp_error, _, _} ->
	    Owner ! closed,
	    receiver(NS, Owner, Socket, MRef);
	{tcp_closed, _} ->
	    Owner ! closed,
	    receiver(NS, Owner, Socket, MRef)
    end.

%%%===================================================================
%%% Clients puts and gets events via this relay.
%%%===================================================================
start_event_relay() ->
    spawn(fun event_relay/0).

stop_event_relay(Config) ->
    Pid = ?config(event_relay, Config),
    exit(Pid, normal).

event_relay() ->
    event_relay([], []).

event_relay(Events, Subscribers) ->
    receive
        {subscribe, From} ->
	    erlang:monitor(process, From),
            From ! {ok, self()},
            lists:foreach(
              fun(Event) -> From ! {event, Event, self()}
              end, Events),
            event_relay(Events, [From|Subscribers]);
        {put, Event, From} ->
            From ! {ok, self()},
            lists:foreach(
              fun(Pid) when Pid /= From ->
                      Pid ! {event, Event, self()};
                 (_) ->
                      ok
              end, Subscribers),
            event_relay([Event|Events], Subscribers);
	{'DOWN', _MRef, process, Pid, _Info} ->
	    case lists:member(Pid, Subscribers) of
		true ->
		    NewSubscribers = lists:delete(Pid, Subscribers),
		    lists:foreach(
		      fun(Subscriber) ->
			      Subscriber ! {event, peer_down, self()}
		      end, NewSubscribers),
		    event_relay(Events, NewSubscribers);
		false ->
		    event_relay(Events, Subscribers)
	    end
    end.

subscribe_to_events(Config) ->
    Relay = ?config(event_relay, Config),
    Relay ! {subscribe, self()},
    receive
        {ok, Relay} ->
            ok
    end.

put_event(Config, Event) ->
    Relay = ?config(event_relay, Config),
    Relay ! {put, Event, self()},
    receive
        {ok, Relay} ->
            ok
    end.

get_event(Config) ->
    Relay = ?config(event_relay, Config),
    receive
        {event, Event, Relay} ->
            Event
    end.

flush(Config) ->
    receive
	{event, peer_down, _} -> flush(Config);
	closed -> flush(Config);
	Msg -> ct:fail({unexpected_msg, Msg})
    after 0 ->
	    ok
    end.