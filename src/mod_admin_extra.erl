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

-export([start/2, stop/1, reload/3, mod_options/1,
	 get_commands_spec/0, depends/2]).

% Commands API
-export([
	 % Adminsys
	 compile/1, get_cookie/0,
	 restart_module/2,

	 % Sessions
	 num_resources/2, resource_num/3,
	 kick_session/4, status_num/2, status_num/1,
	 status_list/2, status_list/1, connected_users_info/0,
	 connected_users_vhost/1, set_presence/7,
	 get_presence/2, user_sessions_info/2,

	 % Accounts
	 set_password/3, check_password_hash/4, delete_old_users/1,
	 delete_old_users_vhost/2, ban_account/3, check_password/3,

	 % Private storage
	 private_get/4, private_set/3,

	 % Send message
	 send_message/5, send_stanza/3, send_stanza_c2s/4,

	 % Privacy list
	 privacy_set/3,

	 % Stats
	 stats/1, stats/2
	]).


-include("ejabberd_commands.hrl").
-include("mod_privacy.hrl").
-include("ejabberd_sm.hrl").
-include("xmpp.hrl").

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

get_commands_spec() ->
    Vcard1FieldsString = "Some vcard field names in get/set_vcard are:\n"
	" FN		- Full Name\n"
	" NICKNAME	- Nickname\n"
	" BDAY		- Birthday\n"
	" TITLE		- Work: Position\n"
	" ROLE		- Work: Role",

    Vcard2FieldsString = "Some vcard field names and subnames in get/set_vcard2 are:\n"
	" N FAMILY	- Family name\n"
	" N GIVEN	- Given name\n"
	" N MIDDLE	- Middle name\n"
	" ADR CTRY	- Address: Country\n"
	" ADR LOCALITY	- Address: City\n"
	" TEL HOME      - Telephone: Home\n"
	" TEL CELL      - Telephone: Cellphone\n"
	" TEL WORK      - Telephone: Work\n"
	" TEL VOICE     - Telephone: Voice\n"
	" EMAIL USERID	- E-Mail Address\n"
	" ORG ORGNAME	- Work: Company\n"
	" ORG ORGUNIT	- Work: Department",

    VcardXEP = "For a full list of vCard fields check XEP-0054: vcard-temp at "
	"http://www.xmpp.org/extensions/xep-0054.html",

    [
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
     #ejabberd_commands{name = delete_old_users, tags = [accounts, purge],
			desc = "Delete users that didn't log in last days, or that never logged",
			longdesc = "To protect admin accounts, configure this for example:\n"
			    "access_rules:\n"
			    "  protect_old_users:\n"
			    "    - allow: admin\n"
			    "    - deny: all\n",
			module = ?MODULE, function = delete_old_users,
			args = [{days, integer}],
			args_example = [30],
			args_desc = ["Last login age in days of accounts that should be removed"],
			result = {res, restuple},
			result_example = {ok, <<"Deleted 2 users: [\"oldman@myserver.com\", \"test@myserver.com\"]">>},
			result_desc = "Result tuple"},
     #ejabberd_commands{name = delete_old_users_vhost, tags = [accounts, purge],
			desc = "Delete users that didn't log in last days in vhost, or that never logged",
			longdesc = "To protect admin accounts, configure this for example:\n"
			    "access_rules:\n"
			    "  delete_old_users:\n"
			    "    - deny: admin\n"
			    "    - allow: all\n",
			module = ?MODULE, function = delete_old_users_vhost,
			args = [{host, binary}, {days, integer}],
			args_example = [<<"myserver.com">>, 30],
			args_desc = ["Server name",
				     "Last login age in days of accounts that should be removed"],
			result = {res, restuple},
			result_example = {ok, <<"Deleted 2 users: [\"oldman@myserver.com\", \"test@myserver.com\"]">>},
			result_desc = "Result tuple"},
     #ejabberd_commands{name = check_account, tags = [accounts],
			desc = "Check if an account exists or not",
			module = ejabberd_auth, function = user_exists,
			args = [{user, binary}, {host, binary}],
			args_example = [<<"peter">>, <<"myserver.com">>],
			args_desc = ["User name to check", "Server to check"],
			result = {res, rescode},
			result_example = ok,
			result_desc = "Status code: 0 on success, 1 otherwise"},
     #ejabberd_commands{name = check_password, tags = [accounts],
			desc = "Check if a password is correct",
			module = ?MODULE, function = check_password,
			args = [{user, binary}, {host, binary}, {password, binary}],
			args_example = [<<"peter">>, <<"myserver.com">>, <<"secret">>],
			args_desc = ["User name to check", "Server to check", "Password to check"],
			result = {res, rescode},
			result_example = ok,
			result_desc = "Status code: 0 on success, 1 otherwise"},
     #ejabberd_commands{name = check_password_hash, tags = [accounts],
			desc = "Check if the password hash is correct",
			longdesc = "Allows hash methods from crypto application",
			module = ?MODULE, function = check_password_hash,
			args = [{user, binary}, {host, binary}, {passwordhash, binary},
				{hashmethod, binary}],
			args_example = [<<"peter">>, <<"myserver.com">>,
					<<"5ebe2294ecd0e0f08eab7690d2a6ee69">>, <<"md5">>],
			args_desc = ["User name to check", "Server to check",
				     "Password's hash value", "Name of hash method"],
			result = {res, rescode},
			result_example = ok,
			result_desc = "Status code: 0 on success, 1 otherwise"},
     #ejabberd_commands{name = change_password, tags = [accounts],
			desc = "Change the password of an account",
			module = ?MODULE, function = set_password,
			args = [{user, binary}, {host, binary}, {newpass, binary}],
			args_example = [<<"peter">>, <<"myserver.com">>, <<"blank">>],
			args_desc = ["User name", "Server name",
				     "New password for user"],
			result = {res, rescode},
			result_example = ok,
			result_desc = "Status code: 0 on success, 1 otherwise"},
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
     #ejabberd_commands{name = num_resources, tags = [session],
			desc = "Get the number of resources of a user",
			module = ?MODULE, function = num_resources,
			args = [{user, binary}, {host, binary}],
			args_example = [<<"peter">>, <<"myserver.com">>],
			args_desc = ["User name", "Server name"],
			result = {resources, integer},
			result_example = 5,
			result_desc = "Number of active resources for a user"},
     #ejabberd_commands{name = resource_num, tags = [session],
			desc = "Resource string of a session number",
			module = ?MODULE, function = resource_num,
			args = [{user, binary}, {host, binary}, {num, integer}],
			args_example = [<<"peter">>, <<"myserver.com">>, 2],
			args_desc = ["User name", "Server name", "ID of resource to return"],
			result = {resource, string},
			result_example = <<"Psi">>,
			result_desc = "Name of user resource"},
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
     #ejabberd_commands{name = status_num_host, tags = [session, stats],
			desc = "Number of logged users with this status in host",
			policy = admin,
			module = ?MODULE, function = status_num,
			args = [{host, binary}, {status, binary}],
			args_example = [<<"myserver.com">>, <<"dnd">>],
			args_desc = ["Server name", "Status type to check"],
			result = {users, integer},
			result_example = 23,
			result_desc = "Number of connected sessions with given status type"},
     #ejabberd_commands{name = status_num, tags = [session, stats],
			desc = "Number of logged users with this status",
			policy = admin,
			module = ?MODULE, function = status_num,
			args = [{status, binary}],
			args_example = [<<"dnd">>],
			args_desc = ["Status type to check"],
			result = {users, integer},
			result_example = 23,
			result_desc = "Number of connected sessions with given status type"},
     #ejabberd_commands{name = status_list_host, tags = [session],
			desc = "List of users logged in host with their statuses",
			module = ?MODULE, function = status_list,
			args = [{host, binary}, {status, binary}],
			args_example = [<<"myserver.com">>, <<"dnd">>],
			args_desc = ["Server name", "Status type to check"],
			result_example = [{<<"peter">>,<<"myserver.com">>,<<"tka">>,6,<<"Busy">>}],
			result = {users, {list,
					  {userstatus, {tuple, [
								{user, string},
								{host, string},
								{resource, string},
								{priority, integer},
								{status, string}
							       ]}}
					 }}},
     #ejabberd_commands{name = status_list, tags = [session],
			desc = "List of logged users with this status",
			module = ?MODULE, function = status_list,
			args = [{status, binary}],
			args_example = [<<"dnd">>],
			args_desc = ["Status type to check"],
			result_example = [{<<"peter">>,<<"myserver.com">>,<<"tka">>,6,<<"Busy">>}],
			result = {users, {list,
					  {userstatus, {tuple, [
								{user, string},
								{host, string},
								{resource, string},
								{priority, integer},
								{status, string}
							       ]}}
					 }}},
     #ejabberd_commands{name = connected_users_info,
			tags = [session],
			desc = "List all established sessions and their information",
			module = ?MODULE, function = connected_users_info,
			args = [],
			result_example = [{"user1@myserver.com/tka",
					    "c2s", "127.0.0.1", 42656,8, "ejabberd@localhost",
                                           231, <<"dnd">>, <<"tka">>, <<>>}],
			result = {connected_users_info,
				  {list,
				   {session, {tuple,
					      [{jid, string},
					       {connection, string},
					       {ip, string},
					       {port, integer},
					       {priority, integer},
					       {node, string},
					       {uptime, integer},
					       {status, string},
					       {resource, string},
					       {statustext, string}
					      ]}}
				  }}},

     #ejabberd_commands{name = connected_users_vhost,
			tags = [session],
			desc = "Get the list of established sessions in a vhost",
			module = ?MODULE, function = connected_users_vhost,
			args_example = [<<"myexample.com">>],
			args_desc = ["Server name"],
			result_example = [<<"user1@myserver.com/tka">>, <<"user2@localhost/tka">>],
			args = [{host, binary}],
			result = {connected_users_vhost, {list, {sessions, string}}}},
     #ejabberd_commands{name = user_sessions_info,
			tags = [session],
			desc = "Get information about all sessions of a user",
			module = ?MODULE, function = user_sessions_info,
			args = [{user, binary}, {host, binary}],
			args_example = [<<"peter">>, <<"myserver.com">>],
			args_desc = ["User name", "Server name"],
			result_example = [{"c2s", "127.0.0.1", 42656,8, "ejabberd@localhost",
                                           231, <<"dnd">>, <<"tka">>, <<>>}],
			result = {sessions_info,
				  {list,
				   {session, {tuple,
					      [{connection, string},
					       {ip, string},
					       {port, integer},
					       {priority, integer},
					       {node, string},
					       {uptime, integer},
					       {status, string},
					       {resource, string},
					       {statustext, string}
					      ]}}
				  }}},

     #ejabberd_commands{name = get_presence, tags = [session],
			desc =
			    "Retrieve the resource with highest priority, "
			    "and its presence (show and status message) "
			    "for a given user.",
			longdesc =
			    "The 'jid' value contains the user jid "
			    "with resource.\nThe 'show' value contains "
			    "the user presence flag. It can take "
			    "limited values:\n - available\n - chat "
			    "(Free for chat)\n - away\n - dnd (Do "
			    "not disturb)\n - xa (Not available, "
			    "extended away)\n - unavailable (Not "
			    "connected)\n\n'status' is a free text "
			    "defined by the user client.",
			module = ?MODULE, function = get_presence,
			args = [{user, binary}, {host, binary}],
			args_rename = [{server, host}],
			args_example = [<<"peter">>, <<"myexample.com">>],
			args_desc = ["User name", "Server name"],
			result_example = {<<"user1@myserver.com/tka">>, <<"dnd">>, <<"Busy">>},
			result =
			    {presence,
			     {tuple,
			      [{jid, string}, {show, string},
			       {status, string}]}}},
     #ejabberd_commands{name = set_presence,
			tags = [session],
			desc = "Set presence of a session",
			module = ?MODULE, function = set_presence,
			args = [{user, binary}, {host, binary},
				{resource, binary}, {type, binary},
				{show, binary}, {status, binary},
				{priority, binary}],
			args_example = [<<"user1">>,<<"myserver.com">>,<<"tka1">>,
					<<"available">>,<<"away">>,<<"BB">>, <<"7">>],
			args_desc = ["User name", "Server name", "Resource",
					"Type: available, error, probe...",
					"Show: away, chat, dnd, xa.", "Status text",
					"Priority, provide this value as an integer"],
			result = {res, rescode}},

     #ejabberd_commands{name = set_nickname, tags = [vcard],
			desc = "Set nickname in a user's vCard",
			module = ?MODULE, function = set_nickname,
			args = [{user, binary}, {host, binary}, {nickname, binary}],
			args_example = [<<"user1">>,<<"myserver.com">>,<<"User 1">>],
			args_desc = ["User name", "Server name", "Nickname"],
			result = {res, rescode}},
     #ejabberd_commands{name = get_vcard, tags = [vcard],
			desc = "Get content from a vCard field",
			longdesc = Vcard1FieldsString ++ "\n" ++ Vcard2FieldsString ++ "\n\n" ++ VcardXEP,
			module = ?MODULE, function = get_vcard,
			args = [{user, binary}, {host, binary}, {name, binary}],
			args_example = [<<"user1">>,<<"myserver.com">>,<<"NICKNAME">>],
			args_desc = ["User name", "Server name", "Field name"],
			result_example = "User 1",
			result_desc = "Field content",
			result = {content, string}},
     #ejabberd_commands{name = get_vcard2, tags = [vcard],
			desc = "Get content from a vCard subfield",
			longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
			module = ?MODULE, function = get_vcard,
			args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}],
			args_example = [<<"user1">>,<<"myserver.com">>,<<"N">>, <<"FAMILY">>],
			args_desc = ["User name", "Server name", "Field name", "Subfield name"],
			result_example = "Schubert",
			result_desc = "Field content",
			result = {content, string}},
     #ejabberd_commands{name = get_vcard2_multi, tags = [vcard],
			desc = "Get multiple contents from a vCard field",
			longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
			module = ?MODULE, function = get_vcard_multi,
			args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}],
			result = {contents, {list, {value, string}}}},

     #ejabberd_commands{name = set_vcard, tags = [vcard],
			desc = "Set content in a vCard field",
			longdesc = Vcard1FieldsString ++ "\n" ++ Vcard2FieldsString ++ "\n\n" ++ VcardXEP,
			module = ?MODULE, function = set_vcard,
			args = [{user, binary}, {host, binary}, {name, binary}, {content, binary}],
			args_example = [<<"user1">>,<<"myserver.com">>, <<"URL">>, <<"www.example.com">>],
			args_desc = ["User name", "Server name", "Field name", "Value"],
			result = {res, rescode}},
     #ejabberd_commands{name = set_vcard2, tags = [vcard],
			desc = "Set content in a vCard subfield",
			longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
			module = ?MODULE, function = set_vcard,
			args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}, {content, binary}],
			args_example = [<<"user1">>,<<"myserver.com">>,<<"TEL">>, <<"NUMBER">>, <<"123456">>],
			args_desc = ["User name", "Server name", "Field name", "Subfield name", "Value"],
			result = {res, rescode}},
     #ejabberd_commands{name = set_vcard2_multi, tags = [vcard],
			desc = "Set multiple contents in a vCard subfield",
			longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
			module = ?MODULE, function = set_vcard,
			args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}, {contents, {list, {value, binary}}}],
			result = {res, rescode}},

     #ejabberd_commands{name = send_message, tags = [stanza],
			desc = "Send a message to a local or remote bare of full JID",
			longdesc = "When sending a groupchat message to a MUC room, "
			"FROM must be the full JID of a room occupant, "
			"or the bare JID of a MUC service admin, "
			"or the bare JID of a MUC/Sub subscribed user.",
			module = ?MODULE, function = send_message,
			args = [{type, binary}, {from, binary}, {to, binary},
				{subject, binary}, {body, binary}],
			args_example = [<<"headline">>, <<"admin@localhost">>, <<"user1@localhost">>,
				<<"Restart">>, <<"In 5 minutes">>],
			args_desc = ["Message type: normal, chat, headline, groupchat", "Sender JID",
				"Receiver JID", "Subject, or empty string", "Body"],
			result = {res, rescode}},
     #ejabberd_commands{name = send_stanza_c2s, tags = [stanza],
			desc = "Send a stanza as if sent from a c2s session",
			module = ?MODULE, function = send_stanza_c2s,
			args = [{user, binary}, {host, binary}, {resource, binary}, {stanza, binary}],
			args_example = [<<"admin">>, <<"myserver.com">>, <<"bot">>,
				<<"<message to='user1@localhost'><ext attr='value'/></message>">>],
			args_desc = ["Username", "Server name", "Resource", "Stanza"],
			result = {res, rescode}},
     #ejabberd_commands{name = send_stanza, tags = [stanza],
			desc = "Send a stanza; provide From JID and valid To JID",
			module = ?MODULE, function = send_stanza,
			args = [{from, binary}, {to, binary}, {stanza, binary}],
			args_example = [<<"admin@localhost">>, <<"user1@localhost">>,
				<<"<message><ext attr='value'/></message>">>],
			args_desc = ["Sender JID", "Destination JID", "Stanza"],
			result = {res, rescode}},
     #ejabberd_commands{name = privacy_set, tags = [stanza],
			desc = "Send a IQ set privacy stanza for a local account",
			module = ?MODULE, function = privacy_set,
			args = [{user, binary}, {host, binary}, {xmlquery, binary}],
			args_example = [<<"user1">>, <<"myserver.com">>,
				<<"<query xmlns='jabber:iq:privacy'>...">>],
			args_desc = ["Username", "Server name", "Query XML element"],
			result = {res, rescode}},

     #ejabberd_commands{name = stats, tags = [stats],
			desc = "Get statistical value: registeredusers onlineusers onlineusersnode uptimeseconds processes",
			policy = admin,
			module = ?MODULE, function = stats,
			args = [{name, binary}],
			args_example = [<<"registeredusers">>],
			args_desc = ["Statistic name"],
			result_example = 6,
			result_desc = "Integer statistic value",
			result = {stat, integer}},
     #ejabberd_commands{name = stats_host, tags = [stats],
			desc = "Get statistical value for this host: registeredusers onlineusers",
			policy = admin,
			module = ?MODULE, function = stats,
			args = [{name, binary}, {host, binary}],
			args_example = [<<"registeredusers">>, <<"example.com">>],
			args_desc = ["Statistic name", "Server JID"],
			result_example = 6,
			result_desc = "Integer statistic value",
			result = {stat, integer}}
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

