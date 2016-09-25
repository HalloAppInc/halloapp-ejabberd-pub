%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2002-2016, ProcessOne
%%% @doc
%%%
%%% @end
%%% Created :  2 Jun 2013 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(ejabberd_SUITE).

-compile(export_all).

-import(suite, [init_config/1, connect/1, disconnect/1,
                recv/1, send/2, send_recv/2, my_jid/1, server_jid/1,
                pubsub_jid/1, proxy_jid/1, muc_jid/1, muc_room_jid/1,
		mix_jid/1, mix_room_jid/1, get_features/2, re_register/1,
                is_feature_advertised/2, subscribe_to_events/1,
                is_feature_advertised/3, set_opt/3, auth_SASL/2,
                wait_for_master/1, wait_for_slave/1,
                make_iq_result/1, start_event_relay/0,
                stop_event_relay/1, put_event/2, get_event/1,
                bind/1, auth/1, auth/2, open_session/1, open_session/2,
		zlib/1, starttls/1, starttls/2, close_socket/1, init_stream/1,
		auth_legacy/2, auth_legacy/3, tcp_connect/1, send_text/2]).

-include("suite.hrl").

suite() ->
    [{timetrap, {seconds,30}}].

init_per_suite(Config) ->
    NewConfig = init_config(Config),
    DataDir = proplists:get_value(data_dir, NewConfig),
    {ok, CWD} = file:get_cwd(),
    ExtAuthScript = filename:join([DataDir, "extauth.py"]),
    LDIFFile = filename:join([DataDir, "ejabberd.ldif"]),
    {ok, _} = file:copy(ExtAuthScript, filename:join([CWD, "extauth.py"])),
    {ok, _} = ldap_srv:start(LDIFFile),
    inet_db:add_host({127,0,0,1}, [binary_to_list(?S2S_VHOST),
				   binary_to_list(?MNESIA_VHOST)]),
    inet_db:set_domain(binary_to_list(randoms:get_string())),
    inet_db:set_lookup([file, native]),
    start_ejabberd(NewConfig),
    NewConfig.

start_ejabberd(Config) ->
    case proplists:get_value(backends, Config) of
        all ->
            ok = application:start(ejabberd, transient);
        Backends when is_list(Backends) ->
            Hosts = lists:map(fun(Backend) -> Backend ++ ".localhost" end, Backends),
            application:load(ejabberd),
            AllHosts = Hosts ++ ["localhost"],    %% We always need localhost for the generic no_db tests
            application:set_env(ejabberd, hosts, AllHosts),
            ok = application:start(ejabberd, transient)
    end.

end_per_suite(_Config) ->
    application:stop(ejabberd).

-define(BACKENDS, [mnesia,redis,mysql,pgsql,sqlite,ldap,extauth,riak]).

init_per_group(Group, Config) ->
    case lists:member(Group, ?BACKENDS) of
        false ->
            %% Not a backend related group, do default init:
            do_init_per_group(Group, Config);
        true ->
            case proplists:get_value(backends, Config) of
                all ->
                    %% All backends enabled
                    do_init_per_group(Group, Config);
                Backends ->
                    %% Skipped backends that were not explicitely enabled
                    case lists:member(atom_to_list(Group), Backends) of
                        true ->
                            do_init_per_group(Group, Config);
                        false ->
                            {skip, {disabled_backend, Group}}
                    end
            end
    end.

do_init_per_group(no_db, Config) ->
    re_register(Config),
    Config;
do_init_per_group(mnesia, Config) ->
    mod_muc:shutdown_rooms(?MNESIA_VHOST),
    set_opt(server, ?MNESIA_VHOST, Config);
do_init_per_group(redis, Config) ->
    mod_muc:shutdown_rooms(?REDIS_VHOST),
    set_opt(server, ?REDIS_VHOST, Config);
do_init_per_group(mysql, Config) ->
    case catch ejabberd_sql:sql_query(?MYSQL_VHOST, [<<"select 1;">>]) of
        {selected, _, _} ->
            mod_muc:shutdown_rooms(?MYSQL_VHOST),
            create_sql_tables(mysql, ?config(base_dir, Config)),
            set_opt(server, ?MYSQL_VHOST, Config);
        Err ->
            {skip, {mysql_not_available, Err}}
    end;
do_init_per_group(pgsql, Config) ->
    case catch ejabberd_sql:sql_query(?PGSQL_VHOST, [<<"select 1;">>]) of
        {selected, _, _} ->
            mod_muc:shutdown_rooms(?PGSQL_VHOST),
            create_sql_tables(pgsql, ?config(base_dir, Config)),
            set_opt(server, ?PGSQL_VHOST, Config);
        Err ->
            {skip, {pgsql_not_available, Err}}
    end;
do_init_per_group(sqlite, Config) ->
    case catch ejabberd_sql:sql_query(?SQLITE_VHOST, [<<"select 1;">>]) of
        {selected, _, _} ->
            mod_muc:shutdown_rooms(?SQLITE_VHOST),
            set_opt(server, ?SQLITE_VHOST, Config);
        Err ->
            {skip, {sqlite_not_available, Err}}
    end;
do_init_per_group(ldap, Config) ->
    set_opt(server, ?LDAP_VHOST, Config);
do_init_per_group(extauth, Config) ->
    set_opt(server, ?EXTAUTH_VHOST, Config);
do_init_per_group(riak, Config) ->
    case ejabberd_riak:is_connected() of
	true ->
	    mod_muc:shutdown_rooms(?RIAK_VHOST),
	    NewConfig = set_opt(server, ?RIAK_VHOST, Config),
	    clear_riak_tables(NewConfig);
	Err ->
	    {skip, {riak_not_available, Err}}
    end;
do_init_per_group(s2s, Config) ->
    ejabberd_config:add_option(s2s_use_starttls, required_trusted),
    ejabberd_config:add_option(domain_certfile, "cert.pem"),
    Port = ?config(s2s_port, Config),
    set_opt(server, ?COMMON_VHOST,
	    set_opt(xmlns, ?NS_SERVER,
		    set_opt(type, server,
			    set_opt(server_port, Port,
				    set_opt(stream_from, ?S2S_VHOST,
					    set_opt(lang, <<"">>, Config))))));
do_init_per_group(component, Config) ->
    Server = ?config(server, Config),
    Port = ?config(component_port, Config),
    set_opt(xmlns, ?NS_COMPONENT,
            set_opt(server, <<"component.", Server/binary>>,
                    set_opt(type, component,
                            set_opt(server_port, Port,
                                    set_opt(stream_version, undefined,
                                            set_opt(lang, <<"">>, Config))))));
do_init_per_group(GroupName, Config) ->
    Pid = start_event_relay(),
    NewConfig = set_opt(event_relay, Pid, Config),
    case GroupName of
	anonymous -> set_opt(anonymous, true, NewConfig);
	_ -> NewConfig
    end.

end_per_group(mnesia, _Config) ->
    ok;
end_per_group(redis, _Config) ->
    ok;
end_per_group(mysql, _Config) ->
    ok;
end_per_group(pgsql, _Config) ->
    ok;
end_per_group(sqlite, _Config) ->
    ok;
end_per_group(no_db, _Config) ->
    ok;
end_per_group(ldap, _Config) ->
    ok;
end_per_group(extauth, _Config) ->
    ok;
end_per_group(riak, _Config) ->
    ok;
end_per_group(component, _Config) ->
    ok;
end_per_group(s2s, _Config) ->
    ejabberd_config:add_option(s2s_use_starttls, false);
end_per_group(_GroupName, Config) ->
    stop_event_relay(Config),
    set_opt(anonymous, false, Config).

init_per_testcase(stop_ejabberd, Config) ->
    open_session(bind(auth(connect(Config))));
init_per_testcase(TestCase, OrigConfig) ->
    subscribe_to_events(OrigConfig),
    TestGroup = proplists:get_value(
		  name, ?config(tc_group_properties, OrigConfig)),
    Server = ?config(server, OrigConfig),
    Resource = case TestGroup of
		   anonymous ->
		       <<"">>;
		   legacy_auth ->
		       randoms:get_string();
		   _ ->
		       ?config(resource, OrigConfig)
	       end,
    MasterResource = ?config(master_resource, OrigConfig),
    SlaveResource = ?config(slave_resource, OrigConfig),
    Test = atom_to_list(TestCase),
    IsMaster = lists:suffix("_master", Test),
    IsSlave = lists:suffix("_slave", Test),
    IsCarbons = lists:prefix("carbons_", Test),
    IsReplaced = lists:prefix("replaced_", Test),
    User = if IsReplaced -> <<"test_single!#$%^*()`~+-;_=[]{}|\\">>;
	      IsMaster or IsCarbons -> <<"test_master!#$%^*()`~+-;_=[]{}|\\">>;
              IsSlave -> <<"test_slave!#$%^*()`~+-;_=[]{}|\\">>;
              true -> <<"test_single!#$%^*()`~+-;_=[]{}|\\">>
           end,
    MyResource = if IsMaster and IsCarbons -> MasterResource;
		    IsSlave and IsCarbons -> SlaveResource;
		    true -> Resource
		 end,
    Slave = if IsCarbons ->
		    jid:make(<<"test_master!#$%^*()`~+-;_=[]{}|\\">>, Server, SlaveResource);
	       IsReplaced ->
		    jid:make(User, Server, Resource);
	       true ->
		    jid:make(<<"test_slave!#$%^*()`~+-;_=[]{}|\\">>, Server, Resource)
	    end,
    Master = if IsCarbons ->
		     jid:make(<<"test_master!#$%^*()`~+-;_=[]{}|\\">>, Server, MasterResource);
		IsReplaced ->
		     jid:make(User, Server, Resource);
		true ->
		     jid:make(<<"test_master!#$%^*()`~+-;_=[]{}|\\">>, Server, Resource)
	     end,
    Config = set_opt(user, User,
                     set_opt(slave, Slave,
                             set_opt(master, Master,
				     set_opt(resource, MyResource, OrigConfig)))),
    case Test of
        "test_connect" ++ _ ->
            Config;
	"test_legacy_auth" ++ _ ->
	    init_stream(set_opt(stream_version, undefined, Config));
        "test_auth" ++ _ ->
            connect(Config);
        "test_starttls" ++ _ ->
            connect(Config);
        "test_zlib" ->
            connect(Config);
        "test_register" ->
            connect(Config);
        "auth_md5" ->
            connect(Config);
        "auth_plain" ->
            connect(Config);
	"unauthenticated_" ++ _ ->
	    connect(Config);
        "test_bind" ->
            auth(connect(Config));
	"sm_resume" ->
	    auth(connect(Config));
	"sm_resume_failed" ->
	    auth(connect(Config));
        "test_open_session" ->
            bind(auth(connect(Config)));
	"replaced" ++ _ ->
	    auth(connect(Config));
        _ when IsMaster or IsSlave ->
            Password = ?config(password, Config),
            ejabberd_auth:try_register(User, Server, Password),
            open_session(bind(auth(connect(Config))));
	_ when TestGroup == s2s_tests ->
	    auth(connect(starttls(connect(Config))));
        _ ->
            open_session(bind(auth(connect(Config))))
    end.

end_per_testcase(_TestCase, _Config) ->
    ok.

legacy_auth_tests() ->
    {legacy_auth, [parallel],
     [test_legacy_auth,
      test_legacy_auth_digest,
      test_legacy_auth_no_resource,
      test_legacy_auth_bad_jid,
      test_legacy_auth_fail]}.

no_db_tests() ->
    [{anonymous, [parallel],
      [test_connect_bad_xml,
       test_connect_unexpected_xml,
       test_connect_unknown_ns,
       test_connect_bad_xmlns,
       test_connect_bad_ns_stream,
       test_connect_bad_lang,
       test_connect_bad_to,
       test_connect_missing_to,
       test_connect,
       unauthenticated_iq,
       unauthenticated_stanza,
       test_starttls,
       test_zlib,
       test_auth,
       test_bind,
       test_open_session,
       codec_failure,
       unsupported_query,
       bad_nonza,
       invalid_from,
       ping,
       version,
       time,
       stats,
       disco]},
     {presence_and_s2s, [sequence],
      [test_auth_fail,
       presence,
       s2s_dialback,
       s2s_optional,
       s2s_required,
       s2s_required_trusted]},
     {sm, [sequence],
       [sm,
	sm_resume,
	sm_resume_failed]},
     {test_proxy65, [parallel],
      [proxy65_master, proxy65_slave]},
     {replaced, [parallel],
      [replaced_master, replaced_slave]}].

db_tests(riak) ->
    %% No support for mod_pubsub
    [{single_user, [sequence],
      [test_register,
       legacy_auth_tests(),
       auth_plain,
       auth_md5,
       presence_broadcast,
       last,
       roster_get,
       private,
       privacy,
       blocking,
       vcard,
       test_unregister]},
     {test_muc_register, [sequence],
      [muc_register_master, muc_register_slave]},
     {test_roster_subscribe, [parallel],
      [roster_subscribe_master,
       roster_subscribe_slave]},
     {test_flex_offline, [sequence],
      [flex_offline_master, flex_offline_slave]},
     {test_offline, [sequence],
      [offline_master, offline_slave]},
     {test_muc, [parallel],
      [muc_master, muc_slave]},
     {test_announce, [sequence],
      [announce_master, announce_slave]},
     {test_vcard_xupdate, [parallel],
      [vcard_xupdate_master, vcard_xupdate_slave]},
     {test_roster_remove, [parallel],
      [roster_remove_master,
       roster_remove_slave]}];
