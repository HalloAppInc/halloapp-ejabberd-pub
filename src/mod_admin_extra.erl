%%%-------------------------------------------------------------------
%%% File    : mod_admin_extra.erl
%%% Author  : Badlop <badlop@process-one.net>
%%% Purpose : Contributed administrative functions and commands
%%% Created : 10 Aug 2008 by Badlop <badlop@process-one.net>
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
%%%-------------------------------------------------------------------

-module(mod_admin_extra).
-author('badlop@process-one.net').

-behaviour(gen_mod).

-include("logger.hrl").

-export([start/2, stop/1, reload/3, mod_options/1, get_commands_spec/0, depends/2]).

% Commands API
-export([
    % Adminsys
    compile/1,
    get_cookie/0,
    restart_module/2,

    user_sessions_info/2,

    % Accounts
    ban_account/3,
    kick_session/4
]).


-include("ejabberd_commands.hrl").
-include("ejabberd_sm.hrl").

%%%
%%% gen_mod
%%%

start(_Host, _Opts) ->
    ejabberd_commands:register_commands(get_commands_spec()).

stop(Host) ->
    case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
        false ->
            ejabberd_commands:unregister_commands(get_commands_spec());
        true ->
            ok
    end.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

%%%
%%% Register commands
%%%

get_commands_spec() -> [
    #ejabberd_commands{name = compile, tags = [erlang],
        desc = "Recompile and reload Erlang source code file",
        module = ?MODULE, function = compile,
        args = [{file, string}],
        args_example = ["/home/me/srcs/ejabberd/mod_example.erl"],
        args_desc = ["Filename of erlang source file to compile"],
        result = {res, rescode},
        result_example = ok,
        result_desc = "Status code: 0 on success, 1 otherwise"},
    #ejabberd_commands{name = get_cookie, tags = [erlang],
        desc = "Get the Erlang cookie of this node",
        module = ?MODULE, function = get_cookie,
        args = [],
        result = {cookie, string},
        result_example = "MWTAVMODFELNLSMYXPPD",
        result_desc = "Erlang cookie used for authentication by ejabberd"},
    #ejabberd_commands{name = restart_module, tags = [erlang],
        desc = "Stop an ejabberd module, reload code and start",
        module = ?MODULE, function = restart_module,
        args = [{host, binary}, {module, binary}],
        args_example = ["myserver.com","mod_admin_extra"],
        args_desc = ["Server name", "Module to restart"],
        result = {res, integer},
        result_example = 0,
        result_desc = "Returns integer code:\n"
                  " - 0: code reloaded, module restarted\n"
                  " - 1: error: module not loaded\n"
                  " - 2: code not reloaded, but module restarted"},

    #ejabberd_commands{name = ban_account, tags = [accounts],
        desc = "Ban an account: kick sessions and set random password",
        module = ?MODULE, function = ban_account,
        args = [{user, binary}, {host, binary}, {reason, binary}],
        args_example = [<<"attacker">>, <<"myserver.com">>, <<"Spaming other users">>],
        args_desc = ["User name to ban", "Server name",
                 "Reason for banning user"],
        result = {res, rescode},
        result_example = ok,
        result_desc = "Status code: 0 on success, 1 otherwise"},

    #ejabberd_commands{name = kick_session, tags = [session],
        desc = "Kick a user session",
        module = ?MODULE, function = kick_session,
        args = [{user, binary}, {host, binary}, {resource, binary}, {reason, binary}],
        args_example = [<<"peter">>, <<"myserver.com">>, <<"Psi">>,
                <<"Stuck connection">>],
        args_desc = ["User name", "Server name", "User's resource",
                 "Reason for closing session"],
        result = {res, rescode},
        result_example = ok,
        result_desc = "Status code: 0 on success, 1 otherwise"},

    #ejabberd_commands{name = user_sessions_info,
        tags = [session],
        desc = "Get information about all sessions of a user",
        module = ?MODULE, function = user_sessions_info,
        args = [{user, binary}, {host, binary}],
        args_example = [<<"peter">>, <<"myserver.com">>],
        args_desc = ["User name", "Server name"],
        result_example = [{"c2s", "127.0.0.1", 42656,8, "ejabberd@localhost",
                                       231, <<"tka">>}],
        result = {sessions_info,
              {list,
               {session, {tuple,
                      [{connection, string},
                       {ip, string},
                       {port, integer},
                       {priority, integer},
                       {node, string},
                       {uptime, integer},
                       {resource, string}
                      ]}}
              }}}
    ].


