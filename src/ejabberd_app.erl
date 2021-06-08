%%%----------------------------------------------------------------------
%%% File    : ejabberd_app.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : ejabberd's application callback module
%%% Created : 31 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_app).

-author('alexey@process-one.net').

-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).

-include("logger.hrl").
-include("ejabberd_stacktrace.hrl").

%%%
%%% Application API
%%%

start(normal, _Args) ->
    try
        {T1, _} = statistics(wall_clock),
        ejabberd_logger:start(),
        write_pid_file(),
        start_included_apps(),
        start_elixir_application(),
        setup_if_elixir_conf_used(),
        %% Load all message definitions to the nif module.
        enif_protobuf:load_cache(server:get_msg_defs()),
        case ejabberd_config:load() of
            ok ->
                ha_redis:start(),
                ?INFO("starting ejabberd_mnesia"),
                ejabberd_mnesia:start(),
                file_queue_init(),
                ?INFO("starting ejabberd_sup"),
                case ejabberd_sup:start_link() of
                    {ok, SupPid} ->
                        ?INFO("Ejabberd supervisor started"),
                        ejabberd_system_monitor:start(),
                        register_elixir_config_hooks(),
                        ejabberd_hooks:run(ejabberd_started, []),
                        ejabberd:check_apps(),
                        {T2, _} = statistics(wall_clock),
                        ?INFO("ejabberd ~ts is started in the node ~p in ~.2fs",
                            [ejabberd_option:version(), node(), (T2-T1)/1000]),
                        {ok, SupPid};
                    Err ->
                        ?CRITICAL("Failed to start ejabberd application: ~p", [Err]),
                        ejabberd:halt()
                end;
            Err ->
                ?CRITICAL("Failed to start ejabberd application: ~ts",
                    [ejabberd_config:format_error(Err)]),
                ejabberd:halt()
        end
    catch throw:{?MODULE, Error} ->
        ?DEBUG("Failed to start ejabberd application: ~p", [Error]),
        ejabberd:halt()
    end;
start(_, _) ->
    {error, badarg}.

start_included_apps() ->
    {ok, Apps} = application:get_key(ejabberd, included_applications),
    lists:foreach(
        fun (mnesia) ->
                ok;
            (lager)->
                ok;
            (os_mon)->
                ok;
            (App) ->
                application:ensure_all_started(App)
        end, Apps).

%% Prepare the application for termination.
%% This function is called when an application is about to be stopped,
%% before shutting down the processes of the application.
prep_stop(State) ->
    ?INFO("stopping..."),
    ejabberd_monitor:stop(),
    ejabberd_hooks:run(ejabberd_stopping, []),
    ejabberd_listener:stop(),
    % We first try to terminate all the c2s processes and wait some amount of time for them
    % to shutdown gracefully. We want to allow the c2s process some time time to terminate,
    % before we move on to the next step and start stoping the modules
    ejabberd_sm:prep_stop(),
    % After that we continue with the shutdown procedure by stopping all the module. At this
    % stage we might still have some c2s processes running. Module stopping needs to happen
    % after c2s process termination in order for c2s processes to terminate gracefully.
    gen_mod:stop(),
    % Lastly when ejabberd_sm stops it will remove from the redis_sessions all the c2s processes
    % that have not yet terminated.
    % We should stop the modules first before ejabberd_sm since ejabberd_sm is core component.
    ejabberd_sm:stop(),
    ?INFO("end prep_stop"),
    State.

%% All the processes were killed when this function is called
stop(_State) ->
    ?INFO("ejabberd ~ts is stopped in the node ~p",
        [ejabberd_option:version(), node()]),
    delete_pid_file().

%%%
%%% Internal functions
%%%

%%%
%%% PID file
%%%

write_pid_file() ->
    case ejabberd:get_pid_file() of
        false ->
            ok;
        PidFilename ->
            write_pid_file(os:getpid(), PidFilename)
    end.

write_pid_file(Pid, PidFilename) ->
    case file:write_file(PidFilename, io_lib:format("~ts~n", [Pid])) of
        ok ->
            ok;
        {error, Reason} = Err ->
            ?CRITICAL("Cannot write PID file ~ts: ~ts",
                [PidFilename, file:format_error(Reason)]),
            throw({?MODULE, Err})
    end.

delete_pid_file() ->
    case ejabberd:get_pid_file() of
        false ->
            ok;
        PidFilename ->
            file:delete(PidFilename)
    end.

file_queue_init() ->
    QueueDir = case ejabberd_option:queue_dir() of
        undefined ->
            MnesiaDir = mnesia:system_info(directory),
            filename:join(MnesiaDir, "queue");
        Path ->
            Path
    end,
    case p1_queue:start(QueueDir) of
        ok -> ok;
        Err -> throw({?MODULE, Err})
    end.

-ifdef(ELIXIR_ENABLED).
is_using_elixir_config() ->
    Config = ejabberd_config:path(),
    'Elixir.Ejabberd.ConfigUtil':is_elixir_config(Config).

setup_if_elixir_conf_used() ->
    case is_using_elixir_config() of
        true -> 'Elixir.Ejabberd.Config.Store':start_link();
        false -> ok
    end.

register_elixir_config_hooks() ->
    case is_using_elixir_config() of
        true -> 'Elixir.Ejabberd.Config':start_hooks();
        false -> ok
    end.

start_elixir_application() ->
    case application:ensure_started(elixir) of
        ok -> ok;
        {error, _Msg} -> ?ERROR("Elixir application not started.", [])
    end.
-else.
setup_if_elixir_conf_used() -> ok.
register_elixir_config_hooks() -> ok.
start_elixir_application() -> ok.
-endif.
