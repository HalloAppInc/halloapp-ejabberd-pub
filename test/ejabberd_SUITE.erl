%%%-------------------------------------------------------------------
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created :  2 Jun 2013 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
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
-module(ejabberd_SUITE).
-compile([nowarn_export_all, export_all]).

-import(suite, [init_config/1, connect/1, disconnect/1, recv_message/1,
                recv/1, recv_presence/1, send/2, send_recv/2, my_jid/1,
		server_jid/1, pubsub_jid/1, proxy_jid/1, muc_jid/1,
		muc_room_jid/1, my_muc_jid/1, peer_muc_jid/1,
		mix_jid/1, mix_room_jid/1, get_features/2, recv_iq/1,
		re_register/1, is_feature_advertised/2, subscribe_to_events/1,
                is_feature_advertised/3, set_opt/3,
		auth_SASL/2, auth_SASL/3, auth_SASL/4,
                wait_for_master/1, wait_for_slave/1, flush/1,
                make_iq_result/1, start_event_relay/0, alt_room_jid/1,
                stop_event_relay/1, put_event/2, get_event/1,
                bind/1, auth/1, auth/2, open_session/1, open_session/2,
		zlib/1, starttls/1, starttls/2, close_socket/1, init_stream/1,
		auth_legacy/2, auth_legacy/3, tcp_connect/1, send_text/2,
		set_roster/3, del_roster/1]).
-include("suite.hrl").
-include("account_test_data.hrl").
-include("packets.hrl").

%TODO(thomas): add some tests reflecting current usage of ejabberd functionality

suite() ->
    % TODO: it takes too long to wait for things to timeout
    [{timetrap, {seconds, 7}}].

init_per_suite(Config) ->
    true = config:is_testing_env(),
    NewConfig = init_config(Config),
    DataDir = proplists:get_value(data_dir, NewConfig),
    LDIFFile = filename:join([DataDir, "ejabberd.ldif"]),
    {ok, _} = ldap_srv:start(LDIFFile),
    inet_db:add_host({127,0,0,1}, [binary_to_list(?S2S_VHOST),
				   binary_to_list(?MNESIA_VHOST),
				   binary_to_list(?UPLOAD_VHOST)]),
    inet_db:set_domain(binary_to_list(p1_rand:get_string())),
    inet_db:set_lookup([file, native]),
    start_ejabberd(NewConfig),
    create_test_accounts(),
    NewConfig.

flush_db() ->
    % TODO: Instead of this we should somehow clear the redis before
    % we even start the ejabberd
    tutil:cleardb(redis_accounts),
    ok.

% TODO: move those function in some util file, maybe suite_ha
create_test_accounts() ->
    flush_db(),
    % TODO: instead of the model functions it is better to use the higher level API.
    % TODO: create all 5 accounts
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?UA, ?CAMPAIGN_ID, ?TS1),
    ok = model_accounts:set_name(?UID1, ?NAME1),
    ok = ejabberd_auth:set_spub(?UID1, ?KEYPAIR1),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?UA, ?CAMPAIGN_ID, ?TS2),
    ok = model_accounts:set_name(?UID2, ?NAME2),
    ok = ejabberd_auth:set_spub(?UID2, ?KEYPAIR2),
    ok.

start_ejabberd(_) ->
    {ok, _} = application:ensure_all_started(ejabberd, transient).

end_per_suite(_Config) ->
    application:stop(ejabberd).

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
                    case lists:member(Group, Backends) of
                        true ->
                            do_init_per_group(Group, Config);
                        false ->
                            {skip, {disabled_backend, Group}}
                    end
            end
    end.

do_init_per_group(no_db, Config) ->
%%    re_register(Config),
    set_opt(persistent_room, false, Config);
do_init_per_group(mnesia, Config) ->
%%    mod_muc:shutdown_rooms(?MNESIA_VHOST),
    set_opt(server, ?COMMON_VHOST, Config);
