%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_mnesia.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Authentication via mnesia
%%% Created : 12 Dec 2004 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_auth_mnesia).

-author('alexey@process-one.net').

-behaviour(ejabberd_auth).

-export([start/1, stop/1, set_password/3, try_register/3,
	 get_users/2, init_db/0, get_users_with_passwd/1,
	 count_users/2, get_password/2,
	 remove_user/2, store_type/1, import/2,
	 plain_password_required/1, use_cache/1,
	 try_enroll/3, get_enrolled_users/1, get_enrolled_users_with_code/1,
	 remove_enrolled_user/2, get_passcode/2,
	 generate_and_insert_user_id/2, get_user_id/2,
	 get_user_for_id/1, get_all_user_ids/1,
	 remove_user_id/2, insert_user_id/3]).
-export([need_transform/1, transform/1]).

-include("logger.hrl").
-include("scram.hrl").
-include("ejabberd_auth.hrl").
-include("user_info.hrl").

-record(reg_users_counter, {vhost = <<"">> :: binary(),
                            count = 0 :: integer() | '$1'}).

-record(enrolled_users, {username = {<<"">>, <<"">>} :: {binary(), binary()},
                         passcode = <<"">> :: binary()}).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(Host) ->
    init_db(),
    update_reg_users_counter_table(Host),
    ok.

stop(_Host) ->
    ok.

init_db() ->
    ejabberd_mnesia:create(?MODULE, passwd,
			[{disc_only_copies, [node()]},
			 {attributes, record_info(fields, passwd)}]),
    ejabberd_mnesia:create(?MODULE, enrolled_users,
                           [{disc_only_copies, [node()]},
                            {attributes, record_info(fields, enrolled_users)}]),
    ejabberd_mnesia:create(?MODULE, user_ids,
                           [{disc_only_copies, [node()]},
                            {attributes, record_info(fields, user_ids)}]),
    ejabberd_mnesia:create(?MODULE, reg_users_counter,
			[{ram_copies, [node()]},
			 {attributes, record_info(fields, reg_users_counter)}]).

update_reg_users_counter_table(Server) ->
    Set = get_users(Server, []),
    Size = length(Set),
    LServer = jid:nameprep(Server),
    F = fun () ->
		mnesia:write(#reg_users_counter{vhost = LServer,
						count = Size})
	end,
    mnesia:sync_dirty(F).

use_cache(Host) ->
    case mnesia:table_info(passwd, storage_type) of
	disc_only_copies ->
	    ejabberd_option:auth_use_cache(Host);
	_ ->
	    false
    end.

plain_password_required(Server) ->
    store_type(Server) == scram.

store_type(Server) ->
    ejabberd_auth:password_format(Server).