db_tests(DB) when DB == mnesia; DB == redis ->
    [{single_user, [sequence],
      [test_register,
       legacy_auth_tests(),
       auth_plain,
       auth_md5,
       presence_broadcast,
       last,
       roster_get,
       roster_ver,
       private,
       privacy,
       blocking,
       vcard,
       pubsub,
       test_unregister]},
     {test_muc_register, [sequence],
      [muc_register_master, muc_register_slave]},
     {test_mix, [parallel],
      [mix_master, mix_slave]},
     {test_roster_subscribe, [parallel],
      [roster_subscribe_master,
       roster_subscribe_slave]},
     {test_flex_offline, [sequence],
      [flex_offline_master, flex_offline_slave]},
     {test_offline, [sequence],
      [offline_master, offline_slave]},
     {test_old_mam, [parallel],
      [mam_old_master, mam_old_slave]},
     {test_new_mam, [parallel],
      [mam_new_master, mam_new_slave]},
     {test_carbons, [parallel],
      [carbons_master, carbons_slave]},
     {test_client_state, [parallel],
      [client_state_master, client_state_slave]},
     {test_muc, [parallel],
      [muc_master, muc_slave]},
     {test_muc_mam, [parallel],
      [muc_mam_master, muc_mam_slave]},
     {test_announce, [sequence],
      [announce_master, announce_slave]},
     {test_vcard_xupdate, [parallel],
      [vcard_xupdate_master, vcard_xupdate_slave]},
     {test_roster_remove, [parallel],
      [roster_remove_master,
       roster_remove_slave]}];
db_tests(_) ->
    %% No support for carboncopy
    [{single_user, [sequence],
      [test_register,
       legacy_auth_tests(),
       auth_plain,
       auth_md5,
       presence_broadcast,
       last,
       roster_get,
       roster_ver,
       private,
       privacy,
       blocking,
       vcard,
       pubsub,
       test_unregister]},
     {test_muc_register, [sequence],
      [muc_register_master, muc_register_slave]},
     {test_mix, [parallel],
      [mix_master, mix_slave]},
     {test_roster_subscribe, [parallel],
      [roster_subscribe_master,
       roster_subscribe_slave]},
     {test_flex_offline, [sequence],
      [flex_offline_master, flex_offline_slave]},
     {test_offline, [sequence],
      [offline_master, offline_slave]},
     {test_old_mam, [parallel],
      [mam_old_master, mam_old_slave]},
     {test_new_mam, [parallel],
      [mam_new_master, mam_new_slave]},
     {test_muc, [parallel],
      [muc_master, muc_slave]},
     {test_muc_mam, [parallel],
      [muc_mam_master, muc_mam_slave]},
     {test_announce, [sequence],
      [announce_master, announce_slave]},
     {test_vcard_xupdate, [parallel],
      [vcard_xupdate_master, vcard_xupdate_slave]},
     {test_roster_remove, [parallel],
      [roster_remove_master,
       roster_remove_slave]}].

ldap_tests() ->
    [{ldap_tests, [sequence],
      [test_auth,
       test_auth_fail,
       vcard_get,
       ldap_shared_roster_get]}].

extauth_tests() ->
    [{extauth_tests, [sequence],
      [test_auth,
       test_auth_fail,
       test_unregister]}].

component_tests() ->
    [{component_connect, [parallel],
      [test_connect_bad_xml,
       test_connect_unexpected_xml,
       test_connect_unknown_ns,
       test_connect_bad_xmlns,
       test_connect_bad_ns_stream,
       test_connect_missing_to,
       test_connect,
       test_auth,
       test_auth_fail]},
     {component_tests, [sequence],
      [test_missing_address,
       test_invalid_from,
       test_component_send,
       bad_nonza,
       codec_failure]}].

s2s_tests() ->
    [{s2s_connect, [parallel],
      [test_connect_bad_xml,
       test_connect_unexpected_xml,
       test_connect_unknown_ns,
       test_connect_bad_xmlns,
       test_connect_bad_ns_stream,
       test_connect,
       test_connect_s2s_starttls_required,
       test_starttls,
       test_connect_missing_from,
       test_connect_s2s_unauthenticated_iq,
       test_auth_starttls]},
     {s2s_tests, [sequence],
      [test_missing_address,
       test_invalid_from,
       bad_nonza,
       codec_failure]}].

groups() ->
    [{ldap, [sequence], ldap_tests()},
     {extauth, [sequence], extauth_tests()},
     {no_db, [sequence], no_db_tests()},
     {component, [sequence], component_tests()},
     {s2s, [sequence], s2s_tests()},
     {mnesia, [sequence], db_tests(mnesia)},
     {redis, [sequence], db_tests(redis)},
     {mysql, [sequence], db_tests(mysql)},
     {pgsql, [sequence], db_tests(pgsql)},
     {sqlite, [sequence], db_tests(sqlite)},
     {riak, [sequence], db_tests(riak)}].

all() ->
    [%%{group, ldap},
     {group, no_db},
     %% {group, mnesia},
     %% {group, redis},
     %% {group, mysql},
     %% {group, pgsql},
     %% {group, sqlite},
     %% {group, extauth},
     %% {group, riak},
     %% {group, component},
     %% {group, s2s},
     stop_ejabberd].