%%%
%%% Adminsys
%%%

compile(File) ->
    Ebin = filename:join(code:lib_dir(ejabberd), "ebin"),
    case ext_mod:compile_erlang_file(Ebin, File) of
        {ok, Module} ->
            code:purge(Module),
            code:load_file(Module),
            ok;
        _ ->
            error
    end.

get_cookie() ->
    atom_to_list(erlang:get_cookie()).

restart_module(Host, Module) when is_binary(Module) ->
    restart_module(Host, misc:binary_to_atom(Module));
restart_module(Host, Module) when is_atom(Module) ->
    case gen_mod:is_loaded(Host, Module) of
        false ->
            % not a running module, force code reload anyway
            code:purge(Module),
            code:delete(Module),
            code:load_file(Module),
            1;
        true ->
            gen_mod:stop_module(Host, Module),
            case code:soft_purge(Module) of
                true ->
                    code:delete(Module),
                    code:load_file(Module),
                    gen_mod:start_module(Host, Module),
                    0;
                false ->
                    gen_mod:start_module(Host, Module),
                    2
            end
    end.

%%%
%%% Accounts
%%%

%%
%% Ban account

ban_account(User, Host, ReasonText) ->
    Reason = prepare_reason(ReasonText),
    kick_sessions(User, Host, Reason),
    set_random_password(User, Host, Reason),
    ok.

kick_session(User, Server, Resource, Reason) ->
    kick_this_session(User, Server, Resource, Reason),
    ok.

kick_sessions(User, Server, Reason) ->
    lists:map(
        fun(Resource) ->
            kick_this_session(User, Server, Resource, Reason)
        end,
        ejabberd_sm:get_user_resources(User, Server)).

set_random_password(User, Server, Reason) ->
    NewPass = build_random_password(Reason),
    set_password_auth(User, Server, NewPass).

build_random_password(Reason) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    Date = str:format("~4..0B~2..0B~2..0BT~2..0B:~2..0B:~2..0B",
              [Year, Month, Day, Hour, Minute, Second]),
    RandomString = p1_rand:get_string(),
    <<"BANNED_ACCOUNT--", Date/binary, "--", RandomString/binary, "--", Reason/binary>>.

set_password_auth(_User, _Server, _Password) ->
    %TODO: maybe set spub key or something instead. Evaluate if we use this file!
    ok.

prepare_reason([]) ->
    <<"Kicked by administrator">>;
prepare_reason([Reason]) ->
    Reason;
prepare_reason(Reason) when is_binary(Reason) ->
    Reason.

%%%
%%% Sessions
%%%


kick_this_session(User, Server, Resource, Reason) ->
    ejabberd_sm:route(jid:make(User, Server, Resource), {exit, Reason}).


user_sessions_info(User, Host) ->
    lists:filtermap(
        fun(Resource) ->
            case user_session_info(User, Host, Resource) of
                offline -> false;
                Info -> {true, Info}
            end
        end, ejabberd_sm:get_user_resources(User, Host)).

user_session_info(User, Host, Resource) ->
    CurrentSec = calendar:datetime_to_gregorian_seconds({date(), time()}),
    case ejabberd_sm:get_user_info(User, Host, Resource) of
        offline ->
            offline;
        Info ->
            Now = proplists:get_value(ts, Info),
            Pid = proplists:get_value(pid, Info),
%%            {_U, _Resource, Status, StatusText} = get_presence(Pid),
            Priority = proplists:get_value(priority, Info),
            Conn = proplists:get_value(conn, Info),
            {Ip, Port} = proplists:get_value(ip, Info),
            IPS = inet_parse:ntoa(Ip),
            NodeS = atom_to_list(node(Pid)),
            Uptime = CurrentSec - calendar:datetime_to_gregorian_seconds(
                        calendar:now_to_local_time(Now)),
            {atom_to_list(Conn), IPS, Port, num_prio(Priority), NodeS, Uptime, Resource}
    end.


num_prio(Priority) when is_integer(Priority) ->
    Priority;
num_prio(_) ->
    -1.

mod_options(_) -> [].
