%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 03. Sep 2020 2:51 PM
%%%-------------------------------------------------------------------
-module(ha_suite).
-author("nikola").

%% API
-export([init_config/1]).

-include("suite.hrl").
-include_lib("kernel/include/file.hrl").



%%%===================================================================
%%% API
%%%===================================================================
init_config(Config) ->
    DataDir = proplists:get_value(data_dir, Config),
    PrivDir = proplists:get_value(priv_dir, Config),
    [_, _|Tail] = lists:reverse(filename:split(DataDir)),
    BaseDir = filename:join(lists:reverse(Tail)),
    ConfigPath = filename:join([DataDir, "ejabberd.yml"]),
    LogPath = filename:join([PrivDir, "ejabberd.log"]),
    SASLPath = filename:join([PrivDir, "sasl.log"]),
    % TODO: do we still mnesia?
    MnesiaDir = filename:join([PrivDir, "mnesia"]),
    CertFile = filename:join([DataDir, "cert.pem"]),
    SelfSignedCertFile = filename:join([DataDir, "self-signed-cert.pem"]),
    CAFile = filename:join([DataDir, "ca.pem"]),
    {ok, CWD} = file:get_cwd(),
    {ok, _} = file:copy(CertFile, filename:join([CWD, "cert.pem"])),
    {ok, _} = file:copy(SelfSignedCertFile, filename:join([CWD, "self-signed-cert.pem"])),
    {ok, _} = file:copy(CAFile, filename:join([CWD, "ca.pem"])),
%%    {ok, MacrosContentTpl} = file:read_file(MacrosPathTpl),
%%    Password = <<"password!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>,
%%    Backends = get_config_backends(),
%%    MacrosContent = process_config_tpl(
%%        MacrosContentTpl,
%%        [{c2s_port, 5222},
%%            {loglevel, 4},
%%            {new_schema, false},
%%            {s2s_port, 5269},
%%            {component_port, 5270},
%%            {web_port, 5280},
%%            {password, Password},
%%            {mysql_server, <<"localhost">>},
%%            {mysql_port, 3306},
%%            {mysql_db, <<"ejabberd_test">>},
%%            {mysql_user, <<"ejabberd_test">>},
%%            {mysql_pass, <<"ejabberd_test">>},
%%            {pgsql_server, <<"localhost">>},
%%            {pgsql_port, 5432},
%%            {pgsql_db, <<"ejabberd_test">>},
%%            {pgsql_user, <<"ejabberd_test">>},
%%            {pgsql_pass, <<"ejabberd_test">>},
%%            {priv_dir, PrivDir}]),
    MacrosPath = filename:join([CWD, "macros.yml"]),
%%    ok = file:write_file(MacrosPath, MacrosContent),
%%    copy_backend_configs(DataDir, CWD, Backends),
    setup_ejabberd_lib_path(Config),
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
    [
        {server_port, ct:get_config(c2s_port, 5222)},
        {server_host, "localhost"},
        {component_port, ct:get_config(component_port, 5270)},
        {s2s_port, ct:get_config(s2s_port, 5269)},
        {server, ?COMMON_VHOST},
        {user, <<"test_single!#$%^*()`~+-;_=[]{}|\\">>},
        {nick, <<"nick!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
        {master_nick, <<"master_nick!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
        {slave_nick, <<"slave_nick!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
        {room_subject, <<"hello, world!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>},
        {certfile, CertFile},
        {persistent_room, true},
        {anonymous, false},
        {type, client},
        {xmlns, ?NS_CLIENT},
        {ns_stream, ?NS_STREAM},
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
        {slave_resource, <<"slave_resource!@#$%^&*()'\"`~<>+-/;:_=[]{}|\\">>}
%%        {password, Password},
%%        {backends, Backends}
        | Config].


find_top_dir(Dir) ->
    case file:read_file_info(filename:join([Dir, ebin])) of
        {ok, #file_info{type = directory}} ->
            Dir;
        _ ->
            find_top_dir(filename:dirname(Dir))
    end.


setup_ejabberd_lib_path(Config) ->
    case code:lib_dir(ejabberd) of
        {error, Error} ->
        ct:pal("ejabberd_lib_path needs work ~p~n", [Error]),
            DataDir = proplists:get_value(data_dir, Config),
            {ok, CWD} = file:get_cwd(),
            NewEjPath = filename:join([CWD, "ejabberd-0.0.1"]),
            TopDir = find_top_dir(DataDir),
            % TODO: this symlink I think is causing a loop in the FS.
            % This causes an error later with the coverage tool.
%%            ok = file:make_symlink(TopDir, NewEjPath),
            code:replace_path(ejabberd, TopDir);
        _ ->
            ct:pal("ejabberd_lib_path ok~n"),
            ok
    end.

