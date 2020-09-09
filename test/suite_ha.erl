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

    % TODO: we can try to use the macros to share .yml config file with the prod
%%    MacrosPath = filename:join([CWD, "macros.yml"]),

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
        {receiver, undefined}
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
        {error, _Error} ->
            DataDir = proplists:get_value(data_dir, Config),
            TopDir = find_top_dir(DataDir),
            code:replace_path(ejabberd, TopDir);
        _ ->
            ok
    end.