set_password(User, Host, Password) ->
    Fun = fun () -> ejabberd_auth:set_password(User, Password) end,
    user_action(User, Host, Fun, ok).

check_password(User, _Host, Password) ->
    ejabberd_auth:check_password(User, Password).

%% Copied some code from ejabberd_commands.erl
check_password_hash(_User, _Host, PasswordHash, HashMethod) ->
    AccountPass = <<"">>,
    Methods = lists:map(fun(A) -> atom_to_binary(A, latin1) end,
                   proplists:get_value(hashs, crypto:supports())),
    MethodAllowed = lists:member(HashMethod, Methods),
    AccountPassHash = case {AccountPass, MethodAllowed} of
			  {A, _} when is_tuple(A) -> scrammed;
			  {_, true} -> get_hash(AccountPass, HashMethod);
			  {_, false} ->
			      ?ERROR("Check_password_hash called "
					 "with hash method: ~p", [HashMethod]),
			      undefined
		      end,
    case AccountPassHash of
	scrammed ->
	    ?ERROR("Passwords are scrammed, and check_password_hash cannot work.", []),
	    throw(passwords_scrammed_command_cannot_work);
	undefined -> throw(unkown_hash_method);
	PasswordHash -> ok;
	_ -> false
    end.

get_hash(AccountPass, Method) ->
    iolist_to_binary([io_lib:format("~2.16.0B", [X])
          || X <- binary_to_list(
              crypto:hash(binary_to_atom(Method, latin1), AccountPass))]).

