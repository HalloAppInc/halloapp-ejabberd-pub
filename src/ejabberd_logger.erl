%%%-------------------------------------------------------------------
%%% File    : ejabberd_logger.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Purpose : ejabberd logger wrapper
%%% Created : 12 May 2013 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2013-2019   ProcessOne
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

%%%-------------------------------------------------------------------
-module(ejabberd_logger).

%% API
-export([start/0, restart/0, reopen_log/0, rotate_log/0, get/0, set/1,
	 get_log_path/0]).


-type loglevel() :: 0 | 1 | 2 | 3 | 4 | 5.
-type lager_level() :: none | emergency | alert | critical |
		       error | warning | notice | info | debug.

-spec start() -> ok.
-spec get_log_path() -> string().
-spec reopen_log() -> ok.
-spec rotate_log() -> ok.
-spec get() -> {loglevel(), atom(), string()}.
-spec set(loglevel()) -> ok.

%%%===================================================================
%%% API
%%%===================================================================
%% @doc Returns the full path to the ejabberd log file.
%% It first checks for application configuration parameter 'log_path'.
%% If not defined it checks the environment variable EJABBERD_LOG_PATH.
%% And if that one is neither defined, returns the default value:
%% "ejabberd.log" in current directory.
%% Note: If the directory where to place the ejabberd log file to not exist,
%% it is not created and no log file will be generated.
%% @spec () -> string()
get_log_path() ->
    case ejabberd_config:env_binary_to_list(ejabberd, log_path) of
	{ok, Path} ->
	    Path;
	undefined ->
	    case os:getenv("EJABBERD_LOG_PATH") of
		false ->
		    "ejabberd.log";
		Path ->
		    Path
	    end
    end.

get_integer_env(Name, Default) ->
    case application:get_env(ejabberd, Name) of
        {ok, I} when is_integer(I), I>=0 ->
            I;
        undefined ->
            Default;
        {ok, Junk} ->
            error_logger:error_msg("wrong value for ~ts: ~p; "
                                   "using ~p as a fallback~n",
                                   [Name, Junk, Default]),
            Default
    end.
get_string_env(Name, Default) ->
    case application:get_env(ejabberd, Name) of
        {ok, L} when is_list(L) ->
            L;
        undefined ->
            Default;
        {ok, Junk} ->
            error_logger:error_msg("wrong value for ~ts: ~p; "
                                   "using ~p as a fallback~n",
                                   [Name, Junk, Default]),
            Default
    end.

%% @spec () -> ok
start() ->
    start(config:get_default_log_level()).

-spec start(loglevel()) -> ok.
start(Level) ->
    LLevel = get_lager_loglevel(Level),
    StartedApps = application:which_applications(5000),
    case lists:keyfind(logger, 1, StartedApps) of
        %% Elixir logger is started. We assume everything is in place
        %% to use lager to Elixir logger bridge.
        {logger, _, _} ->
            error_logger:info_msg("Ignoring ejabberd logger options, using Elixir Logger.", []),
            %% Do not start lager, we rely on Elixir Logger
            do_start_for_logger(LLevel);
        _ ->
            do_start(LLevel)
    end.

do_start_for_logger(Level) ->
    application:load(sasl),
    application:set_env(sasl, sasl_error_logger, false),
    application:load(lager),
    application:set_env(lager, error_logger_redirect, false),
    application:set_env(lager, error_logger_whitelist, ['Elixir.Logger.ErrorHandler']),
    application:set_env(lager, crash_log, false),
    application:set_env(lager, handlers, [{elixir_logger_backend, [{level, Level}]}]),
    ejabberd:start_app(lager),
    ok.

