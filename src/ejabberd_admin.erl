%%%-------------------------------------------------------------------
%%% File    : ejabberd_admin.erl
%%% Author  : Mickael Remond <mremond@process-one.net>
%%% Purpose : Administrative functions and commands
%%% Created :  7 May 2006 by Mickael Remond <mremond@process-one.net>
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

-module(ejabberd_admin).
-author('mickael.remond@process-one.net').

-behaviour(gen_server).

-define(CURRENT_LIB_PATH, "/home/ha/pkg/ejabberd/current/lib/").

-include_lib("stdlib/include/assert.hrl").

-export([
    start_link/0,
    %% Server
    status/0, reopen_log/0, rotate_log/0,
    set_loglevel/1,
    stop_kindly/2,
    registered_vhosts/0,
    reload_config/0,
    dump_config/1,
    convert_to_yaml/2,
    %% Cluster
    join_cluster/1, leave_cluster/1, list_cluster/0,
    %% Erlang
    update_list/0, update/1,
    %% Accounts
    register/3, unregister/2,check_and_register/5, check_and_register_spub/5,
    registered_users/1,
    enroll/3, unenroll/2,
    enrolled_users/1, get_user_passcode/2,
    register_push/4, unregister_push/2,
    %% Mnesia
    set_master/1,
    backup_mnesia/1, restore_mnesia/1,
    dump_mnesia/1, dump_table/2, load_mnesia/1,
    mnesia_info/0, mnesia_table_info/1,
    install_fallback_mnesia/1,
    dump_to_textfile/1, dump_to_textfile/2,
    mnesia_change_nodename/4,
    restore/1, % Still used by some modules
    clear_cache/0,
    fix_account_counters/0,
    add_uid_trace/1,
    remove_uid_trace/1,
    add_phone_trace/1,
    remove_phone_trace/1,
    uid_info/1,
    phone_info/1,
    group_info/1,
    send_ios_push/3,
    update_code_paths/0,
    list_changed_modules/0,
    hotload_modules/1,
    hot_code_reload/0,
    get_commands_spec/0
]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("logger.hrl").
-include("account.hrl").
-include("groups.hrl").
-include("time.hrl").
-include("translate.hrl").
-include("ejabberd_commands.hrl").

-record(state, {}).

start_link() ->
    ?INFO("start ~w", [?MODULE]),
    Result = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
    ?INFO("start_link ~w", [Result]),
    Result.

init([]) ->
    process_flag(trap_exit, true),
    ejabberd_commands:register_commands(get_commands_spec()),
    {ok, #state{}}.

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ejabberd_commands:unregister_commands(get_commands_spec()).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%
%%% ejabberd commands
%%%

get_commands_spec() ->
    [
     %% The commands status, stop and restart are implemented also in ejabberd_ctl
     %% They are defined here so that other interfaces can use them too
    #ejabberd_commands{name = status, tags = [server],
        desc = "Get status of the ejabberd server",
        module = ?MODULE, function = status,
        result_desc = "Result tuple",
        result_example = {ok, <<"The node ejabberd@localhost is started with status: started"
                    "ejabberd X.X is running in that node">>},
        args = [], result = {res, restuple}},
    #ejabberd_commands{name = reset_auth_service, tags = [server],
        desc = "Reset auth service: Server will start sending auth failures to clients again",
        module = mod_auth_monitor, function = reset_auth_service,
        args = [], result = {res, restuple}},
    #ejabberd_commands{name = stop, tags = [server],
        desc = "Stop ejabberd gracefully",
        module = init, function = stop,
        args = [], result = {res, rescode}},
    #ejabberd_commands{name = restart, tags = [server],
        desc = "Restart ejabberd gracefully",
        module = init, function = restart,
        args = [], result = {res, rescode}},
    #ejabberd_commands{name = reopen_log, tags = [logs, server],
        desc = "Reopen the log files",
        policy = admin,
        module = ?MODULE, function = reopen_log,
        args = [], result = {res, rescode}},
    #ejabberd_commands{name = rotate_log, tags = [logs, server],
        desc = "Rotate the log files",
        module = ?MODULE, function = rotate_log,
        args = [], result = {res, rescode}},
    #ejabberd_commands{name = stop_kindly, tags = [server],
        desc = "Inform users and rooms, wait, and stop the server",
        longdesc = "Provide the delay in seconds, and the "
        "announcement quoted, for example: \n"
        "ejabberdctl stop_kindly 60 "
        "\\\"The server will stop in one minute.\\\"",
        module = ?MODULE, function = stop_kindly,
        args_desc = ["Seconds to wait", "Announcement to send, with quotes"],
        args_example = [60, <<"Server will stop now.">>],
        args = [{delay, integer}, {announcement, string}],
        result = {res, rescode}},
    #ejabberd_commands{name = get_loglevel, tags = [logs, server],
        desc = "Get the current loglevel",
        module = ejabberd_logger, function = get,
        result_desc = "Tuple with the log level number, its keyword and description",
        result_example = {4, info, <<"Info">>},
        args = [],
                    result = {leveltuple, {tuple, [{levelnumber, integer},
                                                   {levelatom, atom},
                                                   {leveldesc, string}
                                                  ]}}},
    #ejabberd_commands{name = set_loglevel, tags = [logs, server],
        desc = "Set the loglevel (0 to 5)",
        module = ?MODULE, function = set_loglevel,
        args_desc = ["Integer of the desired logging level, between 1 and 5"],
        args_example = [5],
        result_desc = "The type of logger module used",
        result_example = lager,
        args = [{loglevel, integer}],
        result = {res, rescode}},

    #ejabberd_commands{name = update_list, tags = [server],
        desc = "List modified modules that can be updated",
        module = ?MODULE, function = update_list,
        args = [],
        result_example = ["mod_configure", "mod_vcard"],
        result = {modules, {list, {module, string}}}},
    #ejabberd_commands{name = update, tags = [server],
        desc = "Update the given module, or use the keyword: all",
        module = ?MODULE, function = update,
        args_example = ["mod_vcard"],
        args = [{module, string}],
        result = {res, restuple}},

    #ejabberd_commands{name = register, tags = [accounts],
        desc = "Register a user",
        policy = admin,
        module = ?MODULE, function = register,
        args_desc = ["Username", "Local vhost served by ejabberd", "Password"],
        args_example = [<<"bob">>, <<"example.com">>, <<"SomEPass44">>],
        args = [{user, binary}, {host, binary}, {password, binary}],
        result = {res, restuple}},
    #ejabberd_commands{name = unregister, tags = [accounts],
        desc = "Unregister a user",
                    policy = admin,
        module = ?MODULE, function = unregister,
        args_desc = ["Username", "Local vhost served by ejabberd"],
        args_example = [<<"bob">>, <<"example.com">>],
        args = [{user, binary}, {host, binary}],
        result = {res, restuple}},
    #ejabberd_commands{name = registered_users, tags = [accounts],
        desc = "List all registered users in HOST",
        module = ?MODULE, function = registered_users,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>],
        result_desc = "List of registered accounts usernames",
        result_example = [<<"user1">>, <<"user2">>],
        args = [{host, binary}],
        result = {users, {list, {username, string}}}},

    #ejabberd_commands{name = enroll, tags = [accounts],
                    desc = "Enroll a user",
                    policy = admin,
                    module = ?MODULE, function = enroll,
                    args_desc = ["Username", "Local vhost served by ejabberd", "Passcode"],
                    args_example = [<<"bob">>, <<"example.com">>, <<"442368">>],
                    args = [{user, binary}, {host, binary}, {passcode, binary}],
                    result = {res, restuple}},
    #ejabberd_commands{name = unenroll, tags = [accounts],
                    desc = "Unenroll a user",
                    policy = admin,
                    module = ?MODULE, function = unenroll,
                    args_desc = ["Username", "Local vhost served by ejabberd"],
                    args_example = [<<"bob">>, <<"example.com">>],
                    args = [{user, binary}, {host, binary}],
                    result = {res, restuple}},
    #ejabberd_commands{name = enrolled_users, tags = [accounts],
                    desc = "List all enrolled users in HOST",
                    module = ?MODULE, function = enrolled_users,
                    args_desc = ["Local vhost"],
                    args_example = [<<"example.com">>],
                    result_desc = "List of enrolled accounts usernames",
                    result_example = [<<"user1">>, <<"user2">>],
                    args = [{host, binary}],
                    result = {users, {list, {username, string}}}},
    #ejabberd_commands{name = get_user_passcode, tags = [accounts],
                    desc = "Get the passcode of an enrolled user",
                    policy = admin,
                    module = ?MODULE, function = get_user_passcode,
                    args_desc = ["Username", "Local vhost served by ejabberd"],
                    args_example = [<<"bob">>, <<"example.com">>],
                    args = [{user, binary}, {host, binary}],
                    result = {res, restuple}},

    #ejabberd_commands{name = register_push, tags = [accounts],
                    desc = "Register a user for push notifications",
                    policy = admin,
                    module = ?MODULE, function = register_push,
                    args_desc = ["Username", "Local vhost served by ejabberd", "os: either ios or android", "push token"],
                    args_example = [<<"bob">>, <<"example.com">>, <<"ios">>, <<"3ad47856cbdjfk....48489">>],
                    args = [{user, binary}, {host, binary}, {os, binary}, {token, binary}],
                    result = {res, restuple}},
    #ejabberd_commands{name = unregister_push, tags = [accounts],
                    desc = "Unregister a user for push notifications",
                    policy = admin,
                    module = ?MODULE, function = unregister_push,
                    args_desc = ["Username", "Local vhost served by ejabberd"],
                    args_example = [<<"bob">>, <<"example.com">>],
                    args = [{user, binary}, {host, binary}],
                    result = {res, restuple}},

    #ejabberd_commands{name = registered_vhosts, tags = [server],
        desc = "List all registered vhosts in SERVER",
        module = ?MODULE, function = registered_vhosts,
        result_desc = "List of available vhosts",
        result_example = [<<"example.com">>, <<"anon.example.com">>],
        args = [],
        result = {vhosts, {list, {vhost, string}}}},
    #ejabberd_commands{name = reload_config, tags = [server, config],
        desc = "Reload config file in memory",
        module = ?MODULE, function = reload_config,
        args = [],
        result = {res, rescode}},

    #ejabberd_commands{name = join_cluster, tags = [cluster],
        desc = "Join this node into the cluster handled by Node",
        module = ?MODULE, function = join_cluster,
        args_desc = ["Nodename of the node to join"],
        args_example = [<<"ejabberd1@machine7">>],
        args = [{node, binary}],
        result = {res, rescode}},
    #ejabberd_commands{name = leave_cluster, tags = [cluster],
        desc = "Remove and shutdown Node from the running cluster",
        longdesc = "This command can be run from any running node of the cluster, "
        "even the node to be removed.",
        module = ?MODULE, function = leave_cluster,
        args_desc = ["Nodename of the node to kick from the cluster"],
        args_example = [<<"ejabberd1@machine8">>],
        args = [{node, binary}],
        result = {res, rescode}},

    #ejabberd_commands{name = list_cluster, tags = [cluster],
        desc = "List nodes that are part of the cluster handled by Node",
        module = ?MODULE, function = list_cluster,
        result_example = [ejabberd1@machine7, ejabberd1@machine8],
        args = [],
        result = {nodes, {list, {node, atom}}}},

    #ejabberd_commands{name = convert_to_scram, tags = [sql],
        desc = "Convert the passwords in 'users' ODBC table to SCRAM",
        module = ejabberd_auth_sql, function = convert_to_scram,
        args_desc = ["Vhost which users' passwords will be scrammed"],
        args_example = ["example.com"],
        args = [{host, binary}], result = {res, rescode}},

    #ejabberd_commands{name = import_prosody, tags = [mnesia, sql],
        desc = "Import data from Prosody",
        longdesc = "Note: this method requires ejabberd compiled with optional tools support "
            "and package must provide optional luerl dependency.",
        module = prosody2ejabberd, function = from_dir,
        args_desc = ["Full path to the Prosody data directory"],
        args_example = ["/var/lib/prosody/datadump/"],
        args = [{dir, string}], result = {res, rescode}},

    #ejabberd_commands{name = convert_to_yaml, tags = [config],
                    desc = "Convert the input file from Erlang to YAML format",
                    module = ?MODULE, function = convert_to_yaml,
        args_desc = ["Full path to the original configuration file", "And full path to final file"],
        args_example = ["/etc/ejabberd/ejabberd.cfg", "/etc/ejabberd/ejabberd.yml"],
                    args = [{in, string}, {out, string}],
                    result = {res, rescode}},
    #ejabberd_commands{name = dump_config, tags = [config],
        desc = "Dump configuration in YAML format as seen by ejabberd",
        module = ?MODULE, function = dump_config,
        args_desc = ["Full path to output file"],
        args_example = ["/tmp/ejabberd.yml"],
        args = [{out, string}],
        result = {res, rescode}},

    #ejabberd_commands{name = set_master, tags = [mnesia],
        desc = "Set master node of the clustered Mnesia tables",
        longdesc = "If you provide as nodename \"self\", this "
        "node will be set as its own master.",
        module = ?MODULE, function = set_master,
        args_desc = ["Name of the erlang node that will be considered master of this node"],
        args_example = ["ejabberd@machine7"],
        args = [{nodename, string}], result = {res, restuple}},
    #ejabberd_commands{name = mnesia_change_nodename, tags = [mnesia],
        desc = "Change the erlang node name in a backup file",
        module = ?MODULE, function = mnesia_change_nodename,
        args_desc = ["Name of the old erlang node", "Name of the new node",
                 "Path to old backup file", "Path to the new backup file"],
        args_example = ["ejabberd@machine1", "ejabberd@machine2",
                "/var/lib/ejabberd/old.backup", "/var/lib/ejabberd/new.backup"],
        args = [{oldnodename, string}, {newnodename, string},
            {oldbackup, string}, {newbackup, string}],
        result = {res, restuple}},
    #ejabberd_commands{name = backup, tags = [mnesia],
        desc = "Store the database to backup file",
        module = ?MODULE, function = backup_mnesia,
        args_desc = ["Full path for the destination backup file"],
        args_example = ["/var/lib/ejabberd/database.backup"],
        args = [{file, string}], result = {res, restuple}},
    #ejabberd_commands{name = restore, tags = [mnesia],
        desc = "Restore the database from backup file",
        module = ?MODULE, function = restore_mnesia,
        args_desc = ["Full path to the backup file"],
        args_example = ["/var/lib/ejabberd/database.backup"],
        args = [{file, string}], result = {res, restuple}},
    #ejabberd_commands{name = dump, tags = [mnesia],
        desc = "Dump the database to a text file",
        module = ?MODULE, function = dump_mnesia,
        args_desc = ["Full path for the text file"],
        args_example = ["/var/lib/ejabberd/database.txt"],
        args = [{file, string}], result = {res, restuple}},
    #ejabberd_commands{name = dump_table, tags = [mnesia],
        desc = "Dump a table to a text file",
        module = ?MODULE, function = dump_table,
        args_desc = ["Full path for the text file", "Table name"],
        args_example = ["/var/lib/ejabberd/table-muc-registered.txt", "muc_registered"],
        args = [{file, string}, {table, string}], result = {res, restuple}},
    #ejabberd_commands{name = load, tags = [mnesia],
        desc = "Restore the database from a text file",
        module = ?MODULE, function = load_mnesia,
        args_desc = ["Full path to the text file"],
        args_example = ["/var/lib/ejabberd/database.txt"],
        args = [{file, string}], result = {res, restuple}},
    #ejabberd_commands{name = mnesia_info, tags = [mnesia],
        desc = "Dump info on global Mnesia state",
        module = ?MODULE, function = mnesia_info,
        args = [], result = {res, string}},
    #ejabberd_commands{name = mnesia_table_info, tags = [mnesia],
        desc = "Dump info on Mnesia table state",
        module = ?MODULE, function = mnesia_table_info,
        args_desc = ["Mnesia table name"],
        args_example = ["roster"],
        args = [{table, string}], result = {res, string}},
    #ejabberd_commands{name = install_fallback, tags = [mnesia],
        desc = "Install the database from a fallback file",
        module = ?MODULE, function = install_fallback_mnesia,
        args_desc = ["Full path to the fallback file"],
        args_example = ["/var/lib/ejabberd/database.fallback"],
        args = [{file, string}], result = {res, restuple}},
    #ejabberd_commands{name = clear_cache, tags = [server],
        desc = "Clear database cache on all nodes",
        module = ?MODULE, function = clear_cache,
        args = [], result = {res, rescode}},
    #ejabberd_commands{name = add_uid_trace, tags = [server],
            desc = "Start tracing uid",
            module = ?MODULE, function = add_uid_trace,
            args_desc = ["Uid to be traced"],
            args_example = ["1000000000951769287"],
            args = [{uid, string}], result = {res, rescode}},
    #ejabberd_commands{name = remove_uid_trace, tags = [server],
            desc = "Stop tracing uid",
            module = ?MODULE, function = remove_uid_trace,
            args_desc = ["Uid to be traced"],
            args_example = ["1000000000951769287"],
            args = [{uid, string}], result = {res, rescode}}
    #ejabberd_commands{name = add_phone_trace, tags = [server],
            desc = "Start tracing phone",
            module = ?MODULE, function = add_phone_trace,
            args_desc = ["Phone to be traced"],
            args_example = ["12066585586"],
            args = [{phone, string}], result = {res, rescode}},
    #ejabberd_commands{name = remove_phone_trace, tags = [server],
            desc = "Stop tracing phone",
            module = ?MODULE, function = remove_phone_trace,
            args_desc = ["Phone to be traced"],
            args_example = ["12066585586"],
            args = [{phone, string}], result = {res, rescode}},
    #ejabberd_commands{name = fix_account_counters, tags = [server],
            desc = "Fix Redis counters",
            module = ?MODULE, function = fix_account_counters,
            args = [], result = {res, rescode}},
    #ejabberd_commands{name = uid_info, tags = [server],
        desc = "Get information associated with a user account",
        module = ?MODULE, function = uid_info,
        args_desc = ["Account UID"],
        args_example = [<<"1000000024384563984">>],
        args=[{uid, binary}], result = {res, rescode}},
    #ejabberd_commands{name = phone_info, tags = [server],
        desc = "Get information associated with a phone number",
        module = ?MODULE, function = phone_info,
        args_desc = ["Phone number"],
        args_example = [<<"12065555586">>],
        args=[{phone, binary}], result = {res, rescode}},
    #ejabberd_commands{name = group_info, tags = [server],
        desc = "Get information about a group",
        module = ?MODULE, function = group_info,
        args_desc = ["Group ID (gid)"],
        args_example = [<<"gmWxatkspbosFeZQmVoQ0f">>],
        args=[{gid, binary}], result = {res, rescode}},
    #ejabberd_commands{name = send_ios_push, tags = [server],
        desc = "Send an ios push",
        module = ?MODULE, function = send_ios_push,
        args_desc = ["Uid", "PushType", "Payload"],
        args_example = [<<"123">>, <<"alert">>, <<"GgMSAUg=">>],
        args=[{uid, binary}, {push_type, binary}, {payload, binary}],
        result = {res, rescode}},
    #ejabberd_commands{name = update_code_paths, tags = [server],
        desc = "update codepaths to the newly released folder.",
        module = ?MODULE, function = update_code_paths,
        args=[], result = {res, restuple}},
    #ejabberd_commands{name = list_changed_modules, tags = [server],
        desc = "list all changed modules",
        module = ?MODULE, function = list_changed_modules,
        args=[], result = {res, restuple}},
    #ejabberd_commands{name = hotload_modules, tags = [server],
        desc = "Hot code reload some modules",
        module = ?MODULE, function = hotload_modules,
        args=[{modules, modules_list}], result = {res, restuple}},
    #ejabberd_commands{name = hot_code_reload, tags = [server],
        desc = "Hot code reload a module",
        module = ?MODULE, function = hot_code_reload,
        args=[], result = {res, restuple}}
    ].