delete_old_users(Days) ->
    %% Get the list of registered users
    Users = ejabberd_auth:get_users(),

    {removed, N, UR} = delete_old_users(Days, Users),
    {ok, io_lib:format("Deleted ~p users: ~p", [N, UR])}.

delete_old_users_vhost(_Host, Days) ->
    %% Get the list of registered users
    Users = ejabberd_auth:get_users(),

    {removed, N, UR} = delete_old_users(Days, Users),
    {ok, io_lib:format("Deleted ~p users: ~p", [N, UR])}.

delete_old_users(Days, Users) ->
    SecOlder = Days*24*60*60,
    TimeStamp_now = erlang:system_time(second),
    TimeStamp_oldest = TimeStamp_now - SecOlder,
    F = fun({LUser, LServer}) ->
	    case catch delete_or_not(LUser, LServer, TimeStamp_oldest) of
		true ->
		    ejabberd_auth:remove_user(LUser, LServer),
		    true;
		_ ->
		    false
	    end
	end,
    Users_removed = lists:filter(F, Users),
    {removed, length(Users_removed), Users_removed}.

delete_or_not(_LUser, _LServer, _TimeStamp_oldest) ->
	erlang:error(unimplemented).

%%
%% Ban account

ban_account(User, Host, ReasonText) ->
    Reason = prepare_reason(ReasonText),
    kick_sessions(User, Host, Reason),
    set_random_password(User, Host, Reason),
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