-spec do_start(atom()) -> ok.
do_start(Level) ->
    application:load(sasl),
    application:set_env(sasl, sasl_error_logger, false),
    application:load(lager),
    ConsoleLog = get_log_path(),
    Dir = filename:dirname(ConsoleLog),
    ErrorLog = filename:join([Dir, "error.log"]),
    MsgTraceLog = filename:join([Dir, "msg_trace.log"]),
    CrashLog = filename:join([Dir, "crash.log"]),
    LogRotateDate = get_string_env(log_rotate_date, ""),
    LogRotateSize = get_integer_env(log_rotate_size, 10*1024*1024),
    LogRotateCount = get_integer_env(log_rotate_count, 1),
    LogRateLimit = get_integer_env(log_rate_limit, 100),

    % Add the module:function:line
    HalloappFormatterConfigConsole = [
        date, " ", time, color, " [",severity,"] ", pid, " ", module, ":", function, ":", line, " ", message, "\e[0m\r\n"],
    HalloappFormatterConfigFile = [
        date, " ", time, " [",severity,"] ", pid, " ", module, ":", function, ":", line, " ", message, "\n"],
    HalloappTraceFormatterConfig = [
        date, " ", time, ": ", message, "\n"],

    application:set_env(lager, colored, true),
    application:set_env(lager, error_logger_hwm, LogRateLimit),
    application:set_env(lager, handlers,
        [
            {lager_console_backend, [
                {level, Level},
                {formatter, lager_default_formatter},
                {formatter_config, HalloappFormatterConfigConsole}]},
            {lager_file_backend, [
                {file, ConsoleLog},
                {level, Level},
                {formatter, lager_default_formatter},
                {formatter_config, HalloappFormatterConfigFile},
                {date, LogRotateDate},
                {count, LogRotateCount},
                {size, LogRotateSize}]},
            {lager_file_backend, [
                {file, ErrorLog},
                {level, error},
                {formatter, lager_default_formatter},
                {formatter_config, HalloappFormatterConfigFile},
                {date, LogRotateDate},
                {count, LogRotateCount},
                {size, LogRotateSize}]}]),
    application:set_env(lager, extra_sinks, [
        {xmpp_trace_lager_event, [
            {handlers, [
                {lager_file_backend, [
                    {file, MsgTraceLog},
                    {level, info},
                    {formatter, lager_default_formatter},
                    {formatter_config, HalloappTraceFormatterConfig},
                    {date, LogRotateDate},
                    {count, 3},
                    {size, 0}]
                }]
            },
            {async_threshold, 500},
            {async_threshold_window, 50}]
        }]),
%%    application:set_env(lager, traces, [
%%        {{lager_file_backend, MsgTraceLog}, [{module, ejabberd_hooks}], debug}
%%    ]),
    application:set_env(lager, crash_log, CrashLog),
    application:set_env(lager, crash_log_date, LogRotateDate),
    application:set_env(lager, crash_log_size, LogRotateSize),
    application:set_env(lager, crash_log_count, LogRotateCount),
    ejabberd:start_app(lager),
    lists:foreach(fun(Handler) ->
			  lager:set_loghwm(Handler, LogRateLimit)
		  end, gen_event:which_handlers(lager_event)).

restart() ->
    Level = ejabberd_option:loglevel(),
    application:stop(lager),
    start(Level).

%% @spec () -> ok
reopen_log() ->
    %% Lager detects external log rotation automatically.
    ok.

%% @spec () -> ok
rotate_log() ->
    catch lager_crash_log ! rotate,
    lists:foreach(
      fun({lager_file_backend, File}) ->
              whereis(lager_event) ! {rotate, File};
         (_) ->
              ok
      end, gen_event:which_handlers(lager_event)).

%% @spec () -> {loglevel(), atom(), string()}
get() ->
    case get_lager_loglevel() of
        none -> {0, no_log, "No log"};
        emergency -> {1, critical, "Critical"};
        alert -> {1, critical, "Critical"};
        critical -> {1, critical, "Critical"};
        error -> {2, error, "Error"};
        warning -> {3, warning, "Warning"};
        notice -> {3, warning, "Warning"};
        info -> {4, info, "Info"};
        debug -> {5, debug, "Debug"}
    end.

set(LogLevel) when is_integer(LogLevel) ->
    LagerLogLevel = get_lager_loglevel(LogLevel),
    case get_lager_loglevel() of
        LagerLogLevel ->
            ok;
        _ ->
            ConsoleLog = get_log_path(),
            lists:foreach(
              fun({lager_file_backend, File} = H) when File == ConsoleLog ->
                      lager:set_loglevel(H, LagerLogLevel);
                 (lager_console_backend = H) ->
                      lager:set_loglevel(H, LagerLogLevel);
                 (elixir_logger_backend = H) ->
                      lager:set_loglevel(H, LagerLogLevel);
                 (_) ->
                      ok
              end, get_lager_handlers())
    end,
    case LogLevel of
	5 -> xmpp:set_config([{debug, true}]);
	_ -> xmpp:set_config([{debug, false}])
    end.

get_lager_loglevel() ->
    Handlers = get_lager_handlers(),
    lists:foldl(fun(lager_console_backend, _Acc) ->
                        lager:get_loglevel(lager_console_backend);
                   (elixir_logger_backend, _Acc) ->
                        lager:get_loglevel(elixir_logger_backend);
                   (_, Acc) ->
                        Acc
                end,
                none, Handlers).

-spec get_lager_loglevel(loglevel()) -> lager_level().
get_lager_loglevel(LogLevel) ->
    case LogLevel of
	0 -> none;
	1 -> critical;
	2 -> error;
	3 -> warning;
	4 -> info;
	5 -> debug
    end.

get_lager_handlers() ->
    case catch gen_event:which_handlers(lager_event) of
        {'EXIT',noproc} ->
            [];
        Result ->
            Result
    end.

-spec get_lager_version() -> string().
get_lager_version() ->
    Apps = application:loaded_applications(),
    case lists:keyfind(lager, 1, Apps) of
	{_, _, Vsn} -> Vsn;
	false -> "0.0.0"
    end.