stop_ejabberd(Config) ->
    ok = application:stop(ejabberd),
    ?recv1(#stream_error{reason = 'system-shutdown'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    Config.

test_connect_bad_xml(Config) ->
    Config0 = tcp_connect(Config),
    send_text(Config0, <<"<'/>">>),
    Version = ?config(stream_version, Config0),
    ?recv1(#stream_start{version = Version}),
    ?recv1(#stream_error{reason = 'not-well-formed'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config0).

test_connect_unexpected_xml(Config) ->
    Config0 = tcp_connect(Config),
    send(Config0, #caps{}),
    Version = ?config(stream_version, Config0),
    ?recv1(#stream_start{version = Version}),
    ?recv1(#stream_error{reason = 'invalid-xml'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config0).

test_connect_unknown_ns(Config) ->
    Config0 = init_stream(set_opt(xmlns, <<"wrong">>, Config)),
    ?recv1(#stream_error{reason = 'invalid-xml'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config0).

test_connect_bad_xmlns(Config) ->
    NS = case ?config(type, Config) of
	     client -> ?NS_SERVER;
	     _ -> ?NS_CLIENT
	 end,
    Config0 = init_stream(set_opt(xmlns, NS, Config)),
    ?recv1(#stream_error{reason = 'invalid-namespace'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config0).

test_connect_bad_ns_stream(Config) ->
    Config0 = init_stream(set_opt(ns_stream, <<"wrong">>, Config)),
    ?recv1(#stream_error{reason = 'invalid-namespace'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config0).

test_connect_bad_lang(Config) ->
    Config0 = init_stream(set_opt(lang, lists:duplicate(36, $x), Config)),
    ?recv1(#stream_error{reason = 'policy-violation'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config0).

test_connect_bad_to(Config) ->
    Config0 = init_stream(set_opt(server, <<"wrong.com">>, Config)),
    ?recv1(#stream_error{reason = 'host-unknown'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config0).

test_connect_missing_to(Config) ->
    Config0 = init_stream(set_opt(server, <<"">>, Config)),
    ?recv1(#stream_error{reason = 'improper-addressing'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config0).

test_connect_missing_from(Config) ->
    Config1 = starttls(connect(Config)),
    Config2 = set_opt(stream_from, <<"">>, Config1),
    Config3 = init_stream(Config2),
    ?recv1(#stream_error{reason = 'policy-violation'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config3).

test_connect(Config) ->
    disconnect(connect(Config)).

test_connect_s2s_starttls_required(Config) ->
    Config1 = connect(Config),
    send(Config1, #caps{}),
    ?recv1(#stream_error{reason = 'policy-violation'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config1).

test_connect_s2s_unauthenticated_iq(Config) ->
    Config1 = connect(starttls(connect(Config))),
    unauthenticated_iq(Config1).

test_starttls(Config) ->
    case ?config(starttls, Config) of
        true ->
            disconnect(connect(starttls(Config)));
        _ ->
            {skipped, 'starttls_not_available'}
    end.

test_zlib(Config) ->
    case ?config(compression, Config) of
        [_|_] = Ms ->
            case lists:member(<<"zlib">>, Ms) of
                true ->
                    disconnect(zlib(Config));
                false ->
                    {skipped, 'zlib_not_available'}
            end;
        _ ->
            {skipped, 'compression_not_available'}
    end.

test_register(Config) ->
    case ?config(register, Config) of
        true ->
            disconnect(register(Config));
        _ ->
            {skipped, 'registration_not_available'}
    end.

register(Config) ->
    #iq{type = result,
        sub_els = [#register{username = <<>>,
                             password = <<>>}]} =
        send_recv(Config, #iq{type = get, to = server_jid(Config),
                              sub_els = [#register{}]}),
    #iq{type = result, sub_els = []} =
        send_recv(
          Config,
          #iq{type = set,
              sub_els = [#register{username = ?config(user, Config),
                                   password = ?config(password, Config)}]}),
    Config.

test_unregister(Config) ->
    case ?config(register, Config) of
        true ->
            try_unregister(Config);
        _ ->
            {skipped, 'registration_not_available'}
    end.

try_unregister(Config) ->
    true = is_feature_advertised(Config, ?NS_REGISTER),
    #iq{type = result, sub_els = []} =
        send_recv(
          Config,
          #iq{type = set,
              sub_els = [#register{remove = true}]}),
    ?recv1(#stream_error{reason = conflict}),
    Config.

unauthenticated_stanza(Config) ->
    %% Unauthenticated stanza should be silently dropped.
    send(Config, #message{to = server_jid(Config)}),
    disconnect(Config).

unauthenticated_iq(Config) ->
    From = my_jid(Config),
    To = server_jid(Config),
    #iq{type = error} =
	send_recv(Config, #iq{type = get, from = From, to = To,
			      sub_els = [#disco_info{}]}),
    disconnect(Config).

bad_nonza(Config) ->
    %% Unsupported and invalid nonza should be silently dropped.
    send(Config, #caps{}),
    send(Config, #stanza_error{type = wrong}),
    disconnect(Config).

invalid_from(Config) ->
    send(Config, #message{from = jid:make(randoms:get_string())}),
    ?recv1(#stream_error{reason = 'invalid-from'}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config).

test_missing_address(Config) ->
    Server = server_jid(Config),
    #iq{type = error} = send_recv(Config, #iq{type = get, from = Server}),
    #iq{type = error} = send_recv(Config, #iq{type = get, to = Server}),
    disconnect(Config).

test_invalid_from(Config) ->
    From = jid:make(randoms:get_string()),
    To = jid:make(randoms:get_string()),
    #iq{type = error} =
	send_recv(Config, #iq{type = get, from = From, to = To}),
    disconnect(Config).

test_component_send(Config) ->
    To = jid:make(?COMMON_VHOST),
    From = server_jid(Config),
    #iq{type = result, from = To, to = From} =
	send_recv(Config, #iq{type = get, to = To, from = From,
			      sub_els = [#ping{}]}),
    disconnect(Config).

s2s_dialback(Config) ->
    ejabberd_s2s:stop_all_connections(),
    ejabberd_config:add_option(s2s_use_starttls, false),
    ejabberd_config:add_option(domain_certfile, "self-signed-cert.pem"),
    s2s_ping(Config).

s2s_optional(Config) ->
    ejabberd_s2s:stop_all_connections(),
    ejabberd_config:add_option(s2s_use_starttls, optional),
    ejabberd_config:add_option(domain_certfile, "self-signed-cert.pem"),
    s2s_ping(Config).

s2s_required(Config) ->
    ejabberd_s2s:stop_all_connections(),
    ejabberd_config:add_option(s2s_use_starttls, required),
    ejabberd_config:add_option(domain_certfile, "self-signed-cert.pem"),
    s2s_ping(Config).

s2s_required_trusted(Config) ->
    ejabberd_s2s:stop_all_connections(),
    ejabberd_config:add_option(s2s_use_starttls, required),
    ejabberd_config:add_option(domain_certfile, "cert.pem"),
    s2s_ping(Config).

s2s_ping(Config) ->
    From = my_jid(Config),
    To = jid:make(?MNESIA_VHOST),
    ID = randoms:get_string(),
    ejabberd_s2s:route(From, To, #iq{id = ID, type = get, sub_els = [#ping{}]}),
    ?recv1(#iq{type = result, id = ID, sub_els = []}),
    disconnect(Config).

auth_md5(Config) ->
    Mechs = ?config(mechs, Config),
    case lists:member(<<"DIGEST-MD5">>, Mechs) of
        true ->
            disconnect(auth_SASL(<<"DIGEST-MD5">>, Config));
        false ->
            disconnect(Config),
            {skipped, 'DIGEST-MD5_not_available'}
    end.

auth_plain(Config) ->
    Mechs = ?config(mechs, Config),
    case lists:member(<<"PLAIN">>, Mechs) of
        true ->
            disconnect(auth_SASL(<<"PLAIN">>, Config));
        false ->
            disconnect(Config),
            {skipped, 'PLAIN_not_available'}
    end.

test_legacy_auth(Config) ->
    disconnect(auth_legacy(Config, _Digest = false)).

test_legacy_auth_digest(Config) ->
    disconnect(auth_legacy(Config, _Digest = true)).

test_legacy_auth_no_resource(Config0) ->
    Config = set_opt(resource, <<"">>, Config0),
    disconnect(auth_legacy(Config, _Digest = false, _ShouldFail = true)).

test_legacy_auth_bad_jid(Config0) ->
    Config = set_opt(user, <<"@">>, Config0),
    disconnect(auth_legacy(Config, _Digest = false, _ShouldFail = true)).

test_legacy_auth_fail(Config0) ->
    Config = set_opt(user, <<"wrong">>, Config0),
    disconnect(auth_legacy(Config, _Digest = false, _ShouldFail = true)).

test_auth(Config) ->
    disconnect(auth(Config)).

test_auth_starttls(Config) ->
    disconnect(auth(connect(starttls(Config)))).

test_auth_fail(Config0) ->
    Config = set_opt(user, <<"wrong">>,
		     set_opt(password, <<"wrong">>, Config0)),
    disconnect(auth(Config, _ShouldFail = true)).

test_bind(Config) ->
    disconnect(bind(Config)).

test_open_session(Config) ->
    disconnect(open_session(Config, true)).

roster_get(Config) ->
    #iq{type = result, sub_els = [#roster_query{items = []}]} =
        send_recv(Config, #iq{type = get, sub_els = [#roster_query{}]}),
    disconnect(Config).

roster_ver(Config) ->
    %% Get initial "ver"
    #iq{type = result, sub_els = [#roster_query{ver = Ver1, items = []}]} =
        send_recv(Config, #iq{type = get,
                              sub_els = [#roster_query{ver = <<"">>}]}),
    %% Should receive empty IQ-result
    #iq{type = result, sub_els = []} =
        send_recv(Config, #iq{type = get,
                              sub_els = [#roster_query{ver = Ver1}]}),
    %% Attempting to subscribe to server's JID
    send(Config, #presence{type = subscribe, to = server_jid(Config)}),
    %% Receive a single roster push with the new "ver"
    #iq{type = set, sub_els = [#roster_query{ver = Ver2}]} = recv(Config),
    %% Requesting roster with the previous "ver". Should receive Ver2 again
    #iq{type = result, sub_els = [#roster_query{ver = Ver2}]} =
        send_recv(Config, #iq{type = get,
                              sub_els = [#roster_query{ver = Ver1}]}),
    %% Now requesting roster with the newest "ver". Should receive empty IQ.
    #iq{type = result, sub_els = []} =
        send_recv(Config, #iq{type = get,
                              sub_els = [#roster_query{ver = Ver2}]}),
    disconnect(Config).

codec_failure(Config) ->
    JID = my_jid(Config),
    #iq{type = error} =
	send_recv(Config, #iq{type = wrong, from = JID, to = JID}),
    disconnect(Config).

unsupported_query(Config) ->
    ServerJID = server_jid(Config),
    #iq{type = error} = send_recv(Config, #iq{type = get, to = ServerJID}),
    #iq{type = error} = send_recv(Config, #iq{type = get, to = ServerJID,
					      sub_els = [#caps{}]}),
    #iq{type = error} = send_recv(Config, #iq{type = get, to = ServerJID,
					      sub_els = [#roster_query{},
							 #disco_info{},
							 #privacy_query{}]}),
    disconnect(Config).

presence(Config) ->
    send(Config, #presence{}),
    JID = my_jid(Config),
    ?recv1(#presence{from = JID, to = JID}),
    disconnect(Config).

presence_broadcast(Config) ->
    Feature = <<"p1:tmp:", (randoms:get_string())/binary>>,
    Ver = crypto:hash(sha, ["client", $/, "bot", $/, "en", $/,
                            "ejabberd_ct", $<, Feature, $<]),
    B64Ver = base64:encode(Ver),
    Node = <<(?EJABBERD_CT_URI)/binary, $#, B64Ver/binary>>,
    Server = ?config(server, Config),
    ServerJID = server_jid(Config),
    Info = #disco_info{identities =
			   [#identity{category = <<"client">>,
				      type = <<"bot">>,
				      lang = <<"en">>,
				      name = <<"ejabberd_ct">>}],
		       node = Node, features = [Feature]},
    Caps = #caps{hash = <<"sha-1">>, node = ?EJABBERD_CT_URI, version = B64Ver},
    send(Config, #presence{sub_els = [Caps]}),
    JID = my_jid(Config),
    %% We receive:
    %% 1) disco#info iq request for CAPS
    %% 2) welcome message
    %% 3) presence broadcast
    {IQ, _, _} = ?recv3(#iq{type = get,
			    from = ServerJID,
			    sub_els = [#disco_info{node = Node}]},
			#message{type = normal},
			#presence{from = JID, to = JID}),
    send(Config, #iq{type = result, id = IQ#iq.id,
		     to = ServerJID, sub_els = [Info]}),
    %% We're trying to read our feature from ejabberd database
    %% with exponential back-off as our IQ response may be delayed.
    [Feature] =
	lists:foldl(
	  fun(Time, []) ->
		  timer:sleep(Time),
		  mod_caps:get_features(Server, Caps);
	     (_, Acc) ->
		  Acc
	  end, [], [0, 100, 200, 2000, 5000, 10000]),
    disconnect(Config).

ping(Config) ->
    true = is_feature_advertised(Config, ?NS_PING),
    #iq{type = result, sub_els = []} =
        send_recv(
          Config,
          #iq{type = get, sub_els = [#ping{}], to = server_jid(Config)}),
    disconnect(Config).

version(Config) ->
    true = is_feature_advertised(Config, ?NS_VERSION),
    #iq{type = result, sub_els = [#version{}]} =
        send_recv(
          Config, #iq{type = get, sub_els = [#version{}],
                      to = server_jid(Config)}),
    disconnect(Config).

time(Config) ->
    true = is_feature_advertised(Config, ?NS_TIME),
    #iq{type = result, sub_els = [#time{}]} =
        send_recv(Config, #iq{type = get, sub_els = [#time{}],
                              to = server_jid(Config)}),
    disconnect(Config).

disco(Config) ->
    true = is_feature_advertised(Config, ?NS_DISCO_INFO),
    true = is_feature_advertised(Config, ?NS_DISCO_ITEMS),
    #iq{type = result, sub_els = [#disco_items{items = Items}]} =
        send_recv(
          Config, #iq{type = get, sub_els = [#disco_items{}],
                      to = server_jid(Config)}),
    lists:foreach(
      fun(#disco_item{jid = JID, node = Node}) ->
              #iq{type = result} =
                  send_recv(Config,
                            #iq{type = get, to = JID,
                                sub_els = [#disco_info{node = Node}]})
      end, Items),
    disconnect(Config).

replaced_master(Config0) ->
    Config = bind(Config0),
    wait_for_slave(Config),
    ?recv1(#stream_error{reason = conflict}),
    ?recv1({xmlstreamend, <<"stream:stream">>}),
    close_socket(Config).

replaced_slave(Config0) ->
    wait_for_master(Config0),
    Config = bind(Config0),
    disconnect(Config).

sm(Config) ->
    Server = ?config(server, Config),
    ServerJID = jid:make(<<"">>, Server, <<"">>),
    %% Send messages of type 'headline' so the server discards them silently
    Msg = #message{to = ServerJID, type = headline,
		   body = [#text{data = <<"body">>}]},
    true = ?config(sm, Config),
    %% Enable the session management with resumption enabled
    send(Config, #sm_enable{resume = true, xmlns = ?NS_STREAM_MGMT_3}),
    #sm_enabled{id = ID, resume = true} = recv(Config),
    %% Initial request; 'h' should be 0.
    send(Config, #sm_r{xmlns = ?NS_STREAM_MGMT_3}),
    ?recv1(#sm_a{h = 0}),
    %% sending two messages and requesting again; 'h' should be 3.
    send(Config, Msg),
    send(Config, Msg),
    send(Config, Msg),
    send(Config, #sm_r{xmlns = ?NS_STREAM_MGMT_3}),
    ?recv1(#sm_a{h = 3}),
    close_socket(Config),
    {save_config, set_opt(sm_previd, ID, Config)}.

sm_resume(Config) ->
    {sm, SMConfig} = ?config(saved_config, Config),
    ID = ?config(sm_previd, SMConfig),
    Server = ?config(server, Config),
    ServerJID = jid:make(<<"">>, Server, <<"">>),
    MyJID = my_jid(Config),
    Txt = #text{data = <<"body">>},
    Msg = #message{from = ServerJID, to = MyJID, body = [Txt]},
    %% Route message. The message should be queued by the C2S process.
    ejabberd_router:route(ServerJID, MyJID, Msg),
    send(Config, #sm_resume{previd = ID, h = 0, xmlns = ?NS_STREAM_MGMT_3}),
    ?recv1(#sm_resumed{previd = ID, h = 3}),
    ?recv1(#message{from = ServerJID, to = MyJID, body = [Txt]}),
    ?recv1(#sm_r{}),
    send(Config, #sm_a{h = 1, xmlns = ?NS_STREAM_MGMT_3}),
    %% Send another stanza to increment the server's 'h' for sm_resume_failed.
    send(Config, #presence{to = ServerJID}),
    close_socket(Config),
    {save_config, set_opt(sm_previd, ID, Config)}.

sm_resume_failed(Config) ->
    {sm_resume, SMConfig} = ?config(saved_config, Config),
    ID = ?config(sm_previd, SMConfig),
    ct:sleep(5000), % Wait for session to time out.
    send(Config, #sm_resume{previd = ID, h = 1, xmlns = ?NS_STREAM_MGMT_3}),
    ?recv1(#sm_failed{reason = 'item-not-found', h = 4}),
    disconnect(Config).

private(Config) ->
    Conference = #bookmark_conference{name = <<"Some name">>,
                                      autojoin = true,
                                      jid = jid:make(
                                              <<"some">>,
                                              <<"some.conference.org">>,
                                              <<>>)},
    Storage = #bookmark_storage{conference = [Conference]},
    StorageXMLOut = xmpp:encode(Storage),
    WrongEl = #xmlel{name = <<"wrong">>},
    #iq{type = error} =
        send_recv(Config, #iq{type = get,
			      sub_els = [#private{xml_els = [WrongEl]}]}),
    #iq{type = result, sub_els = []} =
        send_recv(
          Config, #iq{type = set,
                      sub_els = [#private{xml_els = [WrongEl, StorageXMLOut]}]}),
    #iq{type = result,
        sub_els = [#private{xml_els = [StorageXMLIn]}]} =
        send_recv(
          Config,
          #iq{type = get,
              sub_els = [#private{xml_els = [xmpp:encode(
                                               #bookmark_storage{})]}]}),
    Storage = xmpp:decode(StorageXMLIn),
    disconnect(Config).

last(Config) ->
    true = is_feature_advertised(Config, ?NS_LAST),
    #iq{type = result, sub_els = [#last{}]} =
        send_recv(Config, #iq{type = get, sub_els = [#last{}],
                              to = server_jid(Config)}),
    disconnect(Config).

privacy(Config) ->
    true = is_feature_advertised(Config, ?NS_PRIVACY),
    #iq{type = result, sub_els = [#privacy_query{}]} =
        send_recv(Config, #iq{type = get, sub_els = [#privacy_query{}]}),
    JID = <<"tybalt@example.com">>,
    I1 = send(Config,
              #iq{type = set,
                  sub_els = [#privacy_query{
                                lists = [#privacy_list{
                                            name = <<"public">>,
                                            items =
                                                [#privacy_item{
                                                    type = jid,
                                                    order = 3,
                                                    action = deny,
						    presence_in = true,
                                                    value = JID}]}]}]}),
    {Push1, _} =
        ?recv2(
           #iq{type = set,
               sub_els = [#privacy_query{
                             lists = [#privacy_list{
                                         name = <<"public">>}]}]},
           #iq{type = result, id = I1, sub_els = []}),
    send(Config, make_iq_result(Push1)),
    #iq{type = result, sub_els = []} =
        send_recv(Config, #iq{type = set,
                              sub_els = [#privacy_query{active = <<"public">>}]}),
    #iq{type = result, sub_els = []} =
        send_recv(Config, #iq{type = set,
                              sub_els = [#privacy_query{default = <<"public">>}]}),
    #iq{type = result,
        sub_els = [#privacy_query{default = <<"public">>,
                            active = <<"public">>,
                            lists = [#privacy_list{name = <<"public">>}]}]} =
        send_recv(Config, #iq{type = get, sub_els = [#privacy_query{}]}),
    #iq{type = result, sub_els = []} =
        send_recv(Config,
                  #iq{type = set, sub_els = [#privacy_query{default = none}]}),
    #iq{type = result, sub_els = []} =
        send_recv(Config, #iq{type = set, sub_els = [#privacy_query{active = none}]}),
    I2 = send(Config, #iq{type = set,
                          sub_els = [#privacy_query{
                                        lists =
                                            [#privacy_list{
                                                name = <<"public">>}]}]}),
    {Push2, _} =
        ?recv2(
           #iq{type = set,
               sub_els = [#privacy_query{
                             lists = [#privacy_list{
                                         name = <<"public">>}]}]},
           #iq{type = result, id = I2, sub_els = []}),
    send(Config, make_iq_result(Push2)),
    disconnect(Config).

blocking(Config) ->
    true = is_feature_advertised(Config, ?NS_BLOCKING),
    JID = jid:make(<<"romeo">>, <<"montague.net">>, <<>>),
    #iq{type = result, sub_els = [#block_list{}]} =
        send_recv(Config, #iq{type = get, sub_els = [#block_list{}]}),
    I1 = send(Config, #iq{type = set,
                          sub_els = [#block{items = [JID]}]}),
    {Push1, Push2, _} =
        ?recv3(
           #iq{type = set,
               sub_els = [#privacy_query{lists = [#privacy_list{}]}]},
           #iq{type = set,
               sub_els = [#block{items = [JID]}]},
           #iq{type = result, id = I1, sub_els = []}),
    send(Config, make_iq_result(Push1)),
    send(Config, make_iq_result(Push2)),
    I2 = send(Config, #iq{type = set,
                          sub_els = [#unblock{items = [JID]}]}),
    {Push3, Push4, _} =
        ?recv3(
           #iq{type = set,
               sub_els = [#privacy_query{lists = [#privacy_list{}]}]},
           #iq{type = set,
               sub_els = [#unblock{items = [JID]}]},
           #iq{type = result, id = I2, sub_els = []}),
    send(Config, make_iq_result(Push3)),
    send(Config, make_iq_result(Push4)),
    disconnect(Config).

vcard(Config) ->
    true = is_feature_advertised(Config, ?NS_VCARD),
    VCard =
        #vcard_temp{fn = <<"Peter Saint-Andre">>,
               n = #vcard_name{family = <<"Saint-Andre">>,
                               given = <<"Peter">>},
               nickname = <<"stpeter">>,
               bday = <<"1966-08-06">>,
               adr = [#vcard_adr{work = true,
                                 extadd = <<"Suite 600">>,
                                 street = <<"1899 Wynkoop Street">>,
                                 locality = <<"Denver">>,
                                 region = <<"CO">>,
                                 pcode = <<"80202">>,
                                 ctry = <<"USA">>},
                      #vcard_adr{home = true,
                                 locality = <<"Denver">>,
                                 region = <<"CO">>,
                                 pcode = <<"80209">>,
                                 ctry = <<"USA">>}],
               tel = [#vcard_tel{work = true,voice = true,
                                 number = <<"303-308-3282">>},
                      #vcard_tel{home = true,voice = true,
                                 number = <<"303-555-1212">>}],
               email = [#vcard_email{internet = true,pref = true,
                                     userid = <<"stpeter@jabber.org">>}],
               jabberid = <<"stpeter@jabber.org">>,
               title = <<"Executive Director">>,role = <<"Patron Saint">>,
               org = #vcard_org{name = <<"XMPP Standards Foundation">>},
               url = <<"http://www.xmpp.org/xsf/people/stpeter.shtml">>,
               desc = <<"More information about me is located on my "
                        "personal website: http://www.saint-andre.com/">>},
    #iq{type = result, sub_els = []} =
        send_recv(Config, #iq{type = set, sub_els = [VCard]}),
    %% TODO: check if VCard == VCard1.
    #iq{type = result, sub_els = [_VCard1]} =
        send_recv(Config, #iq{type = get, sub_els = [#vcard_temp{}]}),
    disconnect(Config).

vcard_get(Config) ->
    true = is_feature_advertised(Config, ?NS_VCARD),
    %% TODO: check if VCard corresponds to LDIF data from ejabberd.ldif
    #iq{type = result, sub_els = [_VCard]} =
        send_recv(Config, #iq{type = get, sub_els = [#vcard_temp{}]}),
    disconnect(Config).

ldap_shared_roster_get(Config) ->
    Item = #roster_item{jid = jid:from_string(<<"user2@ldap.localhost">>), name = <<"Test User 2">>,
                        groups = [<<"group1">>], subscription = both},
    #iq{type = result, sub_els = [#roster_query{items = [Item]}]} =
        send_recv(Config, #iq{type = get, sub_els = [#roster_query{}]}),
    disconnect(Config).

vcard_xupdate_master(Config) ->
    Img = <<137, "PNG\r\n", 26, $\n>>,
    ImgHash = p1_sha:sha(Img),
    MyJID = my_jid(Config),
    Peer = ?config(slave, Config),
    wait_for_slave(Config),
    send(Config, #presence{}),
    ?recv2(#presence{from = MyJID, type = available},
           #presence{from = Peer, type = available}),
    VCard = #vcard_temp{photo = #vcard_photo{type = <<"image/png">>, binval = Img}},
    I1 = send(Config, #iq{type = set, sub_els = [VCard]}),
    ?recv2(#iq{type = result, sub_els = [], id = I1},
	   #presence{from = MyJID, type = available,
		     sub_els = [#vcard_xupdate{hash = ImgHash}]}),
    I2 = send(Config, #iq{type = set, sub_els = [#vcard_temp{}]}),
    ?recv3(#iq{type = result, sub_els = [], id = I2},
	   #presence{from = MyJID, type = available,
		     sub_els = [#vcard_xupdate{hash = undefined}]},
	   #presence{from = Peer, type = unavailable}),
    disconnect(Config).

vcard_xupdate_slave(Config) ->
    Img = <<137, "PNG\r\n", 26, $\n>>,
    ImgHash = p1_sha:sha(Img),
    MyJID = my_jid(Config),
    Peer = ?config(master, Config),
    send(Config, #presence{}),
    ?recv1(#presence{from = MyJID, type = available}),
    wait_for_master(Config),
    ?recv1(#presence{from = Peer, type = available}),
    ?recv1(#presence{from = Peer, type = available,
	      sub_els = [#vcard_xupdate{hash = ImgHash}]}),
    ?recv1(#presence{from = Peer, type = available,
	      sub_els = [#vcard_xupdate{hash = undefined}]}),
    disconnect(Config).

stats(Config) ->
    #iq{type = result, sub_els = [#stats{list = Stats}]} =
        send_recv(Config, #iq{type = get, sub_els = [#stats{}],
                              to = server_jid(Config)}),
    lists:foreach(
      fun(#stat{} = Stat) ->
              #iq{type = result, sub_els = [_|_]} =
                  send_recv(Config, #iq{type = get,
                                        sub_els = [#stats{list = [Stat]}],
                                        to = server_jid(Config)})
      end, Stats),
    disconnect(Config).

pubsub(Config) ->
    Features = get_features(Config, pubsub_jid(Config)),
    true = lists:member(?NS_PUBSUB, Features),
    %% Publish <presence/> element within node "presence"
    ItemID = randoms:get_string(),
    Node = <<"presence!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>,
    Item = #ps_item{id = ItemID,
                        xml_els = [xmpp:encode(#presence{})]},
    #iq{type = result,
        sub_els = [#pubsub{publish = #ps_publish{
                             node = Node,
                             items = [#ps_item{id = ItemID}]}}]} =
        send_recv(Config,
                  #iq{type = set, to = pubsub_jid(Config),
                      sub_els = [#pubsub{publish = #ps_publish{
                                           node = Node,
                                           items = [Item]}}]}),
    %% Subscribe to node "presence"
    I1 = send(Config,
             #iq{type = set, to = pubsub_jid(Config),
                 sub_els = [#pubsub{subscribe = #ps_subscribe{
                                      node = Node,
                                      jid = my_jid(Config)}}]}),
    ?recv2(
       #message{sub_els = [#ps_event{}, #delay{}]},
       #iq{type = result, id = I1}),
    %% Get subscriptions
    true = lists:member(?PUBSUB("retrieve-subscriptions"), Features),
    #iq{type = result,
        sub_els =
            [#pubsub{subscriptions =
                         {<<>>, [#ps_subscription{node = Node}]}}]} =
        send_recv(Config, #iq{type = get, to = pubsub_jid(Config),
                              sub_els = [#pubsub{subscriptions = {<<>>, []}}]}),
    %% Get affiliations
    true = lists:member(?PUBSUB("retrieve-affiliations"), Features),
    #iq{type = result,
        sub_els = [#pubsub{
                      affiliations =
                          {<<>>, [#ps_affiliation{node = Node, type = owner}]}}]} =
        send_recv(Config, #iq{type = get, to = pubsub_jid(Config),
                              sub_els = [#pubsub{affiliations = {<<>>, []}}]}),
    %% Fetching published items from node "presence"
    #iq{type = result,
        sub_els = [#pubsub{items = #ps_items{
                             node = Node,
                             items = [Item]}}]} =
        send_recv(Config,
                  #iq{type = get, to = pubsub_jid(Config),
                      sub_els = [#pubsub{items = #ps_items{node = Node}}]}),
    %% Deleting the item from the node
    true = lists:member(?PUBSUB("delete-items"), Features),
    I2 = send(Config,
              #iq{type = set, to = pubsub_jid(Config),
                  sub_els = [#pubsub{retract = #ps_retract{
                                       node = Node,
                                       items = [#ps_item{id = ItemID}]}}]}),
    ?recv2(
       #iq{type = result, id = I2, sub_els = []},
       #message{sub_els = [#ps_event{
                              items = #ps_items{
					 node = Node,
					 retract = ItemID}}]}),
    %% Unsubscribe from node "presence"
    #iq{type = result, sub_els = []} =
        send_recv(Config,
                  #iq{type = set, to = pubsub_jid(Config),
                      sub_els = [#pubsub{unsubscribe = #ps_unsubscribe{
                                           node = Node,
                                           jid = my_jid(Config)}}]}),
    disconnect(Config).

mix_master(Config) ->
    MIX = mix_jid(Config),
    Room = mix_room_jid(Config),
    MyJID = my_jid(Config),
    MyBareJID = jid:remove_resource(MyJID),
    true = is_feature_advertised(Config, ?NS_MIX_0, MIX),
    #iq{type = result,
	sub_els =
	    [#disco_info{
		identities = [#identity{category = <<"conference">>,
					type = <<"text">>}],
		xdata = [#xdata{type = result, fields = XFields}]}]} =
	send_recv(Config, #iq{type = get, to = MIX, sub_els = [#disco_info{}]}),
    true = lists:any(
	     fun(#xdata_field{var = <<"FORM_TYPE">>,
			      values = [?NS_MIX_SERVICEINFO_0]}) -> true;
		(_) -> false
	     end, XFields),
    %% Joining
    Nodes = [?NS_MIX_NODES_MESSAGES, ?NS_MIX_NODES_PRESENCE,
	     ?NS_MIX_NODES_PARTICIPANTS, ?NS_MIX_NODES_SUBJECT,
	     ?NS_MIX_NODES_CONFIG],
    I0 = send(Config, #iq{type = set, to = Room,
			  sub_els = [#mix_join{subscribe = Nodes}]}),
    {_, #message{sub_els =
		     [#ps_event{
			 items = #ps_items{
				    node = ?NS_MIX_NODES_PARTICIPANTS,
				    items = [#ps_item{
						id = ParticipantID,
						xml_els = [PXML]}]}}]}} =
	?recv2(#iq{type = result, id = I0,
		   sub_els = [#mix_join{subscribe = Nodes, jid = MyBareJID}]},
	       #message{from = Room}),
    #mix_participant{jid = MyBareJID} = xmpp:decode(PXML),
    %% Coming online
    PresenceID = randoms:get_string(),
    Presence = xmpp:encode(#presence{}),
    I1 = send(
	   Config,
	   #iq{type = set, to = Room,
	       sub_els =
		   [#pubsub{
		       publish = #ps_publish{
				    node = ?NS_MIX_NODES_PRESENCE,
				    items = [#ps_item{
						id = PresenceID,
						xml_els = [Presence]}]}}]}),
    ?recv2(#iq{type = result, id = I1,
	       sub_els =
		   [#pubsub{
		       publish = #ps_publish{
				    node = ?NS_MIX_NODES_PRESENCE,
				    items = [#ps_item{id = PresenceID}]}}]},
	   #message{from = Room,
		    sub_els =
			[#ps_event{
			    items = #ps_items{
				       node = ?NS_MIX_NODES_PRESENCE,
				       items = [#ps_item{
						    id = PresenceID,
						   xml_els = [Presence]}]}}]}),
    %% Coming offline
    send(Config, #presence{type = unavailable, to = Room}),
    %% Receiving presence retract event
    #message{from = Room,
	     sub_els = [#ps_event{
			   items = #ps_items{
				      node = ?NS_MIX_NODES_PRESENCE,
				      retract = PresenceID}}]} = recv(Config),
    %% Leaving
    I2 = send(Config, #iq{type = set, to = Room, sub_els = [#mix_leave{}]}),
    ?recv2(#iq{type = result, id = I2, sub_els = []},
	   #message{from = Room,
		    sub_els =
			[#ps_event{
			    items = #ps_items{
				       node = ?NS_MIX_NODES_PARTICIPANTS,
				       retract = ParticipantID}}]}),
    disconnect(Config).

mix_slave(Config) ->
    disconnect(Config).

roster_subscribe_master(Config) ->
    send(Config, #presence{}),
    ?recv1(#presence{}),
    wait_for_slave(Config),
    Peer = ?config(slave, Config),
    LPeer = jid:remove_resource(Peer),
    send(Config, #presence{type = subscribe, to = LPeer}),
    Push1 = ?recv1(#iq{type = set,
                sub_els = [#roster_query{items = [#roster_item{
                                               ask = subscribe,
                                               subscription = none,
                                               jid = LPeer}]}]}),
    send(Config, make_iq_result(Push1)),
    {Push2, _} = ?recv2(
                    #iq{type = set,
                        sub_els = [#roster_query{items = [#roster_item{
                                                       subscription = to,
                                                       jid = LPeer}]}]},
                    #presence{type = subscribed, from = LPeer}),
    send(Config, make_iq_result(Push2)),
    ?recv1(#presence{type = available, from = Peer}),
    %% BUG: ejabberd sends previous push again. Is it ok?
    Push3 = ?recv1(#iq{type = set,
                sub_els = [#roster_query{items = [#roster_item{
                                               subscription = to,
                                               jid = LPeer}]}]}),
    send(Config, make_iq_result(Push3)),
    ?recv1(#presence{type = subscribe, from = LPeer}),
    send(Config, #presence{type = subscribed, to = LPeer}),
    Push4 = ?recv1(#iq{type = set,
                sub_els = [#roster_query{items = [#roster_item{
                                               subscription = both,
                                               jid = LPeer}]}]}),
    send(Config, make_iq_result(Push4)),
    %% Move into a group
    Groups = [<<"A">>, <<"B">>],
    Item = #roster_item{jid = LPeer, groups = Groups},
    I1 = send(Config, #iq{type = set, sub_els = [#roster_query{items = [Item]}]}),
    {Push5, _} = ?recv2(
                   #iq{type = set,
                       sub_els =
                           [#roster_query{items = [#roster_item{
                                                jid = LPeer,
                                                subscription = both}]}]},
                   #iq{type = result, id = I1, sub_els = []}),
    send(Config, make_iq_result(Push5)),
    #iq{sub_els = [#roster_query{items = [#roster_item{groups = G1}]}]} = Push5,
    Groups = lists:sort(G1),
    wait_for_slave(Config),
    ?recv1(#presence{type = unavailable, from = Peer}),
    disconnect(Config).

roster_subscribe_slave(Config) ->
    send(Config, #presence{}),
    ?recv1(#presence{}),
    wait_for_master(Config),
    Peer = ?config(master, Config),
    LPeer = jid:remove_resource(Peer),
    ?recv1(#presence{type = subscribe, from = LPeer}),
    send(Config, #presence{type = subscribed, to = LPeer}),
    Push1 = ?recv1(#iq{type = set,
                sub_els = [#roster_query{items = [#roster_item{
                                               subscription = from,
                                               jid = LPeer}]}]}),
    send(Config, make_iq_result(Push1)),
    send(Config, #presence{type = subscribe, to = LPeer}),
    Push2 = ?recv1(#iq{type = set,
                sub_els = [#roster_query{items = [#roster_item{
                                               ask = subscribe,
                                               subscription = from,
                                               jid = LPeer}]}]}),
    send(Config, make_iq_result(Push2)),
    {Push3, _} = ?recv2(
                    #iq{type = set,
                        sub_els = [#roster_query{items = [#roster_item{
                                                       subscription = both,
                                                       jid = LPeer}]}]},
                    #presence{type = subscribed, from = LPeer}),
    send(Config, make_iq_result(Push3)),
    ?recv1(#presence{type = available, from = Peer}),
    wait_for_master(Config),
    disconnect(Config).

roster_remove_master(Config) ->
    MyJID = my_jid(Config),
    Peer = ?config(slave, Config),
    LPeer = jid:remove_resource(Peer),
    Groups = [<<"A">>, <<"B">>],
    wait_for_slave(Config),
    send(Config, #presence{}),
    ?recv2(#presence{from = MyJID, type = available},
           #presence{from = Peer, type = available}),
    %% The peer removed us from its roster.
    {Push1, Push2, _, _, _} =
        ?recv5(
           %% TODO: I guess this can be optimized, we don't need
           %% to send transient roster push with subscription = 'to'.
           #iq{type = set,
               sub_els =
                   [#roster_query{items = [#roster_item{
                                        jid = LPeer,
                                        subscription = to}]}]},
           #iq{type = set,
               sub_els =
                   [#roster_query{items = [#roster_item{
                                        jid = LPeer,
                                        subscription = none}]}]},
           #presence{type = unsubscribe, from = LPeer},
           #presence{type = unsubscribed, from = LPeer},
           #presence{type = unavailable, from = Peer}),
    send(Config, make_iq_result(Push1)),
    send(Config, make_iq_result(Push2)),
    #iq{sub_els = [#roster_query{items = [#roster_item{groups = G1}]}]} = Push1,
    #iq{sub_els = [#roster_query{items = [#roster_item{groups = G2}]}]} = Push2,
    Groups = lists:sort(G1), Groups = lists:sort(G2),
    disconnect(Config).

roster_remove_slave(Config) ->
    MyJID = my_jid(Config),
    Peer = ?config(master, Config),
    LPeer = jid:remove_resource(Peer),
    send(Config, #presence{}),
    ?recv1(#presence{from = MyJID, type = available}),
    wait_for_master(Config),
    ?recv1(#presence{from = Peer, type = available}),
    %% Remove the peer from roster.
    Item = #roster_item{jid = LPeer, subscription = remove},
    I = send(Config, #iq{type = set, sub_els = [#roster_query{items = [Item]}]}),
    {Push, _, _} = ?recv3(
                   #iq{type = set,
                       sub_els =
                           [#roster_query{items = [#roster_item{
                                                jid = LPeer,
                                                subscription = remove}]}]},
                   #iq{type = result, id = I, sub_els = []},
                   #presence{type = unavailable, from = Peer}),
    send(Config, make_iq_result(Push)),
    disconnect(Config).

proxy65_master(Config) ->
    Proxy = proxy_jid(Config),
    MyJID = my_jid(Config),
    Peer = ?config(slave, Config),
    wait_for_slave(Config),
    send(Config, #presence{}),
    ?recv1(#presence{from = MyJID, type = available}),
    true = is_feature_advertised(Config, ?NS_BYTESTREAMS, Proxy),
    #iq{type = result, sub_els = [#bytestreams{hosts = [StreamHost]}]} =
        send_recv(
          Config,
          #iq{type = get, sub_els = [#bytestreams{}], to = Proxy}),
    SID = randoms:get_string(),
    Data = crypto:rand_bytes(1024),
    put_event(Config, {StreamHost, SID, Data}),
    Socks5 = socks5_connect(StreamHost, {SID, MyJID, Peer}),
    wait_for_slave(Config),
    #iq{type = result, sub_els = []} =
        send_recv(Config,
                  #iq{type = set, to = Proxy,
                      sub_els = [#bytestreams{activate = Peer, sid = SID}]}),
    socks5_send(Socks5, Data),
    %%?recv1(#presence{type = unavailable, from = Peer}),
    disconnect(Config).

proxy65_slave(Config) ->
    MyJID = my_jid(Config),
    Peer = ?config(master, Config),
    send(Config, #presence{}),
    ?recv1(#presence{from = MyJID, type = available}),
    wait_for_master(Config),
    {StreamHost, SID, Data} = get_event(Config),
    Socks5 = socks5_connect(StreamHost, {SID, Peer, MyJID}),
    wait_for_master(Config),
    socks5_recv(Socks5, Data),
    disconnect(Config).

send_messages_to_room(Config, Range) ->
    MyNick = ?config(master_nick, Config),
    Room = muc_room_jid(Config),
    MyNickJID = jid:replace_resource(Room, MyNick),
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
              I = send(Config, #message{to = Room, body = [Text],
					type = groupchat}),
	      ?recv1(#message{from = MyNickJID, id = I,
			      type = groupchat,
			      body = [Text]})
      end, Range).

retrieve_messages_from_room_via_mam(Config, Range) ->
    MyNick = ?config(master_nick, Config),
    Room = muc_room_jid(Config),
    MyNickJID = jid:replace_resource(Room, MyNick),
    MyJID = my_jid(Config),
    QID = randoms:get_string(),
    Count = length(Range),
    I = send(Config, #iq{type = set, to = Room,
			 sub_els = [#mam_query{xmlns = ?NS_MAM_1, id = QID}]}),
    lists:foreach(
      fun(N) ->
	      Text = #text{data = integer_to_binary(N)},
	      ?recv1(#message{
			to = MyJID, from = Room,
			sub_els =
			    [#mam_result{
				xmlns = ?NS_MAM_1,
				queryid = QID,
				sub_els =
				    [#forwarded{
					delay = #delay{},
					sub_els = [#message{
						      from = MyNickJID,
						      type = groupchat,
						      body = [Text]}]}]}]})
      end, Range),
    ?recv1(#iq{from = Room, id = I, type = result,
	       sub_els = [#mam_fin{xmlns = ?NS_MAM_1,
				   id = QID,
				   rsm = #rsm_set{count = Count},
				   complete = true}]}).

muc_mam_master(Config) ->
    MyNick = ?config(master_nick, Config),
    Room = muc_room_jid(Config),
    MyNickJID = jid:replace_resource(Room, MyNick),
    %% Joining
    send(Config, #presence{to = MyNickJID, sub_els = [#muc{}]}),
    %% Receive self-presence
    ?recv1(#presence{from = MyNickJID}),
    %% MAM feature should not be advertised at this point,
    %% because MAM is not enabled so far
    false = is_feature_advertised(Config, ?NS_MAM_1, Room),
    %% Fill in some history
    send_messages_to_room(Config, lists:seq(1, 21)),
    %% We now should be able to retrieve those via MAM, even though
    %% MAM is disabled. However, only last 20 messages should be received.
    retrieve_messages_from_room_via_mam(Config, lists:seq(2, 21)),
    %% Now enable MAM for the conference
    %% Retrieve config first
    #iq{type = result, sub_els = [#muc_owner{config = #xdata{} = RoomCfg}]} =
        send_recv(Config, #iq{type = get, sub_els = [#muc_owner{}],
                              to = Room}),
    %% Find the MAM field in the config and enable it
    NewFields = lists:flatmap(
		  fun(#xdata_field{var = <<"muc#roomconfig_mam">> = Var}) ->
			  [#xdata_field{var = Var, values = [<<"1">>]}];
		     (_) ->
			  []
		  end, RoomCfg#xdata.fields),
    NewRoomCfg = #xdata{type = submit, fields = NewFields},
    I1 = send(Config, #iq{type = set, to = Room,
			  sub_els = [#muc_owner{config = NewRoomCfg}]}),
    ?recv2(#iq{type = result, id = I1},
	   #message{from = Room, type = groupchat,
		    sub_els = [#muc_user{status_codes = [104]}]}),
    %% Check if MAM has been enabled
    true = is_feature_advertised(Config, ?NS_MAM_1, Room),
    %% We now sending some messages again
    send_messages_to_room(Config, lists:seq(1, 5)),
    %% And retrieve them via MAM again.
    retrieve_messages_from_room_via_mam(Config, lists:seq(1, 5)),
    disconnect(Config).

muc_mam_slave(Config) ->
    disconnect(Config).

muc_master(Config) ->
    MyJID = my_jid(Config),
    PeerJID = ?config(slave, Config),
    PeerBareJID = jid:remove_resource(PeerJID),
    PeerJIDStr = jid:to_string(PeerJID),
    MUC = muc_jid(Config),
    Room = muc_room_jid(Config),
    MyNick = ?config(master_nick, Config),
    MyNickJID = jid:replace_resource(Room, MyNick),
    PeerNick = ?config(slave_nick, Config),
    PeerNickJID = jid:replace_resource(Room, PeerNick),
    Subject = ?config(room_subject, Config),
    Localhost = jid:make(<<"">>, <<"localhost">>, <<"">>),
    true = is_feature_advertised(Config, ?NS_MUC, MUC),
    %% Joining
    send(Config, #presence{to = MyNickJID, sub_els = [#muc{}]}),
    %% As per XEP-0045 we MUST receive stanzas in the following order:
    %% 1. In-room presence from other occupants
    %% 2. In-room presence from the joining entity itself (so-called "self-presence")
    %% 3. Room history (if any)
    %% 4. The room subject
    %% 5. Live messages, presence updates, new user joins, etc.
    %% As this is the newly created room, we receive only the 2nd stanza.
    #muc_user{
       status_codes = Codes,
       items = [#muc_item{role = moderator,
			  jid = MyJID,
			  affiliation = owner}]} =
	xmpp:get_subtag(?recv1(#presence{from = MyNickJID}), #muc_user{}),
    %% 110 -> Inform user that presence refers to itself
    %% 201 -> Inform user that a new room has been created
    [110, 201] = lists:sort(Codes),
    %% Request the configuration
    #iq{type = result, sub_els = [#muc_owner{config = #xdata{} = RoomCfg}]} =
        send_recv(Config, #iq{type = get, sub_els = [#muc_owner{}],
                              to = Room}),
    NewFields =
        lists:flatmap(
          fun(#xdata_field{var = Var, values = OrigVals}) ->
                  Vals = case Var of
                             <<"FORM_TYPE">> ->
                                 OrigVals;
                             <<"muc#roomconfig_roomname">> ->
                                 [<<"Test room">>];
                             <<"muc#roomconfig_roomdesc">> ->
                                 [<<"Trying to break the server">>];
                             <<"muc#roomconfig_persistentroom">> ->
                                 [<<"1">>];
			     <<"members_by_default">> ->
				 [<<"0">>];
			     <<"muc#roomconfig_allowvoicerequests">> ->
				 [<<"1">>];
			     <<"public_list">> ->
				 [<<"1">>];
			     <<"muc#roomconfig_publicroom">> ->
				 [<<"1">>];
                             _ ->
                                 []
                         end,
                  if Vals /= [] ->
                          [#xdata_field{values = Vals, var = Var}];
                     true ->
                          []
                  end
          end, RoomCfg#xdata.fields),
    NewRoomCfg = #xdata{type = submit, fields = NewFields},
    ID = send(Config, #iq{type = set, to = Room,
			  sub_els = [#muc_owner{config = NewRoomCfg}]}),
    ?recv2(#iq{type = result, id = ID},
	   #message{from = Room, type = groupchat,
		    sub_els = [#muc_user{status_codes = [104]}]}),
    %% Set subject
    send(Config, #message{to = Room, type = groupchat,
                          body = [#text{data = Subject}]}),
    ?recv1(#message{from = MyNickJID, type = groupchat,
             body = [#text{data = Subject}]}),
    %% Sending messages (and thus, populating history for our peer)
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
              I = send(Config, #message{to = Room, body = [Text],
					type = groupchat}),
	      ?recv1(#message{from = MyNickJID, id = I,
		       type = groupchat,
		       body = [Text]})
      end, lists:seq(1, 5)),
    %% Inviting the peer
    send(Config, #message{to = Room, type = normal,
			  sub_els =
			      [#muc_user{
				  invites =
				      [#muc_invite{to = PeerJID}]}]}),
    #muc_user{
       items = [#muc_item{role = visitor,
			  jid = PeerJID,
			  affiliation = none}]} =
	xmpp:get_subtag(?recv1(#presence{from = PeerNickJID}), #muc_user{}),
    %% Receiving a voice request
    #message{from = Room,
	     sub_els = [#xdata{type = form,
			       instructions = [_],
			       fields = VoiceReqFs}]} = recv(Config),
    %% Approving the voice request
    ReplyVoiceReqFs =
	lists:map(
	  fun(#xdata_field{var = Var, values = OrigVals}) ->
                  Vals = case {Var, OrigVals} of
			     {<<"FORM_TYPE">>,
			      [<<"http://jabber.org/protocol/muc#request">>]} ->
				 OrigVals;
			     {<<"muc#role">>, [<<"participant">>]} ->
				 [<<"participant">>];
			     {<<"muc#jid">>, [PeerJIDStr]} ->
				 [PeerJIDStr];
			     {<<"muc#roomnick">>, [PeerNick]} ->
				 [PeerNick];
			     {<<"muc#request_allow">>, [<<"0">>]} ->
				 [<<"1">>]
			 end,
		  #xdata_field{values = Vals, var = Var}
	  end, VoiceReqFs),
    send(Config, #message{to = Room,
			  sub_els = [#xdata{type = submit,
					    fields = ReplyVoiceReqFs}]}),
    %% Peer is becoming a participant
    #muc_user{items = [#muc_item{role = participant,
				 jid = PeerJID,
				 affiliation = none}]} =
	xmpp:get_subtag(?recv1(#presence{from = PeerNickJID}), #muc_user{}),
    %% Receive private message from the peer
    ?recv1(#message{from = PeerNickJID, body = [#text{data = Subject}]}),
    %% Granting membership to the peer and localhost server
    I1 = send(Config,
	      #iq{type = set, to = Room,
		  sub_els =
		      [#muc_admin{
			  items = [#muc_item{jid = Localhost,
					     affiliation = member},
				   #muc_item{nick = PeerNick,
					     jid = PeerBareJID,
					     affiliation = member}]}]}),
    %% Peer became a member
    #muc_user{items = [#muc_item{affiliation = member,
				 jid = PeerJID,
				 role = participant}]} =
	xmpp:get_subtag(?recv1(#presence{from = PeerNickJID}), #muc_user{}),
    ?recv1(#message{from = Room,
	      sub_els = [#muc_user{
			    items = [#muc_item{affiliation = member,
					       jid = Localhost,
					       role = none}]}]}),
    ?recv1(#iq{type = result, id = I1, sub_els = []}),
    %% Receive groupchat message from the peer
    ?recv1(#message{type = groupchat, from = PeerNickJID,
	     body = [#text{data = Subject}]}),
    %% Retrieving a member list
    #iq{type = result, sub_els = [#muc_admin{items = MemberList}]} =
	send_recv(Config,
		  #iq{type = get, to = Room,
		      sub_els =
			  [#muc_admin{items = [#muc_item{affiliation = member}]}]}),
    [#muc_item{affiliation = member,
	       jid = Localhost},
     #muc_item{affiliation = member,
	       jid = PeerBareJID}] = lists:keysort(#muc_item.jid, MemberList),
    %% Kick the peer
    I2 = send(Config,
	      #iq{type = set, to = Room,
		  sub_els = [#muc_admin{
				items = [#muc_item{nick = PeerNick,
						   role = none}]}]}),
    %% Got notification the peer is kicked
    %% 307 -> Inform user that he or she has been kicked from the room
    ?recv1(#presence{from = PeerNickJID, type = unavailable,
	      sub_els = [#muc_user{
			    status_codes = [307],
			    items = [#muc_item{affiliation = member,
					       jid = PeerJID,
					       role = none}]}]}),
    ?recv1(#iq{type = result, id = I2, sub_els = []}),
    %% Destroying the room
    I3 = send(Config,
	      #iq{type = set, to = Room,
		  sub_els = [#muc_owner{
				destroy = #muc_destroy{
					     reason = Subject}}]}),
    %% Kicked off
    ?recv1(#presence{from = MyNickJID, type = unavailable,
              sub_els = [#muc_user{items = [#muc_item{role = none,
						      affiliation = none}],
				   destroy = #muc_destroy{
						reason = Subject}}]}),
    ?recv1(#iq{type = result, id = I3, sub_els = []}),
    disconnect(Config).

muc_slave(Config) ->
    PeerJID = ?config(master, Config),
    MUC = muc_jid(Config),
    Room = muc_room_jid(Config),
    MyNick = ?config(slave_nick, Config),
    MyNickJID = jid:replace_resource(Room, MyNick),
    PeerNick = ?config(master_nick, Config),
    PeerNickJID = jid:replace_resource(Room, PeerNick),
    Subject = ?config(room_subject, Config),
    %% Receive an invite from the peer
    #muc_user{invites = [#muc_invite{from = PeerJID}]} =
	xmpp:get_subtag(?recv1(#message{from = Room, type = normal}),
			#muc_user{}),
    %% But before joining we discover the MUC service first
    %% to check if the room is in the disco list
    #iq{type = result,
	sub_els = [#disco_items{items = [#disco_item{jid = Room}]}]} =
	send_recv(Config, #iq{type = get, to = MUC,
			      sub_els = [#disco_items{}]}),
    %% Now check if the peer is in the room. We check this via disco#items
    #iq{type = result,
	sub_els = [#disco_items{items = [#disco_item{jid = PeerNickJID,
						     name = PeerNick}]}]} =
	send_recv(Config, #iq{type = get, to = Room,
			      sub_els = [#disco_items{}]}),
    %% Now joining
    send(Config, #presence{to = MyNickJID, sub_els = [#muc{}]}),
    %% First presence is from the participant, i.e. from the peer
    #muc_user{
       status_codes = [],
       items = [#muc_item{role = moderator,
			  affiliation = owner}]} =
	xmpp:get_subtag(?recv1(#presence{from = PeerNickJID}), #muc_user{}),
    %% The next is the self-presence (code 110 means it)
    #muc_user{status_codes = [110],
	      items = [#muc_item{role = visitor,
				 affiliation = none}]} =
	xmpp:get_subtag(?recv1(#presence{from = MyNickJID}), #muc_user{}),
    %% Receive the room subject
    ?recv1(#message{from = PeerNickJID, type = groupchat,
             body = [#text{data = Subject}],
	     sub_els = [#delay{}]}),
    %% Receive MUC history
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
	      ?recv1(#message{from = PeerNickJID,
		       type = groupchat,
		       body = [Text],
		       sub_els = [#delay{}]})
      end, lists:seq(1, 5)),
    %% Sending a voice request
    VoiceReq = #xdata{
		  type = submit,
		  fields =
		      [#xdata_field{
			  var = <<"FORM_TYPE">>,
			  values = [<<"http://jabber.org/protocol/muc#request">>]},
		       #xdata_field{
			  var = <<"muc#role">>,
			  type = 'text-single',
			  values = [<<"participant">>]}]},
    send(Config, #message{to = Room, sub_els = [VoiceReq]}),
    %% Becoming a participant
    #muc_user{items = [#muc_item{role = participant,
				 affiliation = none}]} =
	xmpp:get_subtag(?recv1(#presence{from = MyNickJID}), #muc_user{}),
    %% Sending private message to the peer
    send(Config, #message{to = PeerNickJID,
			  body = [#text{data = Subject}]}),
    %% Becoming a member
    #muc_user{items = [#muc_item{role = participant,
				 affiliation = member}]} =
	xmpp:get_subtag(?recv1(#presence{from = MyNickJID}), #muc_user{}),
    %% Sending groupchat message
    send(Config, #message{to = Room, type = groupchat,
			  body = [#text{data = Subject}]}),
    %% Receive this message back
    ?recv1(#message{type = groupchat, from = MyNickJID,
	     body = [#text{data = Subject}]}),
    %% We're kicked off
    %% 307 -> Inform user that he or she has been kicked from the room
    ?recv1(#presence{from = MyNickJID, type = unavailable,
	      sub_els = [#muc_user{
			    status_codes = [307],
			    items = [#muc_item{affiliation = member,
					       role = none}]}]}),
    disconnect(Config).

muc_register_nick(Config, MUC, PrevNick, Nick) ->
    {Registered, PrevNickVals} = if PrevNick /= <<"">> ->
					 {true, [PrevNick]};
				    true ->
					 {false, []}
				 end,
    %% Request register form
    #iq{type = result,
	sub_els = [#register{registered = Registered,
			     xdata = #xdata{type = form,
					    fields = FsWithoutNick}}]} =
	send_recv(Config, #iq{type = get, to = MUC,
			      sub_els = [#register{}]}),
    %% Check if 'nick' field presents
    #xdata_field{type = 'text-single',
		 var = <<"nick">>,
		 values = PrevNickVals} =
	lists:keyfind(<<"nick">>, #xdata_field.var, FsWithoutNick),
    X = #xdata{type = submit,
	       fields = [#xdata_field{var = <<"nick">>, values = [Nick]}]},
    %% Submitting form
    #iq{type = result, sub_els = []} =
	send_recv(Config, #iq{type = set, to = MUC,
			      sub_els = [#register{xdata = X}]}),
    %% Check if the nick was registered
    #iq{type = result,
	sub_els = [#register{registered = true,
			     xdata = #xdata{type = form,
					    fields = FsWithNick}}]} =
	send_recv(Config, #iq{type = get, to = MUC,
			      sub_els = [#register{}]}),
    #xdata_field{type = 'text-single', var = <<"nick">>,
		 values = [Nick]} =
	lists:keyfind(<<"nick">>, #xdata_field.var, FsWithNick).

muc_register_master(Config) ->
    MUC = muc_jid(Config),
    %% Register nick "master1"
    muc_register_nick(Config, MUC, <<"">>, <<"master1">>),
    %% Unregister nick "master1" via jabber:register
    #iq{type = result, sub_els = []} =
	send_recv(Config, #iq{type = set, to = MUC,
			      sub_els = [#register{remove = true}]}),
    %% Register nick "master2"
    muc_register_nick(Config, MUC, <<"">>, <<"master2">>),
    %% Now register nick "master"
    muc_register_nick(Config, MUC, <<"master2">>, <<"master">>),
    disconnect(Config).

muc_register_slave(Config) ->
    MUC = muc_jid(Config),
    %% Trying to register occupied nick "master"
    X = #xdata{type = submit,
	       fields = [#xdata_field{var = <<"nick">>,
				      values = [<<"master">>]}]},
    #iq{type = error} =
	send_recv(Config, #iq{type = set, to = MUC,
			      sub_els = [#register{xdata = X}]}),
    disconnect(Config).

announce_master(Config) ->
    MyJID = my_jid(Config),
    ServerJID = server_jid(Config),
    MotdJID = jid:replace_resource(ServerJID, <<"announce/motd">>),
    MotdText = #text{data = <<"motd">>},
    send(Config, #presence{}),
    ?recv1(#presence{from = MyJID}),
    %% Set message of the day
    send(Config, #message{to = MotdJID, body = [MotdText]}),
    %% Receive this message back
    ?recv1(#message{from = ServerJID, body = [MotdText]}),
    disconnect(Config).

announce_slave(Config) ->
    MyJID = my_jid(Config),
    ServerJID = server_jid(Config),
    MotdDelJID = jid:replace_resource(ServerJID, <<"announce/motd/delete">>),
    MotdText = #text{data = <<"motd">>},
    send(Config, #presence{}),
    ?recv2(#presence{from = MyJID},
	   #message{from = ServerJID, body = [MotdText]}),
    %% Delete message of the day
    send(Config, #message{to = MotdDelJID}),
    disconnect(Config).

flex_offline_master(Config) ->
    Peer = ?config(slave, Config),
    LPeer = jid:remove_resource(Peer),
    lists:foreach(
      fun(I) ->
	      Body = integer_to_binary(I),
	      send(Config, #message{to = LPeer,
				    body = [#text{data = Body}],
				    subject = [#text{data = <<"subject">>}]})
      end, lists:seq(1, 5)),
    disconnect(Config).

flex_offline_slave(Config) ->
    MyJID = my_jid(Config),
    MyBareJID = jid:remove_resource(MyJID),
    Peer = ?config(master, Config),
    Peer_s = jid:to_string(Peer),
    true = is_feature_advertised(Config, ?NS_FLEX_OFFLINE),
    %% Request disco#info
    #iq{type = result,
	sub_els = [#disco_info{
		      node = ?NS_FLEX_OFFLINE,
		      identities = Ids,
		      features = Fts,
		      xdata = [X]}]} =
	send_recv(Config, #iq{type = get,
			      sub_els = [#disco_info{
					    node = ?NS_FLEX_OFFLINE}]}),
    %% Check if we have correct identities
    true = lists:any(
	     fun(#identity{category = <<"automation">>,
			   type = <<"message-list">>}) -> true;
		(_) -> false
	     end, Ids),
    %% Check if we have needed feature
    true = lists:member(?NS_FLEX_OFFLINE, Fts),
    %% Check xdata, the 'number_of_messages' should be 5
    #xdata{type = result,
	   fields = [#xdata_field{type = hidden,
				  var = <<"FORM_TYPE">>},
		     #xdata_field{var = <<"number_of_messages">>,
				  values = [<<"5">>]}]} = X,
    %% Fetch headers,
    #iq{type = result,
	sub_els = [#disco_items{
		      node = ?NS_FLEX_OFFLINE,
		      items = DiscoItems}]} =
	send_recv(Config, #iq{type = get,
			      sub_els = [#disco_items{
					    node = ?NS_FLEX_OFFLINE}]}),
    %% Check if headers are correct
    Nodes = lists:sort(
	      lists:map(
		fun(#disco_item{jid = J, name = P, node = N})
		      when (J == MyBareJID) and (P == Peer_s) ->
			N
		end, DiscoItems)),
    %% Since headers are received we can send initial presence without a risk
    %% of getting offline messages flood
    send(Config, #presence{}),
    ?recv1(#presence{from = MyJID}),
    %% Check full fetch
    I0 = send(Config, #iq{type = get, sub_els = [#offline{fetch = true}]}),
    lists:foreach(
      fun({I, N}) ->
	      Text = integer_to_binary(I),
	      #message{body = Body, sub_els = SubEls} = recv(Config),
	      [#text{data = Text}] = Body,
	      #offline{items = [#offline_item{node = N}]} =
		  lists:keyfind(offline, 1, SubEls),
	      #delay{} = lists:keyfind(delay, 1, SubEls)
      end, lists:zip(lists:seq(1, 5), Nodes)),
    ?recv1(#iq{type = result, id = I0, sub_els = []}),
    %% Fetch 2nd and 4th message
    I1 = send(Config,
	      #iq{type = get,
		  sub_els = [#offline{
				items = [#offline_item{
					    action = view,
					    node = lists:nth(2, Nodes)},
					 #offline_item{
					    action = view,
					    node = lists:nth(4, Nodes)}]}]}),
    lists:foreach(
      fun({I, N}) ->
	      Text = integer_to_binary(I),
	      #message{body = [#text{data = Text}],
		       sub_els = SubEls} = recv(Config),
	      #offline{items = [#offline_item{node = N}]} =
		  lists:keyfind(offline, 1, SubEls)
      end, lists:zip([2, 4], [lists:nth(2, Nodes), lists:nth(4, Nodes)])),
    ?recv1(#iq{type = result, id = I1, sub_els = []}),
    %% Delete 2nd and 4th message
    #iq{type = result, sub_els = []} =
	send_recv(
	  Config,
	  #iq{type = set,
	      sub_els = [#offline{
			    items = [#offline_item{
					action = remove,
					node = lists:nth(2, Nodes)},
				     #offline_item{
					action = remove,
					node = lists:nth(4, Nodes)}]}]}),
    %% Check if messages were deleted
    #iq{type = result,
	sub_els = [#disco_items{
		      node = ?NS_FLEX_OFFLINE,
		      items = RemainedItems}]} =
	send_recv(Config, #iq{type = get,
			      sub_els = [#disco_items{
					    node = ?NS_FLEX_OFFLINE}]}),
    RemainedNodes = [lists:nth(1, Nodes),
		     lists:nth(3, Nodes),
		     lists:nth(5, Nodes)],
    RemainedNodes = lists:sort(
		      lists:map(
			fun(#disco_item{node = N}) -> N end,
			RemainedItems)),
    %% Purge everything left
    #iq{type = result, sub_els = []} =
	send_recv(Config, #iq{type = set, sub_els = [#offline{purge = true}]}),
    %% Check if there is no offline messages
    #iq{type = result,
	sub_els = [#disco_items{node = ?NS_FLEX_OFFLINE, items = []}]} =
	send_recv(Config, #iq{type = get,
			      sub_els = [#disco_items{
					    node = ?NS_FLEX_OFFLINE}]}),
    disconnect(Config).

offline_master(Config) ->
    Peer = ?config(slave, Config),
    LPeer = jid:remove_resource(Peer),
    send(Config, #message{to = LPeer,
                          body = [#text{data = <<"body">>}],
                          subject = [#text{data = <<"subject">>}]}),
    disconnect(Config).

offline_slave(Config) ->
    Peer = ?config(master, Config),
    send(Config, #presence{}),
    {_, #message{sub_els = SubEls}} =
        ?recv2(#presence{},
               #message{from = Peer,
                        body = [#text{data = <<"body">>}],
                        subject = [#text{data = <<"subject">>}]}),
    true = lists:keymember(delay, 1, SubEls),
    disconnect(Config).

carbons_master(Config) ->
    MyJID = my_jid(Config),
    MyBareJID = jid:remove_resource(MyJID),
    Peer = ?config(slave, Config),
    Txt = #text{data = <<"body">>},
    true = is_feature_advertised(Config, ?NS_CARBONS_2),
    send(Config, #presence{priority = 10}),
    ?recv1(#presence{from = MyJID}),
    wait_for_slave(Config),
    ?recv1(#presence{from = Peer}),
    %% Enable carbons
    #iq{type = result, sub_els = []} =
	send_recv(Config,
		  #iq{type = set,
		      sub_els = [#carbons_enable{}]}),
    %% Send a message to bare and full JID
    send(Config, #message{to = MyBareJID, type = chat, body = [Txt]}),
    send(Config, #message{to = MyJID, type = chat, body = [Txt]}),
    send(Config, #message{to = MyBareJID, type = chat, body = [Txt],
			  sub_els = [#carbons_private{}]}),
    send(Config, #message{to = MyJID, type = chat, body = [Txt],
			  sub_els = [#carbons_private{}]}),
    %% Receive the messages back
    ?recv4(#message{from = MyJID, to = MyBareJID, type = chat,
		    body = [Txt], sub_els = []},
	   #message{from = MyJID, to = MyJID, type = chat,
		    body = [Txt], sub_els = []},
	   #message{from = MyJID, to = MyBareJID, type = chat,
		    body = [Txt], sub_els = [#carbons_private{}]},
	   #message{from = MyJID, to = MyJID, type = chat,
		    body = [Txt], sub_els = [#carbons_private{}]}),
    %% Disable carbons
    #iq{type = result, sub_els = []} =
	send_recv(Config,
		  #iq{type = set,
		      sub_els = [#carbons_disable{}]}),
    wait_for_slave(Config),
    %% Repeat the same and leave
    send(Config, #message{to = MyBareJID, type = chat, body = [Txt]}),
    send(Config, #message{to = MyJID, type = chat, body = [Txt]}),
    send(Config, #message{to = MyBareJID, type = chat, body = [Txt],
			  sub_els = [#carbons_private{}]}),
    send(Config, #message{to = MyJID, type = chat, body = [Txt],
			  sub_els = [#carbons_private{}]}),
    ?recv4(#message{from = MyJID, to = MyBareJID, type = chat,
		    body = [Txt], sub_els = []},
	   #message{from = MyJID, to = MyJID, type = chat,
		    body = [Txt], sub_els = []},
	   #message{from = MyJID, to = MyBareJID, type = chat,
		    body = [Txt], sub_els = [#carbons_private{}]},
	   #message{from = MyJID, to = MyJID, type = chat,
		    body = [Txt], sub_els = [#carbons_private{}]}),
    disconnect(Config).

carbons_slave(Config) ->
    MyJID = my_jid(Config),
    MyBareJID = jid:remove_resource(MyJID),
    Peer = ?config(master, Config),
    Txt = #text{data = <<"body">>},
    wait_for_master(Config),
    send(Config, #presence{priority = 5}),
    ?recv2(#presence{from = MyJID}, #presence{from = Peer}),
    %% Enable carbons
    #iq{type = result, sub_els = []} =
	send_recv(Config,
		  #iq{type = set,
		      sub_els = [#carbons_enable{}]}),
    %% Receive messages sent by the peer
    ?recv4(
       #message{from = MyBareJID, to = MyJID, type = chat,
		sub_els =
		    [#carbons_sent{
			forwarded = #forwarded{
				       sub_els =
					   [#message{from = Peer,
						     to = MyBareJID,
						     type = chat,
						     body = [Txt]}]}}]},
       #message{from = MyBareJID, to = MyJID, type = chat,
		sub_els =
		    [#carbons_sent{
			forwarded = #forwarded{
				       sub_els =
					   [#message{from = Peer,
						     to = Peer,
						     type = chat,
						     body = [Txt]}]}}]},
       #message{from = MyBareJID, to = MyJID, type = chat,
		sub_els =
		    [#carbons_received{
			forwarded = #forwarded{
				       sub_els =
					   [#message{from = Peer,
						     to = MyBareJID,
						     type = chat,
						     body = [Txt]}]}}]},
       #message{from = MyBareJID, to = MyJID, type = chat,
		sub_els =
		    [#carbons_received{
			forwarded = #forwarded{
				       sub_els =
					   [#message{from = Peer,
						     to = Peer,
						     type = chat,
						     body = [Txt]}]}}]}),
    %% Disable carbons
    #iq{type = result, sub_els = []} =
	send_recv(Config,
		  #iq{type = set,
		      sub_els = [#carbons_disable{}]}),
    wait_for_master(Config),
    %% Now we should receive nothing but presence unavailable from the peer
    ?recv1(#presence{from = Peer, type = unavailable}),
    disconnect(Config).

mam_old_master(Config) ->
    mam_master(Config, ?NS_MAM_TMP).

mam_new_master(Config) ->
    mam_master(Config, ?NS_MAM_0).

mam_master(Config, NS) ->
    true = is_feature_advertised(Config, NS),
    MyJID = my_jid(Config),
    BareMyJID = jid:remove_resource(MyJID),
    Peer = ?config(slave, Config),
    send(Config, #presence{}),
    ?recv1(#presence{}),
    wait_for_slave(Config),
    ?recv1(#presence{from = Peer}),
    #iq{type = result, sub_els = [#mam_prefs{xmlns = NS, default = roster}]} =
        send_recv(Config,
                  #iq{type = set,
                      sub_els = [#mam_prefs{xmlns = NS,
					    default = roster,
                                            never = [MyJID]}]}),
    if NS == ?NS_MAM_TMP ->
	    FakeArchived = #mam_archived{id = randoms:get_string(),
					 by = server_jid(Config)},
	    send(Config, #message{to = MyJID,
				  sub_els = [FakeArchived],
				  body = [#text{data = <<"a">>}]}),
	    send(Config, #message{to = BareMyJID,
				  sub_els = [FakeArchived],
				  body = [#text{data = <<"b">>}]}),
	    %% NOTE: The server should strip fake archived tags,
	    %% i.e. the sub_els received should be [].
	    ?recv2(#message{body = [#text{data = <<"a">>}], sub_els = []},
		   #message{body = [#text{data = <<"b">>}], sub_els = []});
       true ->
	    ok
    end,
    wait_for_slave(Config),
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
              send(Config,
                   #message{to = Peer, body = [Text]})
      end, lists:seq(1, 5)),
    ?recv1(#presence{type = unavailable, from = Peer}),
    mam_query_all(Config, NS),
    mam_query_with(Config, Peer, NS),
    %% mam_query_with(Config, jid:remove_resource(Peer)),
    mam_query_rsm(Config, NS),
    #iq{type = result, sub_els = [#mam_prefs{xmlns = NS, default = never}]} =
        send_recv(Config, #iq{type = set,
                              sub_els = [#mam_prefs{xmlns = NS,
						    default = never}]}),
    disconnect(Config).

mam_old_slave(Config) ->
    mam_slave(Config, ?NS_MAM_TMP).

mam_new_slave(Config) ->
    mam_slave(Config, ?NS_MAM_0).

mam_slave(Config, NS) ->
    Peer = ?config(master, Config),
    MyJID = my_jid(Config),
    ServerJID = server_jid(Config),
    wait_for_master(Config),
    send(Config, #presence{}),
    ?recv2(#presence{from = MyJID}, #presence{from = Peer}),
    #iq{type = result, sub_els = [#mam_prefs{xmlns = NS, default = always}]} =
        send_recv(Config,
                  #iq{type = set,
                      sub_els = [#mam_prefs{xmlns = NS, default = always}]}),
    wait_for_master(Config),
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
	      Msg = ?recv1(#message{from = Peer, body = [Text]}),
	      #mam_archived{by = ServerJID} =
		  xmpp:get_subtag(Msg, #mam_archived{}),
	      #stanza_id{by = ServerJID} =
		  xmpp:get_subtag(Msg, #stanza_id{})
      end, lists:seq(1, 5)),
    #iq{type = result, sub_els = [#mam_prefs{xmlns = NS, default = never}]} =
        send_recv(Config, #iq{type = set,
                              sub_els = [#mam_prefs{xmlns = NS, default = never}]}),
    disconnect(Config).

mam_query_all(Config, NS) ->
    QID = randoms:get_string(),
    MyJID = my_jid(Config),
    Peer = ?config(slave, Config),
    Type = case NS of
	       ?NS_MAM_TMP -> get;
	       _ -> set
	   end,
    I = send(Config, #iq{type = Type, sub_els = [#mam_query{xmlns = NS, id = QID}]}),
    maybe_recv_iq_result(Config, NS, I),
    Iter = if NS == ?NS_MAM_TMP -> lists:seq(1, 5);
	      true -> lists:seq(1, 5) ++ lists:seq(1, 5)
	   end,
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
              ?recv1(#message{to = MyJID,
                       sub_els =
                           [#mam_result{
                               queryid = QID,
                               sub_els =
                                   [#forwarded{
                                       delay = #delay{},
                                       sub_els =
                                           [#message{
                                               from = MyJID, to = Peer,
                                               body = [Text]}]}]}]})
      end, Iter),
    if NS == ?NS_MAM_TMP ->
	    ?recv1(#iq{type = result, id = I,
		       sub_els = [#mam_query{xmlns = NS, id = QID}]});
       true ->
	    ?recv1(#message{sub_els = [#mam_fin{complete = true, id = QID}]})
    end.

mam_query_with(Config, JID, NS) ->
    MyJID = my_jid(Config),
    Peer = ?config(slave, Config),
    {Query, Type} = if NS == ?NS_MAM_TMP ->
		    {#mam_query{xmlns = NS, with = JID}, get};
	       true ->
		    Fs = [#xdata_field{var = <<"jid">>,
				       values = [jid:to_string(JID)]}],
		    {#mam_query{xmlns = NS,
			       xdata = #xdata{type = submit, fields = Fs}}, set}
	    end,
    I = send(Config, #iq{type = Type, sub_els = [Query]}),
    Iter = if NS == ?NS_MAM_TMP -> lists:seq(1, 5);
	      true -> lists:seq(1, 5) ++ lists:seq(1, 5)
	   end,
    maybe_recv_iq_result(Config, NS, I),
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
              ?recv1(#message{to = MyJID,
                       sub_els =
                           [#mam_result{
                               sub_els =
                                   [#forwarded{
                                       delay = #delay{},
                                       sub_els =
                                           [#message{
                                               from = MyJID, to = Peer,
                                               body = [Text]}]}]}]})
      end, Iter),
    if NS == ?NS_MAM_TMP ->
	    ?recv1(#iq{type = result, id = I,
		       sub_els = [#mam_query{xmlns = NS}]});
       true ->
	    ?recv1(#message{sub_els = [#mam_fin{complete = true}]})
    end.

maybe_recv_iq_result(Config, ?NS_MAM_0, I1) ->
    ?recv1(#iq{type = result, id = I1});
maybe_recv_iq_result(_, _, _) ->
    ok.

mam_query_rsm(Config, NS) ->
    MyJID = my_jid(Config),
    Peer = ?config(slave, Config),
    Type = case NS of
	       ?NS_MAM_TMP -> get;
	       _ -> set
	   end,
    %% Get the first 3 items out of 5
    I1 = send(Config,
              #iq{type = Type,
                  sub_els = [#mam_query{xmlns = NS, rsm = #rsm_set{max = 3}}]}),
    maybe_recv_iq_result(Config, NS, I1),
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
              ?recv1(#message{to = MyJID,
                       sub_els =
                           [#mam_result{
			       xmlns = NS,
                               sub_els =
                                   [#forwarded{
                                       delay = #delay{},
                                       sub_els =
                                           [#message{
                                               from = MyJID, to = Peer,
                                               body = [Text]}]}]}]})
      end, lists:seq(1, 3)),
    if NS == ?NS_MAM_TMP ->
	    #iq{type = result, id = I1,
		sub_els = [#mam_query{xmlns = NS,
				      rsm = #rsm_set{last = Last,
						     count = 5}}]} =
		recv(Config);
       true ->
	    #message{sub_els = [#mam_fin{
				   complete = false,
				   rsm = #rsm_set{last = Last,
						  count = 10}}]} =
		recv(Config)
    end,
    %% Get the next items starting from the `Last`.
    %% Limit the response to 2 items.
    I2 = send(Config,
              #iq{type = Type,
                  sub_els = [#mam_query{xmlns = NS,
					rsm = #rsm_set{max = 2,
                                                       'after' = Last}}]}),
    maybe_recv_iq_result(Config, NS, I2),
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
              ?recv1(#message{to = MyJID,
                       sub_els =
                           [#mam_result{
			       xmlns = NS,
                               sub_els =
                                   [#forwarded{
                                       delay = #delay{},
                                       sub_els =
                                           [#message{
                                               from = MyJID, to = Peer,
                                               body = [Text]}]}]}]})
      end, lists:seq(4, 5)),
    if NS == ?NS_MAM_TMP ->
	    #iq{type = result, id = I2,
		sub_els = [#mam_query{
			      xmlns = NS,
			      rsm = #rsm_set{
				       count = 5,
				       first = #rsm_first{data = First}}}]} =
		recv(Config);
       true ->
	    #message{
	       sub_els = [#mam_fin{
			     complete = false,
			     rsm = #rsm_set{
				      count = 10,
				      first = #rsm_first{data = First}}}]} =
		recv(Config)
    end,
    %% Paging back. Should receive 3 elements: 1, 2, 3.
    I3 = send(Config,
              #iq{type = Type,
                  sub_els = [#mam_query{xmlns = NS,
					rsm = #rsm_set{max = 3,
                                                       before = First}}]}),
    maybe_recv_iq_result(Config, NS, I3),
    lists:foreach(
      fun(N) ->
              Text = #text{data = integer_to_binary(N)},
              ?recv1(#message{to = MyJID,
                       sub_els =
                           [#mam_result{
			       xmlns = NS,
                               sub_els =
                                   [#forwarded{
                                       delay = #delay{},
                                       sub_els =
                                           [#message{
                                               from = MyJID, to = Peer,
                                               body = [Text]}]}]}]})
      end, lists:seq(1, 3)),
    if NS == ?NS_MAM_TMP ->
	    ?recv1(#iq{type = result, id = I3,
		       sub_els = [#mam_query{xmlns = NS, rsm = #rsm_set{count = 5}}]});
       true ->
	    ?recv1(#message{
		      sub_els = [#mam_fin{complete = true,
					  rsm = #rsm_set{count = 10}}]})
    end,
    %% Getting the item count. Should be 5 (or 10).
    I4 = send(Config,
	      #iq{type = Type,
		  sub_els = [#mam_query{xmlns = NS,
					rsm = #rsm_set{max = 0}}]}),
    maybe_recv_iq_result(Config, NS, I4),
    if NS == ?NS_MAM_TMP ->
	    ?recv1(#iq{type = result, id = I4,
		       sub_els = [#mam_query{
				     xmlns = NS,
				     rsm = #rsm_set{count = 5,
						    first = undefined,
						    last = undefined}}]});
       true ->
	    ?recv1(#message{
		      sub_els = [#mam_fin{
				    complete = false,
				    rsm = #rsm_set{count = 10,
						   first = undefined,
						   last = undefined}}]})
    end,
    %% Should receive 2 last messages
    I5 = send(Config,
	      #iq{type = Type,
		  sub_els = [#mam_query{xmlns = NS,
					rsm = #rsm_set{max = 2,
						       before = <<"">>}}]}),
    maybe_recv_iq_result(Config, NS, I5),
    lists:foreach(
      fun(N) ->
	      Text = #text{data = integer_to_binary(N)},
	      ?recv1(#message{to = MyJID,
			      sub_els =
				  [#mam_result{
				      xmlns = NS,
				      sub_els =
					  [#forwarded{
					      delay = #delay{},
					      sub_els =
						  [#message{
						      from = MyJID, to = Peer,
						      body = [Text]}]}]}]})
      end, lists:seq(4, 5)),
    if NS == ?NS_MAM_TMP ->
	    ?recv1(#iq{type = result, id = I5,
		       sub_els = [#mam_query{xmlns = NS, rsm = #rsm_set{count = 5}}]});
       true ->
	    ?recv1(#message{
		      sub_els = [#mam_fin{complete = false,
					  rsm = #rsm_set{count = 10}}]})
    end.

client_state_master(Config) ->
    true = ?config(csi, Config),
    Peer = ?config(slave, Config),
    Presence = #presence{to = Peer},
    ChatState = #message{to = Peer, thread = <<"1">>,
			 sub_els = [#chatstate{type = active}]},
    Message = ChatState#message{body = [#text{data = <<"body">>}]},
    PepPayload = xmpp:encode(#presence{}),
    PepOne = #message{
		to = Peer,
		sub_els =
		    [#ps_event{
			items =
			    #ps_items{
			       node = <<"foo-1">>,
			       items =
				   [#ps_item{
				       id = <<"pep-1">>,
				       xml_els = [PepPayload]}]}}]},
    PepTwo = #message{
		to = Peer,
		sub_els =
		    [#ps_event{
			items =
			    #ps_items{
			       node = <<"foo-2">>,
			       items =
				   [#ps_item{
				       id = <<"pep-2">>,
				       xml_els = [PepPayload]}]}}]},
    %% Wait for the slave to become inactive.
    wait_for_slave(Config),
    %% Should be queued (but see below):
    send(Config, Presence),
    %% Should replace the previous presence in the queue:
    send(Config, Presence#presence{type = unavailable}),
    %% The following two PEP stanzas should be queued (but see below):
    send(Config, PepOne),
    send(Config, PepTwo),
    %% The following two PEP stanzas should replace the previous two:
    send(Config, PepOne),
    send(Config, PepTwo),
    %% Should be queued (but see below):
    send(Config, ChatState),
    %% Should replace the previous chat state in the queue:
    send(Config, ChatState#message{sub_els = [#chatstate{type = composing}]}),
    %% Should be sent immediately, together with the queued stanzas:
    send(Config, Message),
    %% Wait for the slave to become active.
    wait_for_slave(Config),
    %% Should be delivered, as the client is active again:
    send(Config, ChatState),
    disconnect(Config).

client_state_slave(Config) ->
    Peer = ?config(master, Config),
    change_client_state(Config, inactive),
    wait_for_master(Config),
    ?recv1(#presence{from = Peer, type = unavailable,
		     sub_els = [#delay{}]}),
    #message{
       from = Peer,
       sub_els =
	   [#ps_event{
	       items =
		   #ps_items{
		      node = <<"foo-1">>,
		      items =
			  [#ps_item{
			      id = <<"pep-1">>}]}},
	    #delay{}]} = recv(Config),
    #message{
       from = Peer,
       sub_els =
	   [#ps_event{
	       items =
		   #ps_items{
		      node = <<"foo-2">>,
		      items =
			  [#ps_item{
			      id = <<"pep-2">>}]}},
	    #delay{}]} = recv(Config),
    ?recv1(#message{from = Peer, thread = <<"1">>,
		    sub_els = [#chatstate{type = composing},
			       #delay{}]}),
    ?recv1(#message{from = Peer, thread = <<"1">>,
		    body = [#text{data = <<"body">>}],
		    sub_els = [#chatstate{type = active}]}),
    change_client_state(Config, active),
    wait_for_master(Config),
    ?recv1(#message{from = Peer, thread = <<"1">>,
		    sub_els = [#chatstate{type = active}]}),
    disconnect(Config).

%%%===================================================================
%%% Aux functions
%%%===================================================================
change_client_state(Config, NewState) ->
    send(Config, #csi{type = NewState}),
    send_recv(Config, #iq{type = get, to = server_jid(Config),
			  sub_els = [#ping{}]}).

bookmark_conference() ->
    #bookmark_conference{name = <<"Some name">>,
                         autojoin = true,
                         jid = jid:make(
                                 <<"some">>,
                                 <<"some.conference.org">>,
                                 <<>>)}.

socks5_connect(#streamhost{host = Host, port = Port},
               {SID, JID1, JID2}) ->
    Hash = p1_sha:sha([SID, jid:to_string(JID1), jid:to_string(JID2)]),
    {ok, Sock} = gen_tcp:connect(binary_to_list(Host), Port,
                                 [binary, {active, false}]),
    Init = <<?VERSION_5, 1, ?AUTH_ANONYMOUS>>,
    InitAck = <<?VERSION_5, ?AUTH_ANONYMOUS>>,
    Req = <<?VERSION_5, ?CMD_CONNECT, 0,
            ?ATYP_DOMAINNAME, 40, Hash:40/binary, 0, 0>>,
    Resp = <<?VERSION_5, ?SUCCESS, 0, ?ATYP_DOMAINNAME,
             40, Hash:40/binary, 0, 0>>,
    gen_tcp:send(Sock, Init),
    {ok, InitAck} = gen_tcp:recv(Sock, size(InitAck)),
    gen_tcp:send(Sock, Req),
    {ok, Resp} = gen_tcp:recv(Sock, size(Resp)),
    Sock.

socks5_send(Sock, Data) ->
    ok = gen_tcp:send(Sock, Data).

socks5_recv(Sock, Data) ->
    {ok, Data} = gen_tcp:recv(Sock, size(Data)).

%%%===================================================================
%%% SQL stuff
%%%===================================================================
create_sql_tables(sqlite, _BaseDir) ->
    ok;
create_sql_tables(Type, BaseDir) ->
    {VHost, File} = case Type of
                        mysql ->
                            {?MYSQL_VHOST, "mysql.sql"};
                        pgsql ->
                            {?PGSQL_VHOST, "pg.sql"}
                    end,
    SQLFile = filename:join([BaseDir, "sql", File]),
    CreationQueries = read_sql_queries(SQLFile),
    DropTableQueries = drop_table_queries(CreationQueries),
    case ejabberd_sql:sql_transaction(
           VHost, DropTableQueries ++ CreationQueries) of
        {atomic, ok} ->
            ok;
        Err ->
            ct:fail({failed_to_create_sql_tables, Type, Err})
    end.

read_sql_queries(File) ->
    case file:open(File, [read, binary]) of
        {ok, Fd} ->
            read_lines(Fd, File, []);
        Err ->
            ct:fail({open_file_failed, File, Err})
    end.

drop_table_queries(Queries) ->
    lists:foldl(
      fun(Query, Acc) ->
              case split(str:to_lower(Query)) of
                  [<<"create">>, <<"table">>, Table|_] ->
                      [<<"DROP TABLE IF EXISTS ", Table/binary, ";">>|Acc];
                  _ ->
                      Acc
              end
      end, [], Queries).

read_lines(Fd, File, Acc) ->
    case file:read_line(Fd) of
        {ok, Line} ->
            NewAcc = case str:strip(str:strip(Line, both, $\r), both, $\n) of
                         <<"--", _/binary>> ->
                             Acc;
                         <<>> ->
                             Acc;
                         _ ->
                             [Line|Acc]
                     end,
            read_lines(Fd, File, NewAcc);
        eof ->
            QueryList = str:tokens(list_to_binary(lists:reverse(Acc)), <<";">>),
            lists:flatmap(
              fun(Query) ->
                      case str:strip(str:strip(Query, both, $\r), both, $\n) of
                          <<>> ->
                              [];
                          Q ->
                              [<<Q/binary, $;>>]
                      end
              end, QueryList);
        {error, _} = Err ->
            ct:fail({read_file_failed, File, Err})
    end.

split(Data) ->
    lists:filter(
      fun(<<>>) ->
              false;
         (_) ->
              true
      end, re:split(Data, <<"\s">>)).

clear_riak_tables(Config) ->
    User = ?config(user, Config),
    Server = ?config(server, Config),
    Room = muc_room_jid(Config),
    {URoom, SRoom, _} = jid:tolower(Room),
    ejabberd_auth:remove_user(User, Server),
    ejabberd_auth:remove_user(<<"test_slave">>, Server),
    ejabberd_auth:remove_user(<<"test_master">>, Server),
    mod_muc:forget_room(Server, URoom, SRoom),
    ejabberd_riak:delete(muc_registered, {{<<"test_slave">>, Server}, SRoom}),
    ejabberd_riak:delete(muc_registered, {{<<"test_master">>, Server}, SRoom}),
    Config.