set_password_auth(User, _Server, Password) ->
    ok = ejabberd_auth:set_password(User, Password).

prepare_reason([]) ->
    <<"Kicked by administrator">>;
prepare_reason([Reason]) ->
    Reason;
prepare_reason(Reason) when is_binary(Reason) ->
    Reason.

%%%
%%% Sessions
%%%

num_resources(User, Host) ->
    length(ejabberd_sm:get_user_resources(User, Host)).

resource_num(User, Host, Num) ->
    Resources = ejabberd_sm:get_user_resources(User, Host),
    case (0<Num) and (Num=<length(Resources)) of
	true ->
	    lists:nth(Num, Resources);
	false ->
            throw({bad_argument,
                   lists:flatten(io_lib:format("Wrong resource number: ~p", [Num]))})
    end.

kick_session(User, Server, Resource, ReasonText) ->
    kick_this_session(User, Server, Resource, prepare_reason(ReasonText)),
    ok.

kick_this_session(User, Server, Resource, Reason) ->
    ejabberd_sm:route(jid:make(User, Server, Resource),
                      {exit, Reason}).

status_num(Host, Status) ->
    length(get_status_list(Host, Status)).
status_num(Status) ->
    status_num(<<"all">>, Status).
status_list(Host, Status) ->
    Res = get_status_list(Host, Status),
    [{U, S, R, num_prio(P), St} || {U, S, R, P, St} <- Res].