do_init_per_group(redis, Config) ->
%%    mod_muc:shutdown_rooms(?REDIS_VHOST),
    set_opt(server, ?COMMON_VHOST, Config);
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
do_init_per_group(s2s, Config) ->
    ejabberd_config:set_option({s2s_use_starttls, ?COMMON_VHOST}, required),
    ejabberd_config:set_option(ca_file, "ca.pem"),
    Port = ?config(s2s_port, Config),
    set_opt(server, ?COMMON_VHOST,
		    set_opt(type, server,
			    set_opt(server_port, Port,
				    set_opt(stream_from, ?S2S_VHOST,
					    set_opt(lang, <<"">>, Config)))));
do_init_per_group(component, Config) ->
    Server = ?config(server, Config),
    Port = ?config(component_port, Config),
    set_opt(server, <<"component.", Server/binary>>,
        set_opt(type, component,
            set_opt(server_port, Port,
                set_opt(stream_version, undefined,
                    set_opt(lang, <<"">>, Config)))));
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
end_per_group(component, _Config) ->
    ok;
end_per_group(s2s, Config) ->
    Server = ?config(server, Config),
    ejabberd_config:set_option({s2s_use_starttls, Server}, false);
end_per_group(_GroupName, Config) ->
    stop_event_relay(Config),
    set_opt(anonymous, false, Config).

init_per_testcase(stop_ejabberd, Config) ->
    NewConfig = set_opt(resource, <<"">>,
			set_opt(anonymous, true, Config)),
    open_session(bind(auth(connect(NewConfig))));
init_per_testcase(TestCase, OrigConfig) ->
    ct:print(80, "Testcase '~p' starting", [TestCase]),
    Test = atom_to_list(TestCase),
    IsMaster = lists:suffix("_master", Test),
    IsSlave = lists:suffix("_slave", Test),
    if IsMaster or IsSlave ->
	    subscribe_to_events(OrigConfig);
       true ->
	    ok
    end,
    TestGroup = proplists:get_value(
		  name, ?config(tc_group_properties, OrigConfig)),
    Server = ?config(server, OrigConfig),
    Resource = case TestGroup of
		   anonymous ->
		       <<"">>;
		   legacy_auth ->
		       p1_rand:get_string();
		   _ ->
		       ?config(resource, OrigConfig)
	       end,
    MasterResource = ?config(master_resource, OrigConfig),
    SlaveResource = ?config(slave_resource, OrigConfig),
    Mode = if IsSlave -> slave;
	      IsMaster -> master;
	      true -> single
	   end,
    IsCarbons = lists:prefix("carbons_", Test),
    IsReplaced = lists:prefix("replaced_", Test),
    User = if IsReplaced -> ?UID1;
	      IsCarbons and not (IsMaster or IsSlave) ->
		   ?UID1;
	      IsMaster or IsCarbons -> ?UID1;
              IsSlave -> ?UID2;
              true -> ?UID1
           end,
    Nick = if IsSlave -> ?config(slave_nick, OrigConfig);
	      IsMaster -> ?config(master_nick, OrigConfig);
	      true -> ?config(nick, OrigConfig)
	   end,
    MyResource = if IsMaster and IsCarbons -> MasterResource;
		    IsSlave and IsCarbons -> SlaveResource;
		    true -> Resource
		 end,
    Slave = if IsCarbons ->
		    jid:make(?UID1, Server, SlaveResource);
	       IsReplaced ->
		    jid:make(User, Server, Resource);
	       true ->
		    jid:make(?UID2, Server, Resource)
	    end,
    Master = if IsCarbons ->
		     jid:make(?UID1, Server, MasterResource);
		IsReplaced ->
		     jid:make(User, Server, Resource);
		true ->
		     jid:make(?UID2, Server, Resource)
	     end,
    Config1 = set_opt(user, User,
		      set_opt(slave, Slave,
			      set_opt(master, Master,
				      set_opt(resource, MyResource,
					      set_opt(nick, Nick,
						      set_opt(mode, Mode, OrigConfig)))))),
    Config2 = if IsSlave ->
		      set_opt(peer_nick, ?config(master_nick, Config1), Config1);
		 IsMaster ->
		      set_opt(peer_nick, ?config(slave_nick, Config1), Config1);
		 true ->
		      Config1
	      end,
    Config = if IsSlave -> set_opt(peer, Master, Config2);
		IsMaster -> set_opt(peer, Slave, Config2);
		true -> Config2
	     end,
    case Test of
        "test_connect" ++ _ ->
            Config;
	"test_legacy_auth_feature" ->
	    connect(Config);
	"test_legacy_auth" ++ _ ->
	    init_stream(set_opt(stream_version, undefined, Config));
        "test_auth" ++ _ ->
            connect(Config);
        "test_starttls" ++ _ ->
            connect(Config);
        "test_zlib" ->
            auth(connect(starttls(connect(Config))));
        "test_register" ->
            connect(Config);
        "auth_md5" ->
            connect(Config);
        "auth_plain" ->
            connect(Config);
	"auth_external" ++ _ ->
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
     [test_legacy_auth_feature,
      test_legacy_auth,
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
       unauthenticated_message,
       unauthenticated_presence,
       test_starttls,
       test_auth,
       test_zlib,
       test_bind,
       test_open_session,
       codec_failure,
       unsupported_query,
       bad_nonza,
       invalid_from,
       ping,
       time,
       stats,
       disco]},
