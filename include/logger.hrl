%%%----------------------------------------------------------------------
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

-ifndef(LOGGER_HRL).
-define(LOGGER_HRL, 1).

-define(PRINT(Format, Args), io:format(Format, Args)).
-compile([{parse_transform, lager_transform}]).


-define(DEBUG(Format),
    begin lager:debug(Format, []), ok end).

-define(DEBUG(Format, Args),
    begin lager:debug(Format, Args), ok end).


-define(INFO(Format),
    begin lager:info(Format, []), ok end).

-define(INFO(Format, Args),
    begin lager:info(Format, Args), ok end).


-define(WARNING(Format),
    begin lager:warning(Format, []), ok end).

-define(WARNING(Format, Args),
    begin lager:warning([{fmt, Format}, {args, Args}], Format, Args), ok end).


-define(ERROR(Format),
    begin lager:error(Format, []), ok end).

-define(ERROR(Format, Args),
    begin lager:error([{fmt, Format}, {args, Args}], Format, Args), ok end).


-define(CRITICAL(Format),
    begin lager:critical(Format, []), ok end).

-define(CRITICAL(Format, Args),
    begin lager:critical([{fmt, Format}, {args, Args}], Format, Args), ok end).


%% Keep the old ones for now.
%% TODO(murali@): remove them eventually.
-define(INFO_MSG(Format, Args),
    begin lager:info(Format, Args), ok end).


-define(WARNING_MSG(Format, Args),
    begin lager:warning([{fmt, Format}, {args, Args}], Format, Args), ok end).


-define(ERROR_MSG(Format, Args),
    begin lager:error([{fmt, Format}, {args, Args}], Format, Args), ok end).


-define(CRITICAL_MSG(Format, Args),
    begin lager:critical([{fmt, Format}, {args, Args}], Format, Args), ok end).


%% Use only when trying to troubleshoot test problem with ExUnit
-define(EXUNIT_LOG(Format, Args),
        case lists:keyfind(logger, 1, application:loaded_applications()) of
            false -> ok;
            _ -> 'Elixir.Logger':bare_log(error, io_lib:format(Format, Args), [?MODULE])
        end).

%% Uncomment if you want to debug p1_fsm/gen_fsm
%%-define(DBGFSM, true).

-endif.