status_list(Status) ->
    status_list(<<"all">>, Status).


get_status_list(Host, Status_required) ->
    %% Get list of all logged users
    Sessions = ejabberd_sm:dirty_get_my_sessions_list(),
    %% Reformat the list
    Sessions2 = [ {Session#session.usr, Session#session.sid, Session#session.priority} || Session <- Sessions],
    Fhost = case Host of
		<<"all">> ->
		    %% All hosts are requested, so don't filter at all
		    fun(_, _) -> true end;
		_ ->
		    %% Filter the list, only Host is interesting
		    fun(A, B) -> A == B end
	    end,
    Sessions3 = [ {Pid, Server, Priority} || {{_User, Server, _Resource}, {_, Pid}, Priority} <- Sessions2, apply(Fhost, [Server, Host])],
    %% For each Pid, get its presence
    Sessions4 = [ {catch get_presence(Pid), Server, Priority} || {Pid, Server, Priority} <- Sessions3],
    %% Filter by status
    Fstatus = case Status_required of
		  <<"all">> ->
		      fun(_, _) -> true end;
		  _ ->
		      fun(A, B) -> A == B end
	      end,
    [{User, Server, Resource, num_prio(Priority), stringize(Status_text)}
     || {{User, Resource, Status, Status_text}, Server, Priority} <- Sessions4,
	apply(Fstatus, [Status, Status_required])].

connected_users_info() ->
    lists:filtermap(
      fun({U, S, R}) ->
	    case user_session_info(U, S, R) of
		offline ->
		    false;
		Info ->
		    Jid = jid:encode(jid:make(U, S, R)),
		    {true, erlang:insert_element(1, Info, Jid)}
	    end
      end,
      ejabberd_sm:dirty_get_sessions_list()).

connected_users_vhost(Host) ->
    USRs = ejabberd_sm:get_vh_session_list(Host),
    [ jid:encode(jid:make(USR)) || USR <- USRs].

%% Make string more print-friendly
stringize(String) ->
    %% Replace newline characters with other code
    ejabberd_regexp:greplace(String, <<"\n">>, <<"\\n">>).

get_presence(Pid) ->
    try get_presence2(Pid) of
	{_, _, _, _} = Res ->
	    Res
    catch
	_:_ -> {<<"">>, <<"">>, <<"offline">>, <<"">>}
    end.
get_presence2(Pid) ->
    Pres = #presence{from = From} = ejabberd_c2s:get_presence(Pid),
    Show = case Pres of
	       #presence{type = unavailable} -> <<"unavailable">>;
	       #presence{show = undefined} -> <<"available">>;
	       #presence{show = S} -> atom_to_binary(S, utf8)
	   end,
    Status = xmpp:get_text(Pres#presence.status),
    {From#jid.user, From#jid.resource, Show, Status}.

get_presence(U, S) ->
    Pids = [ejabberd_sm:get_session_pid(U, S, R)
	    || R <- ejabberd_sm:get_user_resources(U, S)],
    OnlinePids = [Pid || Pid <- Pids, Pid=/=none],
    case OnlinePids of
	[] ->
	    {jid:encode({U, S, <<>>}), <<"unavailable">>, <<"">>};
	[SessionPid|_] ->
	    {_User, Resource, Show, Status} = get_presence(SessionPid),
	    FullJID = jid:encode({U, S, Resource}),
	    {FullJID, Show, Status}
    end.

set_presence(User, Host, Resource, Type, Show, Status, Priority)
        when is_integer(Priority) ->
    BPriority = integer_to_binary(Priority),
    set_presence(User, Host, Resource, Type, Show, Status, BPriority);
set_presence(User, Host, Resource, Type, Show, Status, Priority0) ->
    Priority = if is_integer(Priority0) -> Priority0;
		  true -> binary_to_integer(Priority0)
	       end,
    Pres = #presence{
        from = jid:make(User, Host, Resource),
        to = jid:make(User, Host),
        type = misc:binary_to_atom(Type),
        status = xmpp:mk_text(Status),
        show = misc:binary_to_atom(Show),
        priority = Priority,
        sub_els = []},
    Ref = ejabberd_sm:get_session_pid(User, Host, Resource),
    ejabberd_c2s:set_presence(Ref, Pres).

user_sessions_info(User, Host) ->
    lists:filtermap(fun(Resource) ->
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
	    {_U, _Resource, Status, StatusText} = get_presence(Pid),
	    Priority = proplists:get_value(priority, Info),
	    Conn = proplists:get_value(conn, Info),
	    {Ip, Port} = proplists:get_value(ip, Info),
	    IPS = inet_parse:ntoa(Ip),
	    NodeS = atom_to_list(node(Pid)),
	    Uptime = CurrentSec - calendar:datetime_to_gregorian_seconds(
				    calendar:now_to_local_time(Now)),
	    {atom_to_list(Conn), IPS, Port, num_prio(Priority), NodeS, Uptime, Status, Resource, StatusText}
    end.


%%%
%%% Private Storage
%%%

%% Example usage:
%% $ ejabberdctl private_set badlop localhost "\<aa\ xmlns=\'bb\'\>Cluth\</aa\>"
%% $ ejabberdctl private_get badlop localhost aa bb
%% <aa xmlns='bb'>Cluth</aa>

private_get(Username, Host, Element, Ns) ->
    ElementXml = #xmlel{name = Element, attrs = [{<<"xmlns">>, Ns}]},
    Els = mod_private:get_data(jid:nodeprep(Username), jid:nameprep(Host),
			       [{Ns, ElementXml}]),
    binary_to_list(fxml:element_to_binary(xmpp:encode(#private{sub_els = Els}))).

private_set(Username, Host, ElementString) ->
    case fxml_stream:parse_element(ElementString) of
	{error, Error} ->
	    io:format("Error found parsing the element:~n  ~p~nError: ~p~n",
		      [ElementString, Error]),
	    error;
	Xml ->
	    private_set2(Username, Host, Xml)
    end.

private_set2(Username, Host, Xml) ->
    NS = fxml:get_tag_attr_s(<<"xmlns">>, Xml),
    JID = jid:make(Username, Host),
    mod_private:set_data(JID, [{NS, Xml}]).

to_list([]) -> [];
to_list([H|T]) -> [to_list(H)|to_list(T)];
to_list(E) when is_atom(E) -> atom_to_list(E);
to_list(E) -> binary_to_list(E).


%%%
%%% Stanza
%%%

%% @doc Send a message to a Jabber account.
%% @spec (Type::binary(), From::binary(), To::binary(), Subject::binary(), Body::binary()) -> ok
send_message(Type, From, To, Subject, Body) ->
    FromJID = jid:decode(From),
    ToJID = jid:decode(To),
    Packet = build_packet(Type, Subject, Body, FromJID, ToJID),
    State1 = #{jid => FromJID},
    ejabberd_hooks:run_fold(user_send_packet, FromJID#jid.lserver, {Packet, State1}, []),
    ejabberd_router:route(xmpp:set_from_to(Packet, FromJID, ToJID)).

build_packet(Type, Subject, Body, FromJID, ToJID) ->
    #message{type = misc:binary_to_atom(Type),
	     body = xmpp:mk_text(Body),
	     from = FromJID,
	     to = ToJID,
	     id = p1_rand:get_string(),
	     subject = xmpp:mk_text(Subject)}.

send_stanza(FromString, ToString, Stanza) ->
    try
	#xmlel{} = El = fxml_stream:parse_element(Stanza),
	From = jid:decode(FromString),
	To = jid:decode(ToString),
	CodecOpts = ejabberd_config:codec_options(),
	Pkt = xmpp:decode(El, ?NS_CLIENT, CodecOpts),
	ejabberd_router:route(xmpp:set_from_to(Pkt, From, To))
    catch _:{xmpp_codec, Why} ->
	    io:format("incorrect stanza: ~ts~n", [xmpp:format_error(Why)]),
	    {error, Why};
	  _:{badmatch, {error, Why}} ->
	    io:format("invalid xml: ~p~n", [Why]),
	    {error, Why};
	  _:{bad_jid, S} ->
	    io:format("malformed JID: ~ts~n", [S]),
	    {error, "JID malformed"}
    end.

-spec send_stanza_c2s(binary(), binary(), binary(), binary()) -> ok | {error, any()}.
send_stanza_c2s(Username, Host, Resource, Stanza) ->
    try
	#xmlel{} = El = fxml_stream:parse_element(Stanza),
	CodecOpts = ejabberd_config:codec_options(),
	Pkt = xmpp:decode(El, ?NS_CLIENT, CodecOpts),
	case ejabberd_sm:get_session_pid(Username, Host, Resource) of
	    Pid when is_pid(Pid) ->
		ejabberd_c2s:send(Pid, Pkt);
	    _ ->
		{error, no_session}
	end
    catch _:{badmatch, {error, Why} = Err} ->
	    io:format("invalid xml: ~p~n", [Why]),
	    Err;
	  _:{xmpp_codec, Why} ->
	    io:format("incorrect stanza: ~ts~n", [xmpp:format_error(Why)]),
	    {error, Why}
    end.

privacy_set(Username, Host, QueryS) ->
    Jid = jid:make(Username, Host),
    QueryEl = fxml_stream:parse_element(QueryS),
    SubEl = xmpp:decode(QueryEl),
    IQ = #iq{type = set, id = <<"push">>, sub_els = [SubEl],
	     from = Jid, to = Jid},
    Result = mod_privacy:process_iq(IQ),
    Result#iq.type == result.

%%%
%%% Stats
%%%

stats(Name) ->
    case Name of
	<<"uptimeseconds">> -> trunc(element(1, erlang:statistics(wall_clock))/1000);
	<<"processes">> -> length(erlang:processes());
	<<"registeredusers">> -> ejabberd_auth:count_users();
	<<"onlineusersnode">> -> length(ejabberd_sm:dirty_get_my_sessions_list());
	<<"onlineusers">> -> length(ejabberd_sm:dirty_get_sessions_list())
    end.

stats(Name, Host) ->
    case Name of
	<<"registeredusers">> -> ejabberd_auth:count_users();
	<<"onlineusers">> -> length(ejabberd_sm:get_vh_session_list(Host))
    end.


user_action(User, _Server, Fun, OK) ->
    case ejabberd_auth:user_exists(User) of
        true ->
            case catch Fun() of
                OK -> ok;
                {error, Error} -> throw(Error);
                Error ->
                    ?ERROR("Command returned: ~p", [Error]),
                    1
            end;
        false ->
            throw({not_found, "unknown_user"})
    end.

num_prio(Priority) when is_integer(Priority) ->
    Priority;
num_prio(_) ->
    -1.

mod_options(_) -> [].