%%     jidprep_tests:single_cases(),
     sm_tests:single_cases(),
     sm_tests:master_slave_cases(),
        % TODO: delete muc
%%     muc_tests:single_cases(),
%%     muc_tests:master_slave_cases(),
        % TODO: delete proxy65
%%     proxy65_tests:single_cases(),
%%     proxy65_tests:master_slave_cases(),
     replaced_tests:master_slave_cases(),
     upload_tests:single_cases()
%%     carbons_tests:single_cases(),
%%     carbons_tests:master_slave_cases()
    ].

db_tests(DB) when DB == mnesia; DB == redis ->
    [{single_user, [sequence],
      [test_register,
       legacy_auth_tests(),
       auth_plain,
       auth_md5,
       presence_broadcast,
       last,
       roster_tests:single_cases(),
       private_tests:single_cases(),
       privacy_tests:single_cases(),
       vcard_tests:single_cases(),
       pubsub_tests:single_cases(),
       muc_tests:single_cases(),
       offline_tests:single_cases(),
       mam_tests:single_cases(),
       csi_tests:single_cases(),
       push_tests:single_cases(),
       test_unregister]},
     muc_tests:master_slave_cases(),
     privacy_tests:master_slave_cases(),
     pubsub_tests:master_slave_cases(),
     roster_tests:master_slave_cases(),
     offline_tests:master_slave_cases(DB),
     mam_tests:master_slave_cases(),
     vcard_tests:master_slave_cases(),
     announce_tests:master_slave_cases(),
     csi_tests:master_slave_cases(),
     push_tests:master_slave_cases()];
db_tests(DB) ->
    [{single_user, [sequence],
      [test_register,
       legacy_auth_tests(),
       auth_plain,
       auth_md5,
       presence_broadcast,
       last,
       roster_tests:single_cases(),
       private_tests:single_cases(),
       privacy_tests:single_cases(),
       vcard_tests:single_cases(),
       pubsub_tests:single_cases(),
       muc_tests:single_cases(),
       offline_tests:single_cases(),
       mam_tests:single_cases(),
       push_tests:single_cases(),
       test_unregister]},
     muc_tests:master_slave_cases(),
     privacy_tests:master_slave_cases(),
     pubsub_tests:master_slave_cases(),
     roster_tests:master_slave_cases(),
     offline_tests:master_slave_cases(DB),
     mam_tests:master_slave_cases(),
     vcard_tests:master_slave_cases(),
     announce_tests:master_slave_cases(),
     push_tests:master_slave_cases()].

ldap_tests() ->
    [{ldap_tests, [sequence],
      []}].

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
      [test_missing_from,
       test_missing_to,
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
       test_connect_s2s_unauthenticated_iq,
       test_auth_starttls]},
     {s2s_tests, [sequence],
      [test_missing_from,
       test_missing_to,
       test_invalid_from,
       bad_nonza,
       codec_failure]}].