%% Use the h script to release.
%% Ex: h release --machine s-test --hotload
%% That command would release the latest code onto s-test and then call this function.
%% We first update all the code paths for all libraries and then we
%% look up the list of modified modules and purge any old code if present and load these new modules.
%% Please make sure that there are no errors when doing this hot code release.
%% We log if can't hotload a specific module.
%% If this does not work: we can release our old way using restart.
-spec hot_code_reload() -> ok.
hot_code_reload() ->
    update_code_paths(),
    {ok, ModifiedModules} = list_changed_modules(),
    hotload_modules(ModifiedModules),
    ok.


%% Use the h script to check changed_modules.
%% Ex: h release --machine s-test --list_changed_modules
%% That should list the modules updated after the release.
-spec list_changed_modules() -> {ok, [atom()]}.
list_changed_modules() ->
    ModifiedModules = code:modified_modules(),
    ?INFO("changed_modules: ~p", [lists:sort(ModifiedModules)]),
    io:format("changed_modules: ~p", [lists:sort(ModifiedModules)]),
    {ok, ModifiedModules}.


%% Use the h script to release.
%% Ex: h release --machine s-test --hotload_modules module1,module2,module3
%% This will then hotload all the modules.
-spec hotload_modules(ModifiedModules :: [atom()]) -> ok | {error, any()}.
hotload_modules(ModifiedModules) ->
    try
        lists:foldl(
            fun(Module, Acc) ->
                case code:soft_purge(Module) of
                    true -> [Module | Acc];
                    false ->
                        ?ERROR("Can't purge: ~p: there is a process using it", [Module]),
                        io:format("Can't purge: ~p: there is a process using it", [Module]),
                        error(failed_to_purge)
                end
            end, [], ModifiedModules),
        {ok, Prepared} = code:prepare_loading(ModifiedModules),
        ok = code:finish_loading(Prepared),
        ?INFO("Hotloaded following modules: ~p", [lists:sort(ModifiedModules)]),
        io:format("Hotloaded following modules: ~p", [lists:sort(ModifiedModules)])
    catch
        error: Reason ->
            io:format("Failed to hotload modules, reason: ~p", [Reason]),
            {error, Reason};
        Class: Reason: Stacktrace ->
            io:format("hotload_code error: ~s",
                    [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, Reason}
    end.


%% Use the h script to update code_paths.
%% This will load the new directories for all packages and remove any files that are no longer needed.
-spec update_code_paths() -> ok | {error, any()}.
update_code_paths() ->
    try
        %% List all libraries in the current directory.
        {ok, AllLibDirs} = file:list_dir(?CURRENT_LIB_PATH),

        %% Get all the new library names to be added.
        Libs = lists:map(
                fun(LibDir) ->
                    [Package| _] = string:split(LibDir, "-"),
                    Package
                end, AllLibDirs),

        %% check if we need to delete any filepaths from the new set of paths.
        Files = code:get_path(),
        DelFilePaths = lists:foldl(
            fun(FilePath, Acc) ->
                case util:to_binary(FilePath) of
                    <<?CURRENT_LIB_PATH, PackageExtBin>>  ->
                        PackageExt = util:to_list(PackageExtBin),
                        [Package | _] = string:split(PackageExt, <<"-">>),
                        case lists:member(Package, Libs) of
                            false -> [FilePath | Acc];
                            true -> Acc
                        end;
                    _ -> error(invalid_file)
                end
            end, [], Files),

        %% replace any existing paths if any for all libraries.
        %% if paths already exist: we replace them, else we add them newly.
        LoadedLibs = lists:foldl(
            fun(LibDir, Acc) ->
                [Package | _] = string:split(LibDir, <<"-">>),
                true = code:replace_path(Package, ?CURRENT_LIB_PATH ++ LibDir),
                [Package | Acc]
            end, [], AllLibDirs),

        ?INFO("Added file paths for these libraries: ~p", [LoadedLibs]),

        %% delete filepaths that are no longer needed.
        lists:foreach(fun code:del_path/1, DelFilePaths),
        ok
    catch
        error: Reason ->
            io:format("Failed to update paths, reason: ~p", [Reason]),
            {error, Reason};
        Class: Reason: Stacktrace ->
            io:format("update_code_paths error: ~s",
                    [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, Reason}
    end.


%%%
%%% Server management
%%%

status() ->
    {InternalStatus, ProvidedStatus} = init:get_status(),
    String1 = io_lib:format("The node ~p is ~p. Status: ~p",
            [node(), InternalStatus, ProvidedStatus]),
    {Is_running, String2} =
    case lists:keysearch(ejabberd, 1, application:which_applications()) of
        false ->
        {ejabberd_not_running, "ejabberd is not running in that node."};
        {value, {_, _, Version}} ->
        {ok, io_lib:format("ejabberd ~ts is running in that node", [Version])}
    end,
    {Is_running, String1 ++ String2}.

reopen_log() ->
    ejabberd_hooks:run(reopen_log_hook, []),
    ejabberd_logger:reopen_log().

rotate_log() ->
    ejabberd_hooks:run(rotate_log_hook, []),
    ejabberd_logger:rotate_log().

set_loglevel(LogLevel) ->
    ejabberd_logger:set(LogLevel).

%%%
%%% Stop Kindly
%%%

stop_kindly(DelaySeconds, AnnouncementTextString) ->
    Subject = (str:format("Server stop in ~p seconds!", [DelaySeconds])),
    WaitingDesc = (str:format("Waiting ~p seconds", [DelaySeconds])),
    AnnouncementText = list_to_binary(AnnouncementTextString),
    Steps = [
        {"Stopping ejabberd port listeners", ejabberd_listener, stop_listeners, []},
        {WaitingDesc, timer, sleep, [DelaySeconds * 1000]},
        {"Stopping ejabberd", application, stop, [ejabberd]},
        {"Stopping Mnesia", mnesia, stop, []},
        {"Stopping Erlang node", init, stop, []}
    ],
    NumberLast = length(Steps),
    TimestampStart = calendar:datetime_to_gregorian_seconds({date(), time()}),
    lists:foldl(
        fun({Desc, Mod, Func, Args}, NumberThis) ->
            SecondsDiff =
            calendar:datetime_to_gregorian_seconds({date(), time()})
            - TimestampStart,
            io:format("[~p/~p ~ps] ~ts... ",
            [NumberThis, NumberLast, SecondsDiff, Desc]),
            Result = (catch apply(Mod, Func, Args)),
            io:format("~p~n", [Result]),
            NumberThis+1
        end,
        1,
        Steps),
    ok.

%%%
%%% ejabberd_update
%%%

update_list() ->
    {ok, _Dir, UpdatedBeams, _Script, _LowLevelScript, _Check} =
    ejabberd_update:update_info(),
    [atom_to_list(Beam) || Beam <- UpdatedBeams].

update("all") ->
    [update_module(ModStr) || ModStr <- update_list()],
    {ok, []};
update(ModStr) ->
    update_module(ModStr).

update_module(ModuleNameBin) when is_binary(ModuleNameBin) ->
    update_module(binary_to_list(ModuleNameBin));
update_module(ModuleNameString) ->
    ModuleName = list_to_atom(ModuleNameString),
    case ejabberd_update:update([ModuleName]) of
    {ok, _Res} -> {ok, []};
    {error, Reason} -> {error, Reason}
    end.

%%%
%%% Account management
%%%

%% TODO(vipin): Remove after all clients use SPub.
check_and_register(Phone, Host, Password, Name, UserAgent) ->
    case is_my_host(Host) of
        true -> check_and_register(Phone, Host, Password, <<>>, Name, UserAgent);
        false -> {error, cannot_register, 10001, "Unknown virtual host"}
    end.

check_and_register_spub(Phone, Host, SPub, Name, UserAgent) ->
    case is_my_host(Host) of
        true -> check_and_register(Phone, Host, <<>>, SPub, Name, UserAgent);
        false -> {error, cannot_register, 10001, "Unknown virtual host"}
    end.


check_and_register(Phone, Host, Password, SPub, Name, UserAgent) ->
    Result = case Password of
      <<>> ->
          ?assert(byte_size(SPub) > 0),
          ejabberd_auth:check_and_register(Phone, Host, SPub, fun ejabberd_auth:set_spub/2,
                                           Name, UserAgent);
      _ ->
          ?assert(byte_size(Password) > 0),
          ejabberd_auth:check_and_register(Phone, Host, Password, fun ejabberd_auth:set_password/2,
                                           Name, UserAgent)
    end,
    case Result of
        {ok, Uid, login} ->
            ?INFO("Login into existing account uid:~p for phone:~p", [Uid, Phone]),
            {ok, Uid, login};
        {ok, Uid, register} ->
            ?INFO("Registering new account uid:~p for phone:~p", [Uid, Phone]),
            {ok, Uid, register};
        {error, Reason} ->
            ?INFO("Login/Registration for phone:~p failed. ~p", [Phone, Reason]),
            {error, Reason, 10001, "Login/Registration failed"}
    end.

register(User, Host, Password) ->
    case is_my_host(Host) of
    true ->
        case ejabberd_auth:try_register(User, Host, Password) of
        ok ->
            {ok, io_lib:format("User ~ts@~ts successfully registered", [User, Host])};
        {error, exists} ->
            Msg = io_lib:format("User ~ts@~ts already registered", [User, Host]),
            {error, conflict, 10090, Msg};
        {error, Reason} ->
            ErrReason = list_to_binary(io_lib:format(?T("error condition: ~p"), [Reason])),
            String = io_lib:format("Can't register user ~ts@~ts at node ~p: ~ts",
                       [User, Host, node(), ErrReason]),
            {error, cannot_register, 10001, String}
        end;
    false ->
        {error, cannot_register, 10001, "Unknown virtual host"}
    end.

unregister(User, Host) ->
    case is_my_host(Host) of
    true ->
        ejabberd_auth:remove_user(User, Host),
        {ok, ""};
    false ->
        {error, "Unknown virtual host"}
    end.

registered_users(Host) ->
    case is_my_host(Host) of
    true ->
        Users = ejabberd_auth:get_users(),
        SUsers = lists:sort(Users),
        lists:map(fun({U, _S}) -> U end, SUsers);
    false ->
        {error, "Unknown virtual host"}
    end.

enroll(User, Host, Passcode) ->
    case is_my_host(Host) of
        true ->
            case ejabberd_auth:try_enroll(User, Passcode) of
                {ok, _} ->
                    ?INFO("Phone ~s successfully enrolled", [User]),
                    {ok, io_lib:format("User ~ts@~ts successfully enrolled", [User, Host])};
                {error, Reason} ->
                    ?ERROR("Failed to enroll phone ~s, Reason: ~p", [User, Reason]),
                    ErrReason = list_to_binary(io_lib:format(?T("error condition: ~p"), [Reason])),
                    String = io_lib:format("Can't enroll user ~ts@~ts at node ~p: ~ts",
                                           [User, Host, node(), ErrReason]),
                    {error, cannot_enroll, 10001, String}
            end;
        false ->
            {error, cannot_enroll, 10001, "Unknown virtual host"}
    end.

unenroll(Phone, Host) ->
    case is_my_host(Host) of
        true ->
            ?INFO("phone:~s", [Phone]),
            ok = model_phone:delete_sms_code(Phone),
            {ok, ""};
        false ->
            {error, "Unknown virtual host"}
    end.

enrolled_users(Host) ->
    case is_my_host(Host) of
        true ->
            %% TODO(vipin): the following function is not defined.
            Users = ejabberd_auth_halloapp:get_enrolled_users(Host),
            SUsers = lists:sort(Users),
            lists:map(fun({U, _S}) -> U end, SUsers);
        false ->
            {error, "Unknown virtual host"}
    end.

get_user_passcode(Phone, Host) ->
    case is_my_host(Host) of
        true ->
            ?INFO("phone:~s", [Phone]),
            case model_phone:get_sms_code(Phone) of
                {ok, undefined} ->
                    Msg = io_lib:format("Phone ~ts does not have a code", [Phone]),
                    {error, conflict, 10090, Msg};
                {ok, Passcode} ->
                    {ok, Passcode};
                {error, _} ->
                    {error, "db-failure, unable to obtain passcode"}
            end;
        false ->
            {error, "Unknown virtual host"}
    end.

register_push(User, Host, Os, Token) ->
    case is_my_host(Host) of
        true ->
            case mod_push_tokens:register_push_info(User, Host, Os, Token) of
                {ok, _} ->
                    {ok, io_lib:format("User ~ts@~ts successfully registered for push notifications", [User, Host])};
                {error, Reason} ->
                    ErrReason = list_to_binary(io_lib:format(?T("error condition: ~p"), [Reason])),
                    String = io_lib:format("Can't register user ~ts@~ts at node ~p for push notifications: ~ts",
                                           [User, Host, node(), ErrReason]),
                    {error, cannot_register_push, 10001, String}
            end;
        false ->
            {error, cannot_register_push, 10001, "Unknown virtual host"}
    end.

unregister_push(User, Host) ->
    case is_my_host(Host) of
        true ->
            case mod_push_tokens:remove_push_token(User, Host) of
                ok ->
                    {ok, io_lib:format("User ~ts@~ts successfully unregistered for push notifications", [User, Host])};
                {error, Reason} ->
                    ErrReason = list_to_binary(io_lib:format(?T("error condition: ~p"), [Reason])),
                    String = io_lib:format("Can't unregister user ~ts@~ts at node ~p for push notifications: ~ts",
                                           [User, Host, node(), ErrReason]),
                    {error, cannot_unregister_push, 10001, String}
            end;
        false ->
            {error, cannot_unregister_push, 10001, "Unknown virtual host"}
    end.

registered_vhosts() ->
    ejabberd_option:hosts().

reload_config() ->
    case ejabberd_config:reload() of
    ok -> {ok, ""};
    Err ->
        Reason = ejabberd_config:format_error(Err),
        {invalid_config, Reason}
    end.

dump_config(Path) ->
    case ejabberd_config:dump(Path) of
    ok -> {ok, ""};
    Err ->
        Reason = ejabberd_config:format_error(Err),
        {invalid_file, Reason}
    end.

convert_to_yaml(In, Out) ->
    case ejabberd_config:convert_to_yaml(In, Out) of
    ok -> {ok, ""};
    Err ->
        Reason = ejabberd_config:format_error(Err),
        {invalid_config, Reason}
    end.

%%%
%%% Cluster management
%%%

join_cluster(NodeBin) ->
    ejabberd_cluster:join(list_to_atom(binary_to_list(NodeBin))).

leave_cluster(NodeBin) ->
    ejabberd_cluster:leave(list_to_atom(binary_to_list(NodeBin))).

list_cluster() ->
    ejabberd_cluster:get_nodes().

%%%
%%% Mnesia management
%%%

set_master("self") ->
    set_master(node());
set_master(NodeString) when is_list(NodeString) ->
    set_master(list_to_atom(NodeString));
set_master(Node) when is_atom(Node) ->
    case mnesia:set_master_nodes([Node]) of
        ok ->
        {ok, ""};
    {error, Reason} ->
        String = io_lib:format("Can't set master node ~p at node ~p:~n~p",
                   [Node, node(), Reason]),
        {error, String}
    end.

backup_mnesia(Path) when is_binary(Path) ->
    backup_mnesia(binary_to_list(Path));
backup_mnesia(Path) ->
    case mnesia:backup(Path) of
        ok ->
        {ok, ""};
    {error, Reason} ->
        String = io_lib:format("Can't store backup in ~p at node ~p: ~p",
                   [filename:absname(Path), node(), Reason]),
        {cannot_backup, String}
    end.

restore_mnesia(Path) ->
    case ejabberd_admin:restore(Path) of
    {atomic, _} ->
        {ok, ""};
    {aborted,{no_exists,Table}} ->
        String = io_lib:format("Can't restore backup from ~p at node ~p: Table ~p does not exist.",
                   [filename:absname(Path), node(), Table]),
        {table_not_exists, String};
    {aborted,enoent} ->
        String = io_lib:format("Can't restore backup from ~p at node ~p: File not found.",
                   [filename:absname(Path), node()]),
        {file_not_found, String}
    end.

%% Mnesia database restore
%% This function is called from ejabberd_ctl, ejabberd_web_admin and
%% mod_configure/adhoc
restore(Path) ->
    mnesia:restore(Path, [{keep_tables,keep_tables()},
              {default_op, skip_tables}]).

%% This function return a list of tables that should be kept from a previous
%% version backup.
%% Obsolete tables or tables created by module who are no longer used are not
%% restored and are ignored.
keep_tables() ->
    lists:flatten([acl, passwd, config,
           keep_modules_tables()]).

%% Returns the list of modules tables in use, according to the list of actually
%% loaded modules
keep_modules_tables() ->
    lists:map(fun(Module) -> module_tables(Module) end,
          gen_mod:loaded_modules(ejabberd_config:get_myname())).

%% TODO: This mapping should probably be moved to a callback function in each
%% module.
%% Mapping between modules and their tables
module_tables(mod_privacy) -> [privacy];
module_tables(mod_private) -> [private_storage];
module_tables(mod_pubsub) -> [pubsub_node];
module_tables(mod_roster) -> [roster];
module_tables(mod_shared_roster) -> [sr_group, sr_user];
module_tables(mod_vcard) -> [vcard, vcard_search];
module_tables(_Other) -> [].

get_local_tables() ->
    Tabs1 = lists:delete(schema, mnesia:system_info(local_tables)),
    Tabs = lists:filter(
         fun(T) ->
             case mnesia:table_info(T, storage_type) of
             disc_copies -> true;
             disc_only_copies -> true;
             _ -> false
             end
         end, Tabs1),
    Tabs.

dump_mnesia(Path) ->
    Tabs = get_local_tables(),
    dump_tables(Path, Tabs).

dump_table(Path, STable) ->
    Table = list_to_atom(STable),
    dump_tables(Path, [Table]).

dump_tables(Path, Tables) ->
    case dump_to_textfile(Path, Tables) of
    ok ->
        {ok, ""};
    {error, Reason} ->
            String = io_lib:format("Can't store dump in ~p at node ~p: ~p",
                   [filename:absname(Path), node(), Reason]),
        {cannot_dump, String}
    end.

dump_to_textfile(File) ->
    Tabs = get_local_tables(),
    dump_to_textfile(File, Tabs).

dump_to_textfile(File, Tabs) ->
    dump_to_textfile(mnesia:system_info(is_running), Tabs, file:open(File, [write])).
dump_to_textfile(yes, Tabs, {ok, F}) ->
    Defs = lists:map(
         fun(T) -> {T, [{record_name, mnesia:table_info(T, record_name)},
                {attributes, mnesia:table_info(T, attributes)}]}
         end,
         Tabs),
    io:format(F, "~p.~n", [{tables, Defs}]),
    lists:foreach(fun(T) -> dump_tab(F, T) end, Tabs),
    file:close(F);
dump_to_textfile(_, _, {ok, F}) ->
    file:close(F),
    {error, mnesia_not_running};
dump_to_textfile(_, _, {error, Reason}) ->
    {error, Reason}.

dump_tab(F, T) ->
    W = mnesia:table_info(T, wild_pattern),
    {atomic,All} = mnesia:transaction(
             fun() -> mnesia:match_object(T, W, read) end),
    lists:foreach(
      fun(Term) -> io:format(F,"~p.~n", [setelement(1, Term, T)]) end, All).

load_mnesia(Path) ->
    case mnesia:load_textfile(Path) of
        {atomic, ok} ->
            {ok, ""};
        {error, Reason} ->
            String = io_lib:format("Can't load dump in ~p at node ~p: ~p",
                   [filename:absname(Path), node(), Reason]),
        {cannot_load, String}
    end.

mnesia_info() ->
    lists:flatten(io_lib:format("~p", [mnesia:system_info(all)])).

mnesia_table_info(Table) ->
    ATable = list_to_atom(Table),
    lists:flatten(io_lib:format("~p", [mnesia:table_info(ATable, all)])).

install_fallback_mnesia(Path) ->
    case mnesia:install_fallback(Path) of
    ok ->
        {ok, ""};
    {error, Reason} ->
        String = io_lib:format("Can't install fallback from ~p at node ~p: ~p",
                   [filename:absname(Path), node(), Reason]),
        {cannot_fallback, String}
    end.

mnesia_change_nodename(FromString, ToString, Source, Target) ->
    From = list_to_atom(FromString),
    To = list_to_atom(ToString),
    Switch =
    fun
        (Node) when Node == From ->
        io:format("     - Replacing nodename: '~p' with: '~p'~n", [From, To]),
        To;
        (Node) when Node == To ->
        %% throw({error, already_exists});
        io:format("     - Node: '~p' will not be modified (it is already '~p')~n", [Node, To]),
        Node;
        (Node) ->
        io:format("     - Node: '~p' will not be modified (it is not '~p')~n", [Node, From]),
        Node
    end,
    Convert =
    fun
        ({schema, db_nodes, Nodes}, Acc) ->
        io:format(" +++ db_nodes ~p~n", [Nodes]),
        {[{schema, db_nodes, lists:map(Switch,Nodes)}], Acc};
        ({schema, version, Version}, Acc) ->
        io:format(" +++ version: ~p~n", [Version]),
        {[{schema, version, Version}], Acc};
        ({schema, cookie, Cookie}, Acc) ->
        io:format(" +++ cookie: ~p~n", [Cookie]),
        {[{schema, cookie, Cookie}], Acc};
        ({schema, Tab, CreateList}, Acc) ->
        io:format("~n * Checking table: '~p'~n", [Tab]),
        Keys = [ram_copies, disc_copies, disc_only_copies],
        OptSwitch =
            fun({Key, Val}) ->
                case lists:member(Key, Keys) of
                true ->
                    io:format("   + Checking key: '~p'~n", [Key]),
                    {Key, lists:map(Switch, Val)};
                false-> {Key, Val}
                end
            end,
        Res = {[{schema, Tab, lists:map(OptSwitch, CreateList)}], Acc},
        Res;
        (Other, Acc) ->
        {[Other], Acc}
    end,
    mnesia:traverse_backup(Source, Target, Convert, switched).

clear_cache() ->
    Nodes = ejabberd_cluster:get_nodes(),
    lists:foreach(fun(T) -> ets_cache:clear(T, Nodes) end, ets_cache:all()).

fix_account_counters() ->
    ?INFO("fixing account counters", []),
    model_accounts:fix_counters().

add_uid_trace(Uid) ->
    UidBin = list_to_binary(Uid),
    % TODO: check if it looks like uid
    ?INFO("Uid: ~s", [UidBin]),
    mod_trace:add_uid(UidBin),
    ok.

remove_uid_trace(Uid) ->
    UidBin = list_to_binary(Uid),
    % TODO: check if it looks like uid
    ?INFO("Uid: ~s", [UidBin]),
    mod_trace:remove_uid(UidBin),
    ok.

add_phone_trace(Phone) ->
    PhoneBin = list_to_binary(Phone),
    ?INFO("Phone: ~s", [PhoneBin]),
    mod_trace:add_phone(PhoneBin),
    ok.


remove_phone_trace(Phone) ->
    PhoneBin = list_to_binary(Phone),
    ?INFO("Phone: ~s", [PhoneBin]),
    mod_trace:remove_phone(PhoneBin),
    ok.


uid_info(Uid) ->
    case model_accounts:account_exists(Uid) of
        false -> io:format("There is no account associated with uid: ~s~n", [Uid]);
        true ->
            {ok, #account{phone = Phone, name = Name, signup_user_agent = UserAgent,
                creation_ts_ms = CreationTs, last_activity_ts_ms = LastActivityTs,
                activity_status = ActivityStatus} = Account} = model_accounts:get_account(Uid),
            {CreationDate, CreationTime} = util:ms_to_datetime_string(CreationTs),
            {LastActiveDate, LastActiveTime} = util:ms_to_datetime_string(LastActivityTs),
            ?INFO("Uid: ~s, Name: ~s, Phone: ~s~n", [Uid, Name, Phone]),
            io:format("Uid: ~s~nName: ~s~nPhone: ~s~n", [Uid, Name, Phone]),
            io:format("Account created on ~s at ~s ua: ~s~n",
                [CreationDate, CreationTime, UserAgent]),
            io:format("Last activity on ~s at ~s and current status is ~s~n",
                [LastActiveDate, LastActiveTime, ActivityStatus]),
            io:format("Current Version: ~s~n", [Account#account.client_version]),

            {ok, Friends} = model_friends:get_friends(Uid),
            io:format("Friend list (~p):~n", [length(Friends)]),
            FNameMap = model_accounts:get_names(Friends),
            [io:format("  ~s (~s)~n", [FName, FUid]) ||
                {FUid, FName} <- maps:to_list(FNameMap), FName =/= <<>>],

            Gids = model_groups:get_groups(Uid),
            io:format("Group list (~p):~n", [length(Gids)]),
            [io:format(
                "  ~s (~s)~n",
                [(model_groups:get_group_info(Gid))#group_info.name, Gid])
                || Gid <- Gids]
    end,
    ok.


phone_info(Phone) ->
    case model_phone:get_uid(Phone) of
        {ok, undefined} ->
            io:format("No account associated with phone: ~s~n", [Phone]),
            invite_info(Phone);
        {ok, Uid} -> uid_info(Uid)
    end,
    ok.


invite_info(Phone) ->
    case model_invites:is_invited(Phone) of
        false -> io:format("This phone number has not been invited~n");
        true ->
            {ok, Uid, Ts} = model_invites:get_inviter(Phone),
            {Day, Time} = util:ms_to_datetime_string(binary_to_integer(Ts) * ?SECONDS_MS),
            {ok, Name} = model_accounts:get_name(Uid),
            io:format("~s was invited by ~s (~s) on ~s at ~s.~n",
                [Phone, Name, Uid, Day, Time])
    end,
    ok.


group_info(Gid) ->
    case model_groups:group_exists(Gid) of
        false -> io:format("No group associated with gid: ~s~n", [Gid]);
        true ->
            Group = model_groups:get_group(Gid),
            GName = Group#group.name,
            Members = [{Uid, Type, util:ms_to_datetime_string(Ts),
                model_accounts:get_name_binary(Uid)}
                || #group_member{uid = Uid, type = Type, joined_ts_ms = Ts} <- Group#group.members],
            {CreateDate, CreateTime} = util:ms_to_datetime_string(Group#group.creation_ts_ms),
            io:format("~s (~s), created on ~s at ~s:~n", [GName, Gid, CreateDate, CreateTime]),
            [io:format("    ~s (~s) | ~s | joined on ~s at ~s~n", [Name, Uid, Type, Date, Time])
                || {Uid, Type, {Date, Time}, Name} <- Members]
    end,
    ok.


%% TODO(murali@): add support for android as well.
send_ios_push(Uid, PushType, Payload) ->
    Server = util:get_host(),
    case ejabberd_auth:user_exists(Uid) of
        false ->
            io:format("Invalid uid: ~s", [Uid]);
        true ->
            PushInfo = mod_push_tokens:get_push_info(Uid, Server),
            if
                PushInfo#push_info.token =:= undefined ->
                    io:format("Invalid push token: ~s", [Uid]);
                PushInfo#push_info.os =:= <<"ios">> ->
                    io:format("Cannot send push to non_dev users: ~s", [Uid]);
                true ->
                    case mod_ios_push:send_dev_push(Uid, PushInfo, PushType, Payload) of
                        ok ->
                            io:format("Uid: ~s, successfully sent a push", [Uid]);
                        {error, Reason} ->
                            io:format("Uid: ~s, failed sending a push: ~p", [Uid, Reason])
                    end
            end
    end.


-spec is_my_host(binary()) -> boolean().
is_my_host(Host) ->
    try ejabberd_router:is_my_host(Host)
    catch _:{invalid_domain, _} -> false
    end.