set_password(User, Server, Password) ->
    US = {User, Server},
    F = fun () ->
		mnesia:write(#passwd{us = US, password = Password})
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    {cache, {ok, Password}};
	{aborted, Reason} ->
	    ?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
	    {nocache, {error, db_failure}}
    end.

try_register(User, Server, Password) ->
    US = {User, Server},
    F = fun () ->
		case mnesia:read({passwd, US}) of
		    [] ->
			mnesia:write(#passwd{us = US, password = Password}),
			mnesia:dirty_update_counter(reg_users_counter, Server, 1),
			generate_and_insert_user_id(User, Server),
			create_pubsub_node(User, Server),
			{ok, Password};
		    [_] ->
			{error, exists}
		end
	end,
    case mnesia:transaction(F) of
	{atomic, Res} ->
	    {cache, Res};
	{aborted, Reason} ->
	    ?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
	    {nocache, {error, db_failure}}
    end.

-spec generate_and_insert_user_id(binary(), binary()) -> {ok, any()} | {error, any()}.
generate_and_insert_user_id(User, Server) ->
	UserId = util:generate_user_id(),
	insert_user_id(User, Server, UserId).


-spec insert_user_id(binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
insert_user_id(User, Server, UserId) ->
	US = {User, Server},
	F = fun () ->
		case mnesia:read({user_ids, US}) of
			[] ->
				mnesia:write(#user_ids{username = US, id = UserId}),
				{ok, UserId};
			[#user_ids{id = Id}] ->
				{ok, Id}
		end
	end,
	case mnesia:transaction(F) of
	{atomic, Res} ->
		Res;
	{aborted, Reason} ->
		?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
		{error, db_failure}
	end.



-spec create_pubsub_node(binary(), binary()) -> ok.
create_pubsub_node(User, Server) ->
	Host = mod_pubsub:host(Server),
	ServerHost = Server,
	Node = util:get_feed_pubsub_node_name(User),
	From = jid:make(User, Server),
	Type = <<"flat">>,
	Access = pubsub_createnode,
	Config = [{send_last_published_item, never}, {itemreply, publisher},
			{notification_type, normal}, {notify_retract, false}, {notify_delete, false},
			{publish_model, subscribers}, {access_model, whitelist}],
	JID = jid:make(User, Server),
	SubscribeConfig = [],
	Result1 = mod_pubsub:create_node(Host, ServerHost, Node, From, Type, Access, Config),
	Result2 = mod_pubsub:subscribe_node(Host, Node, From, JID, SubscribeConfig),
	?DEBUG("Tried creating a pubsub node for user: ~p, result: ~p, subscribe result: ~p",
			[From, Result1, Result2]),
	ok.


try_enroll(User, Server, Passcode) ->
    US = {User, Server},
    F = fun () ->
                case mnesia:read({enrolled_users, US}) of
                    [] ->
                        mnesia:write(#enrolled_users{username = US, passcode = Passcode}),
                        {ok, Passcode};
                    [_] ->
                        {error, exists}
                end
        end,
    case mnesia:transaction(F) of
        {atomic, Res} ->
            Res;
        {aborted, Reason} ->
            ?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
            {error, db_failure}
    end.


get_enrolled_users(Server) ->
        mnesia:dirty_select(enrolled_users,
                            [{#enrolled_users{username = '$1', _ = '_'},
                              [{'==', {element, 2, '$1'}, Server}], ['$1']}]).

get_enrolled_users_with_code(Server) ->
        mnesia:dirty_select(enrolled_users,
                            [{#enrolled_users{username = '$1', _ = '_'},
                              [{'==', {element, 2, '$1'}, Server}], ['$_']}]).

get_all_user_ids(Server) ->
    mnesia:dirty_select(user_ids, [{#user_ids{username = '$1', _ = '_'},
									[{'==', {element, 2, '$1'}, Server}], ['$_']}]).

get_users_with_passwd(Server) ->
    mnesia:dirty_select(passwd,
			[{#passwd{us = '$1', _ = '_'},
			  [{'==', {element, 2, '$1'}, Server}], ['$_']}]).

get_users(Server, []) ->
    mnesia:dirty_select(passwd,
			[{#passwd{us = '$1', _ = '_'},
			  [{'==', {element, 2, '$1'}, Server}], ['$1']}]);
get_users(Server, [{from, Start}, {to, End}])
  when is_integer(Start) and is_integer(End) ->
    get_users(Server, [{limit, End - Start + 1}, {offset, Start}]);
get_users(Server, [{limit, Limit}, {offset, Offset}])
  when is_integer(Limit) and is_integer(Offset) ->
    case get_users(Server, []) of
	[] ->
	    [];
	Users ->
	    Set = lists:keysort(1, Users),
	    L = length(Set),
	    Start = if Offset < 1 -> 1;
		       Offset > L -> L;
		       true -> Offset
		    end,
	    lists:sublist(Set, Start, Limit)
    end;
get_users(Server, [{prefix, Prefix}]) when is_binary(Prefix) ->
    Set = [{U, S} || {U, S} <- get_users(Server, []), str:prefix(Prefix, U)],
    lists:keysort(1, Set);
get_users(Server, [{prefix, Prefix}, {from, Start}, {to, End}])
  when is_binary(Prefix) and is_integer(Start) and is_integer(End) ->
    get_users(Server, [{prefix, Prefix}, {limit, End - Start + 1},
		       {offset, Start}]);
get_users(Server, [{prefix, Prefix}, {limit, Limit}, {offset, Offset}])
  when is_binary(Prefix) and is_integer(Limit) and is_integer(Offset) ->
    case [{U, S} || {U, S} <- get_users(Server, []), str:prefix(Prefix, U)] of
	[] ->
	    [];
	Users ->
	    Set = lists:keysort(1, Users),
	    L = length(Set),
	    Start = if Offset < 1 -> 1;
		       Offset > L -> L;
		       true -> Offset
		    end,
	    lists:sublist(Set, Start, Limit)
    end;
get_users(Server, _) ->
    get_users(Server, []).

count_users(Server, []) ->
    case mnesia:dirty_select(
	   reg_users_counter,
	   [{#reg_users_counter{vhost = Server, count = '$1'},
	     [], ['$1']}]) of
	[Count] -> Count;
	_ -> 0
    end;
count_users(Server, [{prefix, Prefix}]) when is_binary(Prefix) ->
    Set = [{U, S} || {U, S} <- get_users(Server, []), str:prefix(Prefix, U)],
    length(Set);
count_users(Server, _) ->
    count_users(Server, []).

get_password(User, Server) ->
    case mnesia:dirty_read(passwd, {User, Server}) of
	[#passwd{password = Password}] ->
	    {cache, {ok, Password}};
	_ ->
	    {cache, error}
    end.

get_passcode(User, Server) ->
    US = {User, Server},
    F = fun () ->
                case mnesia:read({enrolled_users, US}) of
                    [] ->
                        {error, invalid};
                    [#enrolled_users{passcode = Passcode}] ->
                        {ok, Passcode}
                end
        end,
    case mnesia:transaction(F) of
        {atomic, Res} ->
            Res;
        {aborted, Reason} ->
            ?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
            {error, db_failure}
    end.

-spec get_user_id(binary(), binary()) -> {ok, binary()} | {error, any()}.
get_user_id(User, Server) ->
    US = {User, Server},
    F = fun () ->
                case mnesia:read({user_ids, US}) of
                    [] ->
                        {error, invalid};
                    [#user_ids{id = Id}] ->
                        {ok, Id}
                end
        end,
    case mnesia:transaction(F) of
        {atomic, Res} ->
            Res;
        {aborted, Reason} ->
            ?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
            {error, db_failure}
    end.

-spec get_user_for_id(binary()) -> {ok, {binary(), binary()}} | {error, invalid}.
get_user_for_id(Id) ->
  F = fun () ->
        MatchHead = #user_ids{id = Id, _ = '_'},
        case mnesia:select(user_ids, [{MatchHead, [], ['$_']}]) of
            [] -> {error, invalid};
            [#user_ids{id = Id, username = US}] -> {ok, US}
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
        ?DEBUG("Successfully retrieved user: ~p for id: ~p, from user_ids", [Result, Id]),
        Result;
    {aborted, _Reason} ->
        ?ERROR_MSG("Failed retrieving user for id: ~p, from user_ids", [Id]),
        {error, invalid}
  end.


remove_user(User, Server) ->
    US = {User, Server},
    F = fun () ->
		mnesia:delete({passwd, US}),
		mnesia:dirty_update_counter(reg_users_counter, Server, -1),
		ok
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    ok;
	{aborted, Reason} ->
	    ?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
	    {error, db_failure}
    end.

remove_enrolled_user(User, Server) ->
    US = {User, Server},
    F = fun () ->
                mnesia:delete({enrolled_users, US}),
                ok
        end,
    case mnesia:transaction(F) of
        {atomic, ok} ->
            ok;
        {aborted, Reason} ->
            ?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
            {error, db_failure}
    end.

remove_user_id(User, Server) ->
	US = {User, Server},
    F = fun () ->
                mnesia:delete({user_ids, US}),
                ok
        end,
    case mnesia:transaction(F) of
        {atomic, ok} ->
            ok;
        {aborted, Reason} ->
            ?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
            {error, db_failure}
    end.

need_transform({enrolled_users, {_U, _S}, _Code}) ->
    false;
need_transform({user_ids, {_U, _S}, _Id}) ->
    false;
need_transform(#reg_users_counter{}) ->
    false;
need_transform({passwd, {U, S}, Pass}) ->
    if is_binary(Pass) ->
	    case store_type(S) of
		scram ->
		    ?INFO_MSG("Passwords in Mnesia table 'passwd' "
			      "will be SCRAM'ed", []),
		    true;
		plain ->
		    false
	    end;
       is_record(Pass, scram) ->
	    case store_type(S) of
		scram ->
		    false;
		plain ->
		    ?WARNING_MSG("Some passwords were stored in the database "
				 "as SCRAM, but 'auth_password_format' "
				 "is not configured as 'scram': some "
				 "authentication mechanisms such as DIGEST-MD5 "
				 "would *fail*", []),
		    false
	    end;
       is_list(U) orelse is_list(S) orelse is_list(Pass) ->
	    ?INFO_MSG("Mnesia table 'passwd' will be converted to binary", []),
	    true
    end.

transform({passwd, {U, S}, Pass})
  when is_list(U) orelse is_list(S) orelse is_list(Pass) ->
    NewUS = {iolist_to_binary(U), iolist_to_binary(S)},
    NewPass = case Pass of
		  #scram{storedkey = StoredKey,
			 serverkey = ServerKey,
			 salt = Salt} ->
		      Pass#scram{
			storedkey = iolist_to_binary(StoredKey),
			serverkey = iolist_to_binary(ServerKey),
			salt = iolist_to_binary(Salt)};
		  _ ->
		      iolist_to_binary(Pass)
	      end,
    transform(#passwd{us = NewUS, password = NewPass});
transform(#passwd{us = {U, S}, password = Password} = P)
  when is_binary(Password) ->
    case store_type(S) of
	scram ->
	    case jid:resourceprep(Password) of
		error ->
		    ?ERROR_MSG("SASLprep failed for password of user ~ts@~ts",
			       [U, S]),
		    P;
		_ ->
		    Scram = ejabberd_auth:password_to_scram(Password),
		    P#passwd{password = Scram}
	    end;
	plain ->
	    P
    end;
transform(#passwd{password = Password} = P)
  when is_record(Password, scram) ->
    P.

import(LServer, [LUser, Password, _TimeStamp]) ->
    mnesia:dirty_write(
      #passwd{us = {LUser, LServer}, password = Password}).