groups() -> [
    {ldap, [sequence], ldap_tests()},
    {no_db, [sequence], no_db_tests()},
    {component, [sequence], component_tests()},
    {s2s, [sequence], s2s_tests()},
    {mnesia, [sequence], db_tests(mnesia)},
    {redis, [sequence], db_tests(redis)},
    {mysql, [sequence], db_tests(mysql)},
    {pgsql, [sequence], db_tests(pgsql)},
    {sqlite, [sequence], db_tests(sqlite)}
].

all() ->
    [
%%        {group, ldap},
     {group, no_db},
%%     {group, mnesia},
%%     {group, redis},
%%     {group, mysql},
%%     {group, pgsql},
%%     {group, sqlite},
%%     {group, component},
%%     {group, s2s},
     stop_ejabberd].

stop_ejabberd(Config) ->
    ok = application:stop(ejabberd),
    Config.


test_connect(Config) ->
    disconnect(connect(Config)).


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

auth_external(Config0) ->
    Config = connect(starttls(Config0)),
    disconnect(auth_SASL(<<"EXTERNAL">>, Config)).

auth_external_no_jid(Config0) ->
    Config = connect(starttls(Config0)),
    disconnect(auth_SASL(<<"EXTERNAL">>, Config, _ShoudFail = false,
			 {<<"">>, <<"">>, <<"">>})).

auth_external_no_user(Config0) ->
    Config = set_opt(user, <<"">>, connect(starttls(Config0))),
    disconnect(auth_SASL(<<"EXTERNAL">>, Config)).

auth_external_malformed_jid(Config0) ->
    Config = connect(starttls(Config0)),
    disconnect(auth_SASL(<<"EXTERNAL">>, Config, _ShouldFail = true,
			 {<<"">>, <<"@">>, <<"">>})).

auth_external_wrong_jid(Config0) ->
    Config = set_opt(user, <<"wrong">>,
		     connect(starttls(Config0))),
    disconnect(auth_SASL(<<"EXTERNAL">>, Config, _ShouldFail = true)).

auth_external_wrong_server(Config0) ->
    Config = connect(starttls(Config0)),
    disconnect(auth_SASL(<<"EXTERNAL">>, Config, _ShouldFail = true,
			 {<<"">>, <<"wrong.com">>, <<"">>})).

auth_external_invalid_cert(Config0) ->
    Config = connect(starttls(
		       set_opt(certfile, "self-signed-cert.pem", Config0))),
    disconnect(auth_SASL(<<"EXTERNAL">>, Config, _ShouldFail = true)).

test_legacy_auth_feature(Config) ->
    true = ?config(legacy_auth, Config),
    disconnect(Config).

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



%%%===================================================================
%%% Aux functions
%%%===================================================================
'$handle_undefined_function'(F, [Config]) when is_list(Config) ->
    case re:split(atom_to_list(F), "_", [{return, list}, {parts, 2}]) of
	[M, T] ->
	    Module = list_to_atom(M ++ "_tests"),
	    Function = list_to_atom(T),
	    case erlang:function_exported(Module, Function, 1) of
		true ->
		    Module:Function(Config);
		false ->
		    erlang:error({undef, F})
	    end;
	_ ->
	    erlang:error({undef, F})
    end;
'$handle_undefined_function'(_, _) ->
    erlang:error(undef).

%%%===================================================================
%%% SQL stuff
%%%===================================================================
create_sql_tables(sqlite, _BaseDir) ->
    ok;
create_sql_tables(Type, BaseDir) ->
    {VHost, File} = case Type of
                        mysql ->
                            Path = case ejabberd_sql:use_new_schema() of
                                true ->
                                    "mysql.new.sql";
                                false ->
                                    "mysql.sql"
                            end,
                            {?MYSQL_VHOST, Path};
                        pgsql ->
                            Path = case ejabberd_sql:use_new_schema() of
                                true ->
                                    "pg.new.sql";
                                false ->
                                    "pg.sql"
                            end,
                            {?PGSQL_VHOST, Path}
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
