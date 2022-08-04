%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 03. Sep 2020 2:51 PM
%%%-------------------------------------------------------------------
-module(suite_ha).
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
    [_, _, _, _, _, _|Tail] = lists:reverse(filename:split(DataDir)),
    BaseDir = filename:join(lists:reverse(Tail)),
    ConfigPath = setup_test_config(BaseDir, DataDir),
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

%%    MacrosPath = filename:join([CWD, "macros.yml"]),

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
    [
        {server_port, ct:get_config(c2s_port, 5222)},
        {server_host, "localhost"},
        {component_port, ct:get_config(component_port, 5270)},
        {server, ?COMMON_VHOST},
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
        {receiver, undefined}
        | Config].


% Copy the main config file and replace few things
setup_test_config(BaseDir, DataDir) ->
    application:ensure_started(fast_yaml),

    MainConfigPath = filename:join([BaseDir, "ejabberd.yml"]),
    ConfigPath = filename:join([DataDir, "ejabberd.auto.yml"]),

    {ok, [ConfigPropList]} = fast_yaml:decode_from_file(MainConfigPath, [plain_as_atom, sane_scalars]),

    ConfigPropList1 = lists:keystore(<<"certfiles">>, 1, ConfigPropList, {<<"certfiles">>, [<<"cert.pem">>]}),

    ok = file:write_file(ConfigPath, fast_yaml:encode(ConfigPropList1)),
    ConfigPath.


find_top_dir(Dir) ->
    case file:read_file_info(filename:join([Dir, ebin])) of
        {ok, #file_info{type = directory}} ->
            Dir;
        _ ->
            find_top_dir(filename:dirname(Dir))
    end.


setup_ejabberd_lib_path(Config) ->
    case code:lib_dir(ejabberd) of
        {error, _Error} ->
            DataDir = proplists:get_value(data_dir, Config),
            TopDir = find_top_dir(DataDir),
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


