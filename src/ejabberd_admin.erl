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

-export([
    start_link/0,
    %% Server
    status/0,
    reopen_log/0,
    rotate_log/0,
    stop_kindly/2,
    reload_config/0,
    dump_config/1,
    convert_to_yaml/2,
    %% Cluster
    leave_cluster/1,
    %% Erlang
    update_list/0,
    update/1,
    clear_cache/0,
    %% HalloApp functions
    add_uid_trace/1,
    remove_uid_trace/1,
    add_phone_trace/1,
    remove_phone_trace/1,
    uid_info/1,
    uid_info_short/1,
    uid_info_with_all_contacts/1,
    phone_info/2,
    phone_info_short/2,
    phone_info_with_all_contacts/2,
    username_info/1,
    username_info_short/1,
    group_info/1,
    session_info/1,
    spub_info/1,
    get_sms_codes/1,
    send_moment_notification/7,
    send_invite/2,
    reset_sms_backoff/1,
    delete_account/1,
    send_ios_push/3,
    update_code_paths/0,
    list_changed_modules/0,
    hotload_modules/1,
    hot_code_reload/0,
    get_commands_spec/0,
    hotswap_modules/0,
    get_full_sync_error_percent/0,
    get_full_sync_retry_time/0,
    request_phone_logs/1,
    request_uid_logs/1,
    reload_modules/1,
    friend_recos/1,
    get_moment_notif_time/1
]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("logger.hrl").
-include("account.hrl").
-include("feed.hrl").
-include("groups.hrl").
-include("prompts.hrl").
-include("time.hrl").
-include("translate.hrl").
-include("ejabberd_commands.hrl").
-include("sms.hrl").
-include("ejabberd_sm.hrl").

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
    #ejabberd_commands{name = stop, tags = [server],
        desc = "Stop ejabberd gracefully",
        module = init, function = stop,
        args = [], result = {res, rescode}},
    #ejabberd_commands{name = restart, tags = [server],
        desc = "Restart ejabberd gracefully",
        module = init, function = restart,
        args = [], result = {res, rescode}},
    #ejabberd_commands{name = reset_auth_service, tags = [server],
        desc = "Reset auth service: Server will start sending auth failures to clients again",
        module = mod_auth_monitor, function = reset_auth_service,
        args = [], result = {res, restuple}},
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
        module = ejabberd_logger, function = set,
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
    #ejabberd_commands{name = reload_config, tags = [server, config],
        desc = "Reload config file in memory",
        module = ?MODULE, function = reload_config,
        args = [],
        result = {res, rescode}},
    #ejabberd_commands{name = join_cluster, tags = [cluster],
        desc = "Join the ejabberd cluster (using Redis)",
        module = ejabberd_cluster, function = join,
        args = [],
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
        module = ejabberd_cluster, function = get_nodes,
        result_example = [ejabberd1@machine7, ejabberd1@machine8],
        args = [],
        result = {nodes, {list, {node, atom}}}},
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
    #ejabberd_commands{name = username_info, tags = [server],
        desc = "Get information associated with a username",
        module = ?MODULE, function = username_info,
        args_desc = ["Username"],
        args_example = [<<"my_username">>],
        args=[{username, binary}], result = {res, rescode}},
    #ejabberd_commands{name = username_info_short, tags = [server],
        desc = "Get information associated with a username",
        module = ?MODULE, function = username_info_short,
        args_desc = ["Username"],
        args_example = [<<"my_username">>],
        args=[{username, binary}], result = {res, rescode}},
    #ejabberd_commands{name = uid_info, tags = [server],
        desc = "Get information associated with a user account",
        module = ?MODULE, function = uid_info,
        args_desc = ["Account UID"],
        args_example = [<<"1000000024384563984">>],
        args=[{uid, binary}], result = {res, rescode}},
    #ejabberd_commands{name = uid_info_short, tags = [server],
        desc = "Get information associated with a user account",
        module = ?MODULE, function = uid_info_short,
        args_desc = ["Account UID"],
        args_example = [<<"1000000024384563984">>],
        args=[{uid, binary}], result = {res, rescode}},
    #ejabberd_commands{name = uid_info_with_all_contacts, tags = [server],
        desc = "Get information associated with a user account",
        module = ?MODULE, function = uid_info_with_all_contacts,
        args_desc = ["Account UID"],
        args_example = [<<"1000000024384563984">>],
        args=[{uid, binary}], result = {res, rescode}},
    #ejabberd_commands{name = phone_info, tags = [server],
        desc = "Get information associated with a phone number",
        module = ?MODULE, function = phone_info,
        args_desc = ["Phone number", "AppType"],
        args_example = [<<"12065555586">>, halloapp],
        args=[{phone, binary}, {app_type, string}], result = {res, rescode}},
    #ejabberd_commands{name = phone_info_short, tags = [server],
        desc = "Get information associated with a phone number",
        module = ?MODULE, function = phone_info_short,
        args_desc = ["Phone number", "AppType"],
        args_example = [<<"12065555586">>, halloapp],
        args=[{phone, binary}, {app_type, string}], result = {res, rescode}},
    #ejabberd_commands{name = phone_info_with_all_contacts, tags = [server],
        desc = "Get information associated with a phone number",
        module = ?MODULE, function = phone_info_with_all_contacts,
        args_desc = ["Phone number", "AppType"],
        args_example = [<<"12065555586">>, halloapp],
        args=[{phone, binary}, {app_type, string}], result = {res, rescode}},
    #ejabberd_commands{name = get_moment_notif_time, tags = [server],
        desc = "Get the moment notification time for a particular date",
        module = ?MODULE, function = get_moment_notif_time,
        args_desc = ["Date", "20"],
        args_example = [20],
        args=[{date, integer}], result = {res, rescode}},
    #ejabberd_commands{name = send_invite, tags = [server],
        desc = "Send an invite",
        module = ?MODULE, function = send_invite,
        args_desc = ["Uid of inviter", "Phone number of invitee"],
        args_example = [<<"1000000000121550191">>, <<"12065555586">>],
        args=[{uid, binary}, {phone, binary}], result = {res, rescode}},
    #ejabberd_commands{name = group_info, tags = [server],
        desc = "Get information about a group",
        module = ?MODULE, function = group_info,
        args_desc = ["Group ID (gid)"],
        args_example = [<<"gmWxatkspbosFeZQmVoQ0f">>],
        args=[{gid, binary}], result = {res, rescode}},
    #ejabberd_commands{name = session_info, tags = [server],
        desc = "Get information associated with a user's session",
        module = ?MODULE, function = session_info,
        args_desc = ["Account UID"],
        args_example = [<<"1000000024384563984">>],
        args=[{uid, binary}], result = {res, rescode}},
    #ejabberd_commands{name = spub_info, tags = [server],
        desc = "Get uid(s) associated with a noise registration key or a noise reg key prefix",
        module = ?MODULE, function = spub_info,
        args_desc = ["Static key or static key prefix"],
        args_example = [<<"Q+v8tggW+WDPMmBN9vPoBvyDl5V4vd3o5FG0v7/qH+1=">>],
        args=[{key, binary}], result = {res, rescode}},
    #ejabberd_commands{name = get_sms_codes, tags = [server],
        desc = "Get SMS registration code for phone number",
        module = ?MODULE, function = get_sms_codes,
        args_desc = ["Phone number"],
        args_example = [<<"12065555586">>],
        args=[{phone, binary}], result = {res, rescode}},
    #ejabberd_commands{name = send_ios_push, tags = [server],
        desc = "Send an ios push",
        module = ?MODULE, function = send_ios_push,
        args_desc = ["Uid", "PushType", "Payload"],
        args_example = [<<"123">>, <<"alert">>, <<"GgMSAUg=">>],
        args=[{uid, binary}, {push_type, binary}, {payload, binary}],
        result = {res, rescode}},
    #ejabberd_commands{name = request_phone_logs, tags = [server],
        desc = "Send request_logs notification",
        module = ?MODULE, function = request_phone_logs,
        args_desc = ["Phone"],
        args_example = [<<"14703381473">>],
        args=[{phone, binary}], result = {res, rescode}},
    #ejabberd_commands{name = request_uid_logs, tags = [server],
        desc = "Send request_logs notification",
        module = ?MODULE, function = request_uid_logs,
        args_desc = ["Uid"],
        args_example = [<<"1000000024384563984">>],
        args=[{uid, binary}], result = {res, rescode}},
    #ejabberd_commands{name = reset_sms_backoff, tags = [server],
        desc = "Delete the SMS gateway history for a phone number",
        module = ?MODULE, function = reset_sms_backoff,
        args_desc = ["Phone number"],
        args_example = [<<"12065555586">>],
        args=[{phone, binary}], result = {res, rescode}},
    #ejabberd_commands{name = delete_account, tags = [server],
        desc = "Delete an account",
        module = ?MODULE, function = delete_account,
        args_desc = ["Uid"],
        args_example = [<<"1000000000121550191">>],
        args=[{uid, binary}], result = {res, rescode}},
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
        args=[{modules, modules_list}], result = {res, rescode}},
    #ejabberd_commands{name = reload_modules, tags = [server],
        desc = "Restart some modules",
        module = ?MODULE, function = reload_modules,
        args=[{modules, modules_list}], result = {res, rescode}},
    #ejabberd_commands{name = hot_code_reload, tags = [server],
        desc = "Hot code reload a module",
        module = ?MODULE, function = hot_code_reload,
        args=[], result = {res, restuple}},
    #ejabberd_commands{name = friend_recos, tags = [server],
        desc = "Get friend recommendations associated with a user account",
        module = ?MODULE, function = friend_recos,
        args_desc = ["Account UID"],
        args_example = [<<"1000000024384563984">>],
        args=[{uid, binary}], result = {res, rescode}},
     #ejabberd_commands{name = set_full_sync_error_percent, tags = [server],
        desc = "Sets the full sync error percentage, >= 0 and =< 100 ",
        module = mod_contacts, function = set_full_sync_error_percent,
        args_desc = ["Percentage"],
        args_example = [50],
        args=[{percent, integer}],
        result = {res, rescode}},
    #ejabberd_commands{name = set_full_sync_retry_time, tags = [server],
        desc = "Sets the full sync retry_time - default is 1 day",
        module = mod_contacts, function = set_full_sync_retry_time,
        args_desc = ["Time"],
        args_example = [86400],
        args=[{retry_time, integer}],
        result = {res, rescode}},
    #ejabberd_commands{name = get_full_sync_error_percent, tags = [server],
        desc = "Sets the full sync error percentage, >= 0 and =< 100 ",
        module = ?MODULE, function = get_full_sync_error_percent,
        result = {res, rescode}},
    #ejabberd_commands{name = get_full_sync_retry_time, tags = [server],
        desc = "Sets the full sync retry_time - default is 1 day",
        module = ?MODULE, function = get_full_sync_retry_time,
        result = {res, rescode}},
    #ejabberd_commands{name = fetch_push_stats, tags = [server],
        desc = "Fetches push stats for android",
        module = android_push_stats, function = fetch_push_stats,
        result = {res, rescode}},
    #ejabberd_commands{name = send_moment_notification, tags = [server],
        desc = "Send Moment Notification",
        module = ?MODULE, function = send_moment_notification,
        %% PhoneOrUid, Timestamp, Id, Type, Prompt, HideBanner
        args_desc = ["Phone number or Uid", "Date", "Timestamp", "NotificationId", "NotificationType", "Prompt", "HideBanner"],
        args_example = [<<"12065555586">>, <<"19/02/2023">>, 1677115217, 1677115000, <<"live_camera">>, <<"WYD?">>, <<"false">>],
        args=[{phone_or_uid, binary}, {date, binary}, {timestamp, integer}, {id, integer}, {type, binary}, {prompt, binary}, {hide_banner, binary}],
        result = {res, rescode}},
     #ejabberd_commands{name = get_invite_string, tags = [server],
        desc = "Get invite string from its hash ID",
        module = mod_invites, function = lookup_invite_string,
        args_desc = ["Invite string hash ID"],
        args = [{hash_id, binary}],
        result = {res, rescode}}
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
%% Ex: h release --machine s-test --list-changed-modules
%% That should list the modules updated after the release.
-spec list_changed_modules() -> {ok, [atom()]}.
list_changed_modules() ->
    ModifiedModules = code:modified_modules(),
    ?INFO("changed_modules: ~p", [lists:sort(ModifiedModules)]),
    io:format("changed_modules: ~p~n", [lists:sort(ModifiedModules)]),
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
                        io:format("Can't purge: ~p: there is a process using it~n", [Module]),
                        error(failed_to_purge)
                end
            end, [], ModifiedModules),
        {ok, Prepared} = code:prepare_loading(ModifiedModules),
        ok = code:finish_loading(Prepared),
        ?INFO("Hotloaded following modules: ~p", [lists:sort(ModifiedModules)]),
        io:format("Hotloaded following modules: ~p~n", [lists:sort(ModifiedModules)])
    catch
        Class: Reason: Stacktrace ->
            io:format("hotload_code error: ~s~n",
                    [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, Reason}
    end.


-spec reload_modules(ModulesList :: [atom()]) -> ok | {error, any()}.
reload_modules(ModulesList) ->
    Host = util:get_host(),
    ?DEBUG("restart modules: ~p", [ModulesList]),
    lists:foreach(
        fun(Module) ->
            case erlang:function_exported(Module, reload, 3) of
                true ->
                    ?INFO("Reloading ~p", [Module]),
                    try case Module:reload(Host, #{}, #{}) of
                        ok -> ok;
                        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
                        Err -> 
                            ?ERROR("Module: ~p reload returned error: ~p", [Module, Err]),
                            {error, {Module, Err}}
                    end
                    catch
                        Class: Reason: Stacktrace ->
                            io:format("reload module error: ~s~n",
                                    [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
                            {error, Reason}
                    end;
                false ->
                    ?WARNING("Module ~p doesn't support reloading", [Module])
            end
        end, ModulesList).

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
                true = code:replace_path(util:to_atom(Package), ?CURRENT_LIB_PATH ++ LibDir),
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
    String3 = io_lib:format("Hotswap modules: ~s", [string:join(hotswap_modules(), " ")]),
    {Is_running, String1 ++ String2 ++ String3}.

hotswap_modules() ->
    case file:list_dir("/home/ha/pkg/ejabberd/current/lib/zzz_hotswap/ebin/") of
        {error, _Reason} -> [];
        {ok, ModulesFiles} ->
            Modules = [lists:nth(1, string:split(M, ".beam")) || M <- ModulesFiles],
            lists:sort(Modules)
    end.

reopen_log() ->
    ejabberd_hooks:run(reopen_log_hook, []),
    ejabberd_logger:reopen_log().

rotate_log() ->
    ejabberd_hooks:run(rotate_log_hook, []),
    ejabberd_logger:rotate_log().


%%%
%%% Stop Kindly
%%%

stop_kindly(DelaySeconds, _AnnouncementTextString) ->
    _Subject = (str:format("Server stop in ~p seconds!", [DelaySeconds])),
    WaitingDesc = (str:format("Waiting ~p seconds", [DelaySeconds])),
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

convert_to_yaml(_In, _Out) -> {invalid_config, not_yml}.

%%%
%%% Cluster management
%%%

leave_cluster(NodeBin) ->
    ejabberd_cluster:leave(list_to_atom(binary_to_list(NodeBin))).

clear_cache() ->
    Nodes = ejabberd_cluster:get_nodes(),
    lists:foreach(fun(T) -> ets_cache:clear(T, Nodes) end, ets_cache:all()).

%%%
%%% HalloApp functions
%%%

add_uid_trace(Uid) ->
    UidBin = list_to_binary(Uid),
    case util_uid:looks_like_uid(UidBin) of
        true ->
            ?INFO("Uid: ~s", [UidBin]),
            mod_trace:add_uid(UidBin);
        false ->
            ?INFO("Not tracing Uid: ~s -- doesn't look like Uid", [UidBin])
    end,
    ok.

remove_uid_trace(Uid) ->
    UidBin = list_to_binary(Uid),
    case util_uid:looks_like_uid(UidBin) of
        true ->
            ?INFO("Uid: ~s", [UidBin]),
            mod_trace:remove_uid(UidBin);
        false ->
            ?INFO("Can't remove Uid: ~s -- doesn't look like Uid", [UidBin])
    end,
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

format_contact_list(Uid) ->
    AppType = util_uid:get_app_type(Uid),
    {ok, ContactPhones} = model_contacts:get_contacts(Uid),
    {ok, Friends} = model_friends:get_friends(Uid),
    PhoneToUidMap = model_phone:get_uids(ContactPhones, AppType),
    UidToNameMap = model_accounts:get_names(maps:values(PhoneToUidMap)),
    {PhoneToNumFriendsMap, PhoneToCreationDateMap, PhoneToLastActiveDateMap} = maps:fold(
        fun(K, V, {Acc1, Acc2, Acc3}) ->
            {ok, Friends2} = model_friends:get_friends(V),
            NewAcc1 = maps:put(K, length(Friends2), Acc1),
            {ok, #account{creation_ts_ms = CreationTs, last_activity_ts_ms = LastActivityTs}} =
                model_accounts:get_account(V),
            {CreationDate, _CreationTime} = util:ms_to_datetime_string(CreationTs),
            {LastActiveDate, _LastActiveTime} = util:ms_to_datetime_string(LastActivityTs),
            NewAcc2 = maps:put(K, CreationDate, Acc2),
            NewAcc3 = maps:put(K, LastActiveDate, Acc3),
            {NewAcc1, NewAcc2, NewAcc3}
        end, {#{}, #{}, #{}}, PhoneToUidMap),
    PhoneToNameMap = maps:map(fun(_P, U) -> maps:get(U, UidToNameMap) end, PhoneToUidMap),
    ContactList = [{
        case maps:get(CPhone, PhoneToUidMap, undefined) of      % Friend or Contact
            undefined -> "C";
            FUid ->
                case lists:member(FUid, Friends) of
                    true -> "F";
                    false -> "C"
                end
        end,
        binary_to_integer(CPhone),                              % Phone,
        maps:get(CPhone, PhoneToUidMap, ""),                    % Uid,
        maps:get(CPhone, PhoneToNameMap, ""),                   % Name
        maps:get(CPhone, PhoneToNumFriendsMap, 0),              % Num Friends
        maps:get(CPhone, PhoneToCreationDateMap, ""),           % Creation Date
        maps:get(CPhone, PhoneToLastActiveDateMap, "")          % Last Active Date
    } || CPhone <- ContactPhones],
    NumFriends = length([1 || {CorF, _P, U, _N, _NF, _CD, _LAD} <- ContactList, CorF =:= "F" andalso U =/= Uid]),
    {ok, ContactList, NumFriends}.


uid_info_with_all_contacts(Uid) ->
    uid_info(Uid, [show_all_contacts]).

uid_info_short(Uid) ->
    uid_info(Uid, [short]).

uid_info(Uid) ->
    uid_info(Uid, []).

uid_info(Uid, Options) ->
    ?INFO("Admin requesting account info for uid: ~s", [Uid]),
    case model_accounts:account_exists(Uid) of
        false ->
            case model_accounts:get_deleted_account(Uid) of
                {error, not_deleted} ->
                    io:format("There is no account associated with uid: ~s~n", [Uid]);
                {DeleteTimeMS, Acc} ->
                    {CreationDate, CreationTime} =
                        util:ms_to_datetime_string(Acc#account.creation_ts_ms),
                    {LastRegDate, LastRegTime} =
                        util:ms_to_datetime_string(Acc#account.last_registration_ts_ms),
                    {LastActiveDate, LastActiveTime} =
                        util:ms_to_datetime_string(Acc#account.last_activity_ts_ms),
                    {DeletetionDate, DeletionTime} =
                        util:ms_to_datetime_string(DeleteTimeMS),
                    io:format("Deleted uid: ~s~n", [Uid]),
                    io:format("Account created on ~s at ~s ua: ~s~n",
                        [CreationDate, CreationTime, Acc#account.signup_user_agent]),
                    io:format("Last registration on ~s at ~s~n", [LastRegDate, LastRegTime]),
                    io:format("Last activity on ~s at ~s and current status is ~s~n",
                        [LastActiveDate, LastActiveTime, Acc#account.activity_status]),
                    io:format("Deleted on ~s at ~s~n", [DeletetionDate, DeletionTime]),
                    io:format("Campaign ID: ~s~n", [Acc#account.campaign_id]),
                    io:format("Device: ~s, OS version: ~s, Client version: ~s~n",
                        [Acc#account.device, Acc#account.os_version, Acc#account.client_version])
            end;
        true ->
            case util_uid:get_app_type(Uid) of
                ?KATCHUP -> uid_info_katchup(Uid, Options);
                ?HALLOAPP -> uid_info_halloapp(Uid, Options);
                _ -> io:format("Uid cannot be resolved to an AppType: ~p", [Uid])
            end
    end.

uid_info_halloapp(Uid, Options) ->
    {ok, #account{phone = Phone, name = Name, signup_user_agent = UserAgent,
        creation_ts_ms = CreationTs, last_activity_ts_ms = LastActivityTs,
        activity_status = ActivityStatus} = Account} = model_accounts:get_account(Uid),
    LastConnectionTime = model_accounts:get_last_connection_time(Uid),
    {CreationDate, CreationTime} = util:ms_to_datetime_string(CreationTs),
    {LastActiveDate, LastActiveTime} = util:ms_to_datetime_string(LastActivityTs),
    {LastConnDate, LastConnTime} = util:ms_to_datetime_string(LastConnectionTime),
    ?INFO("Uid: ~s, Name: ~s, Phone: ~s~n", [Uid, Name, Phone]),
    io:format("Uid: ~s~nName: ~s~nPhone: ~s~n", [Uid, Name, Phone]),
    io:format("Account created on ~s at ~s ua: ~s~n",
        [CreationDate, CreationTime, UserAgent]),
    io:format("Last activity on ~s at ~s and current status is ~s~n",
        [LastActiveDate, LastActiveTime, ActivityStatus]),
    io:format("Last connection on ~s at ~s~n", [LastConnDate, LastConnTime]),
    io:format("Current Version: ~s Lang: ~s~n", [Account#account.client_version, Account#account.lang_id]),

    print_push_token_info(Uid),

    Tags = model_accounts:get_all_geo_tags(Uid),
    io:format("GeoTags: ~p~n", [Tags]),

    case lists:member(short, Options) of
        true -> ok;
        false ->
            {ok, ContactList, NumFriends} = format_contact_list(Uid),
            ContactList2 = case lists:member(show_all_contacts, Options) of
                true -> ContactList;
                false -> lists:filter(fun({_, _, AUid, _, _, _, _}) -> AUid =/= "" andalso AUid =/= Uid end, ContactList)
            end,
            io:format("Contact list (~p, ~p are friends):~n",
                [length(ContactList2), NumFriends]),
            [io:format("  ~s ~w ~s ~p ~s ~s ~s ~n",
                [CorF, CPhone, FUid, FNumFriends, FCDate, FLADate, FName]) ||
                {CorF, CPhone, FUid, FName, FNumFriends, FCDate, FLADate} <- ContactList2],

            Gids = model_groups:get_groups(Uid),
            GidMaxSize = case Gids of
                [] -> 0;
                _ -> lists:max(maps:values(model_groups:get_group_size(Gids)))
            end,
            io:format("Group list (~p, max membership: ~p):~n", [length(Gids), GidMaxSize]),
            lists:foreach(
                fun(Gid) ->
                    {GName, GSize} = case (model_groups:get_group_info(Gid)) of
                        #group_info{} = G -> {G#group_info.name, model_groups:get_group_size(Gid)};
                        _  -> {undefined, undefined}
                        end,
                    io:format("   ~s ~p (~s)~n", [GName, GSize, Gid])
                end,
                Gids)
    end,
    ok.


uid_info_katchup(Uid, Options) ->
    {ok, #account{phone = Phone, name = Name, signup_user_agent = UserAgent,
        creation_ts_ms = CreationTs, last_activity_ts_ms = LastActivityTs,
        activity_status = ActivityStatus, zone_offset = ZoneOffset,
        username = Username} = Account} = model_accounts:get_account(Uid),
    LastConnectionTime = model_accounts:get_last_connection_time(Uid),
    {CreationDate, CreationTime} = util:ms_to_datetime_string(CreationTs),
    {LastActiveDate, LastActiveTime} = util:ms_to_datetime_string(LastActivityTs),
    {LastConnDate, LastConnTime} = util:ms_to_datetime_string(LastConnectionTime),
    ?INFO("Uid: ~s, Name: ~s, Phone: ~s, Username: ~s~n", [Uid, Name, Phone, Username]),
    io:format("Uid: ~s~nUsername: ~s~nName: ~s~nPhone: ~s~n", [Uid, Username, Name, Phone]),
    io:format("Account created on ~s at ~s ua: ~s~n",
        [CreationDate, CreationTime, UserAgent]),
    io:format("Last activity on ~s at ~s and current status is ~s~n",
        [LastActiveDate, LastActiveTime, ActivityStatus]),
    io:format("Last connection on ~s at ~s~n", [LastConnDate, LastConnTime]),
    io:format("Current Version: ~s Lang: ~s~n", [Account#account.client_version, Account#account.lang_id]),

    print_push_token_info(Uid),

    Tags = model_accounts:get_all_geo_tags(Uid),
    io:format("ZoneOffset = ~p GeoTags: ~p~n", [ZoneOffset, Tags]),

    ContactsPerms = model_accounts:is_permission_enabled(Uid, contacts),
    LocationPerms = model_accounts:is_permission_enabled(Uid, location),
    NotificationsPerms = model_accounts:is_permission_enabled(Uid, notifications),

    io:format("Permissions: contacts = ~p, location = ~p, notifications = ~p~n",
        [ContactsPerms, LocationPerms, NotificationsPerms]),

    Bio = model_accounts:get_bio(Uid),
    LinksMap = model_accounts:get_links(Uid),
    io:format("Bio: ~p~n", [Bio]),
    LinksStr = maps:fold(
        fun(LinkType, Link, AccStr) ->
            AccStr ++ "{" ++ util:to_list(LinkType) ++ ", " ++ util:to_list(Link) ++ "}"
        end,
        "Links:",
        LinksMap) ++ "~n",
    io:format("~p", [LinksStr]),

    case lists:member(short, Options) of
        true -> ok;
        false ->
            {ok, ContactsList} = model_contacts:get_contacts(Uid),
            Contacts = sets:from_list(ContactsList),
            Followers = sets:from_list(model_follow:get_all_followers(Uid)),
            Following = sets:from_list(model_follow:get_all_following(Uid)),
            ConnectedContacts = sets:union(sets:intersection(Contacts, Followers), sets:intersection(Contacts, Following)),
            Mutual = sets:intersection(Following, Followers),
            List = case lists:member(show_all_contacts, Options) of
                true -> sets:union([Contacts, Following, Followers]);
                false -> sets:union(Following, Followers)
            end,
            io:format("Relationship List: ~p followers, ~p following, ~p mutual, ~p contacts, ~p contacts following/follower~n",
                [sets:size(Followers), sets:size(Following), sets:size(Mutual), sets:size(Contacts), sets:size(ConnectedContacts)]),
            lists:foreach(
                fun(Buid) ->
                    IsContact = sets:is_element(Buid, Contacts),
                    IsFollower = sets:is_element(Buid, Followers),
                    IsFollowing = sets:is_element(Buid, Following),
                    FollowStatus = case {IsFollower, IsFollowing} of
                        {true, true} -> "mutual";
                        {true, false} -> "follower";
                        {false, true} -> "following";
                        {false, false} -> "none"
                    end,
                    FinalStatus = case IsContact of
                        true -> FollowStatus ++ " + contact";
                        _ -> FollowStatus
                    end,
                    io:format("~s    ~s~n", [Buid, FinalStatus])
                end,
                sets:to_list(List))
    end,
    ok.


username_info(Username) ->
    username_info(Username, []).

username_info_short(Username) ->
    username_info(Username, [short]).

username_info(Username, Options) ->
    case model_accounts:get_username_uid(Username) of
        {ok, undefined} ->
            io:format("No account associated with username: ~s", [Username]);
        {ok, Uid} ->
            uid_info_katchup(Uid, Options)
    end.


print_push_token_info(Uid) ->
    {ok, PushInfo} = model_accounts:get_push_info(Uid),
    #push_info{os = Os,
        token = Token,
        voip_token = VoipToken,
        huawei_token = HuaweiToken} = PushInfo,
    TokenPrint = case Token of
                     <<TokenHead:8/binary, _/binary>> -> TokenHead;
                     _ -> Token
                 end,
    VoipTokenPrint = case VoipToken of
                         <<VoipTokenHead:8/binary, _/binary>> -> VoipTokenHead;
                         _ -> VoipToken
                     end,
    HuaweiTokenPrint = case HuaweiToken of
                           <<HuaweiTokenHead:8/binary, _/binary>> -> HuaweiTokenHead;
                           _ -> HuaweiToken
                       end,
    io:format("TokenInfo, OS: ~s, TokenHead: ~s, VoipTokenHead: ~s, HuaweiTokenHead: ~s~n",
        [Os, TokenPrint, VoipTokenPrint, HuaweiTokenPrint]).


phone_info_with_all_contacts(Phone, AppType) ->
    phone_info(Phone, AppType, [show_all_contacts]).

phone_info_short(Phone, AppType) ->
    phone_info(Phone, AppType, [short]).

phone_info(Phone, AppType) ->
    phone_info(Phone, AppType, []).

phone_info(Phone, AppTypeStr, Options) ->
    AppType = util:to_atom(AppTypeStr),
    case AppType of
        all ->
            phone_info(Phone, ?HALLOAPP, Options),
            io:format("------------------------------------------------------------~n"),
            phone_info(Phone, ?KATCHUP, Options);
        _ ->
            case model_phone:get_uid(Phone, AppType) of
                {ok, undefined} ->
                    io:format("No ~s account associated with phone: ~s~n", [AppType, Phone]),
                    invite_info(Phone);
                {ok, Uid2} -> uid_info(Uid2, Options)
            end
    end,
    ok.


invite_info(Phone) ->
    case model_invites:is_invited(Phone) of
        false -> io:format("This phone number has not been invited~n");
        true ->
            {ok, InviterList} = model_invites:get_inviters_list(Phone),
            lists:foreach(
                fun ({Uid, Ts}) ->
                    {Day, Time} = util:ms_to_datetime_string(binary_to_integer(Ts) * ?SECONDS_MS),
                    {ok, Name} = model_accounts:get_name(Uid),
                    io:format("~s was invited by ~s (~s) on ~s at ~s.~n",
                        [Phone, Name, Uid, Day, Time])
                end,
                InviterList)
    end,
    ok.


group_info(Gid) ->
    case model_groups:group_exists(Gid) of
        false -> io:format("No group associated with gid: ~s~n", [Gid]);
        true ->
            Group = model_groups:get_group(Gid),
            GName = Group#group.name,
            Members = [{Uid, Type, util:ms_to_datetime_string(Ts),
                model_accounts:get_name_binary(Uid), format_contact_list(Uid)}
                || #group_member{uid = Uid, type = Type, joined_ts_ms = Ts} <- Group#group.members],
            {CreateDate, CreateTime} = util:ms_to_datetime_string(Group#group.creation_ts_ms),
            io:format("~s (~s), created on ~s at ~s:~n", [GName, Gid, CreateDate, CreateTime]),
            [io:format("    ~s (~s) | ~s | joined on ~s at ~s, Num Contacts: ~p, Num Friends: ~p~n",
                [Name, Uid, Type, Date, Time, length(ContactList), NumFriends])
                || {Uid, Type, {Date, Time}, Name, {ok, ContactList, NumFriends}} <- Members]
    end,
    ok.


session_info(Uid) ->
    ?INFO("Admin requesting session info for uid: ~p", [Uid]),
    Sessions = ejabberd_sm:get_sessions(Uid, util:get_host()),
    case Sessions of
        [] -> io:format("User ~p currently has no sessions~n", [Uid]);
        _ ->
            io:format("User ~p has ~p sessions~n", [Uid, length(Sessions)]),
            lists:foreach(
                fun
                    (#session{sid = {_Ts, Pid} = Sid, usr = {_U, _S, R}, mode = Mode, info = Info}) ->
                        Node = node(Pid),
                        io:format("~p session on node: ~p~n", [Mode, Node]), 
                        io:format("  sid: ~p~n  resource: ~p~n  info: ~p~n", [Sid, R, Info])
                end,
                Sessions)
    end,
    ok.


spub_info(Key) ->
    case model_auth:spub_search(Key) of
        [] -> io:format("No results~n", []);
        Results ->
            lists:foreach(
                fun({ResultKey, Uid}) ->
                    io:format("~s: ~s~n", [ResultKey, Uid])
                end,
                Results)
    end.


reset_sms_backoff(Phone) ->
    reset_sms_backoff(Phone, halloapp).


reset_sms_backoff(Phone, AppType) ->
    ?INFO("Reset SMS backoff for: ~p, ~p", [Phone, AppType]),
    {ok, Attempts} = model_phone:get_verification_attempt_list(Phone, AppType),
    case Attempts of
        [] -> io:format("Nothing to reset~n");
        _ ->
            {AttemptId, _Ts} = lists:last(Attempts),
            model_phone:add_verification_success(Phone, AppType, AttemptId),
            io:format("Successfully reset SMS backoff for ~p~n", [Phone])
    end,
    ok.


get_full_sync_error_percent() ->
    io:format("full_sync_error_percent: ~p", [mod_contacts:get_full_sync_error_percent()]),
    ok.


get_full_sync_retry_time() ->
    io:format("full_sync_retry_time: ~p", [mod_contacts:get_full_sync_retry_time()]),
    ok.


%% TODO(murali@): add support for android as well.
send_ios_push(Uid, PushType, Payload) ->
    case ejabberd_auth:user_exists(Uid) of
        false ->
            io:format("Invalid uid: ~s", [Uid]);
        true ->
            {ok, PushInfo} = model_accounts:get_push_info(Uid),
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


get_sms_codes(PhoneRaw) ->
    get_sms_codes(PhoneRaw, halloapp),
    get_sms_codes(PhoneRaw, katchup).

get_sms_codes(PhoneRaw, AppType) ->
    ?INFO("Admin requesting SMS codes for ~p", [PhoneRaw]),
    Phone = mod_libphonenumber:prepend_plus(PhoneRaw),
    case mod_libphonenumber:normalized_number(Phone, <<"US">>) of
        undefined ->
            io:format("Phone number invalid~n"),
            io:format("Try entering only the numbers, no additional characters~n");
        NormalizedPhone ->
            {ok, RawList} = model_phone:get_all_verification_info(NormalizedPhone, AppType),
            case RawList of
                [] -> io:format("No SMS codes associated with phone: ~s, AppType: ~p~n", [NormalizedPhone, AppType]);
                _ ->
                    Codes = [Code || #verification_info{code = Code} <- RawList],
                    io:format("SMS codes for phone: ~s~n", [NormalizedPhone]),
                    [io:format("  ~s~n", [Code]) || Code <- Codes]
            end
    end,
    ok.


send_moment_notification(PhoneOrUid, Date, Timestamp, Id, Type, Prompt, HideBanner) ->
    Uid = case util_uid:looks_like_uid(PhoneOrUid) of
        true ->
            PhoneOrUid;
        false ->
            {ok, U} = model_phone:get_uid(PhoneOrUid, ?KATCHUP),
            U
    end,
    ?INFO("Admin Sending moment notification to ~s", [Uid]),
    mod_moment_notification2:send_moment_notification(Uid, Date, Timestamp, Id, util:to_atom(Type), Prompt, <<>>, util:to_atom(HideBanner), false).


send_invite(FromUid, ToPhone) ->
    case model_accounts:account_exists(FromUid) of
        true ->
            case dev_users:is_dev_uid(FromUid) of
                true ->
                    case mod_invites:request_invite(FromUid, ToPhone) of
                        {_ToPhone, ok, undefined} ->
                            io:format("Uid ~s marked phone ~s as invited~n", [FromUid, ToPhone]);
                        {_ToPhone, failed, Reason} ->
                            io:format("Failed to send invite: ~s~n", [Reason])
                    end;
                false -> io:format("Uid ~s is not a dev user", [FromUid])
            end;
        false -> io:format("No account associated with uid: ~s~n", [FromUid])
    end,
    ok.


delete_account(Uid) ->
    ?INFO("Admin initiated account deletion for uid: ~p", [Uid]),
    ejabberd_auth:remove_user(Uid, util:get_host()),
    io:format("Account deleted: ~p~n", [Uid]),
    ok.


request_phone_logs(Phone) ->
    request_phone_logs(Phone, halloapp),
    request_phone_logs(Phone, katchup).


-spec request_phone_logs(Phone :: binary(), AppType :: app_type()) -> ok.
request_phone_logs(Phone, AppType) ->
    case model_phone:get_uid(Phone, AppType) of
        {ok, undefined} ->
            io:format("No ~s account associated with phone: ~s~n", [AppType, Phone]);
        {ok, Uid} ->
            request_uid_logs(Uid),
            io:format("Sent ~s request_logs notification to phone: ~s~n", [AppType, Phone]);
        _ ->
            io:format("No ~s account associated with phone: ~s~n", [AppType, Phone])
    end.


-spec request_uid_logs(Uid :: binary()) -> ok.
request_uid_logs(Uid) ->
    case model_accounts:get_account(Uid) of
        {ok, _Account} ->
            notifications_util:send_request_logs_notification(Uid),
            io:format("Sent request_logs notification to uid: ~s~n", [Uid]);
        _ ->
            io:format("No account associated with uid: ~s~n", [Uid])
    end.

friend_recos(Uid) ->
    ?INFO("Admin requesting friend recommendations for uid: ~s", [Uid]),
    case model_accounts:account_exists(Uid) of
        false -> io:format("There is no account associated with uid: ~s~n", [Uid]);
        true ->
            {ok, #account{phone = Phone, name = Name, signup_user_agent = UserAgent,
                creation_ts_ms = CreationTs, last_activity_ts_ms = LastActivityTs,
                activity_status = ActivityStatus} = Account} = model_accounts:get_account(Uid),
            LastConnectionTime = model_accounts:get_last_connection_time(Uid),
            {CreationDate, CreationTime} = util:ms_to_datetime_string(CreationTs),
            {LastActiveDate, LastActiveTime} = util:ms_to_datetime_string(LastActivityTs),
            {LastConnDate, LastConnTime} = util:ms_to_datetime_string(LastConnectionTime),
            ?INFO("Uid: ~s, Name: ~s, Phone: ~s~n", [Uid, Name, Phone]),
            io:format("Uid: ~s~nName: ~s~nPhone: ~s~n", [Uid, Name, Phone]),
            io:format("Account created on ~s at ~s ua: ~s~n",
                [CreationDate, CreationTime, UserAgent]),
            io:format("Last activity on ~s at ~s and current status is ~s~n",
                [LastActiveDate, LastActiveTime, ActivityStatus]),
            io:format("Last connection on ~s at ~s~n", [LastConnDate, LastConnTime]),
            io:format("Current Version: ~s Lang: ~s~n", [Account#account.client_version, Account#account.lang_id]),

            {ok, RecommendationList} = mod_recommendations:generate_friend_recos(Uid, Phone),
            io:format("(~p recommendations):~n", [length(RecommendationList)]),
            [io:format("  ~s ~w ~s ~p ~s ~n", [CorF, CPhone, FUid, FNumFriends, FName]) ||
                {CorF, CPhone, FUid, FName, FNumFriends} <- RecommendationList]
    end,
    ok.


get_moment_notif_time(Date) ->
    %% Date must be an integer representing the day of the (current or nearest) month.
    CurrentTime = util:now(),
    {{Year,Month,TodayDate}, {_,_,_}} = calendar:system_time_to_universal_time(CurrentTime, second),
    %% Find the easiest timestamp where Date is true – doesn't have to be correct month, as it is indexed solely by Date
    LastDayOfMonth = calendar:last_day_of_the_month(Year, Month),
    InspectionTime = case Date > LastDayOfMonth of
        true ->
            %% Use day from previous month
            PrevMonth = case Month of
                1 -> 12;
                _ -> Month - 1
            end,
            LastDayOfPrevMonth = calendar:last_day_of_the_month(Year, PrevMonth),
            DaysDifference = (LastDayOfPrevMonth - Date) + TodayDate,
            CurrentTime - (DaysDifference * ?DAYS);
        false ->
            if
                Date =:= TodayDate ->
                    CurrentTime;
                Date < TodayDate ->
                    CurrentTime - ((TodayDate - Date) * ?DAYS);
                Date > TodayDate ->
                    CurrentTime + ((Date - TodayDate) * ?DAYS)
            end
    end,
    %% Get moment info
    case model_feed:get_moment_info(InspectionTime, false) of
        undefined ->
            io:format("No moment info for date: ~p (inspection time = ~p)~n", [Date, InspectionTime]);
        MomentNotifInfo ->
            Hrs = MomentNotifInfo#moment_notification.mins_to_send div 60,
            MinsRemaining = MomentNotifInfo#moment_notification.mins_to_send rem 60,
            Prompt = mod_prompts:get_prompt_from_id(MomentNotifInfo#moment_notification.promptId),
            MinsRemainingStr = case MinsRemaining < 10 of
                true -> "0" ++ util:to_list(MinsRemaining);
                false -> util:to_list(MinsRemaining)
            end,
            io:format("Date: ~p~nTime to send: ~p:~s~nType: ~p~nId: ~p~nPromptId: ~p~nPrompt: ~s~n",
                [Date, Hrs, MinsRemainingStr, MomentNotifInfo#moment_notification.type,
                    MomentNotifInfo#moment_notification.id, MomentNotifInfo#moment_notification.promptId, Prompt#prompt.text])
    end,
    ok.

