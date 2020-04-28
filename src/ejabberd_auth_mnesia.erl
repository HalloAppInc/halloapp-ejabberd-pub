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

-export([start/1, stop/1, set_password/3, try_register/3, try_register_internal/4,
	 get_users/2, init_db/0, get_users_with_passwd/1,
	 count_users/2, get_password/2, check_password/4,
	 remove_user/2, store_type/1, import/2,
	 plain_password_required/1, use_cache/1,
	 try_enroll/3, get_enrolled_users/1, get_enrolled_users_with_code/1,
	 remove_enrolled_user/2, get_passcode/2, get_uid/1, get_phone/1, user_exists/2
    ]).
-export([need_transform/1, transform/1]).

-include("logger.hrl").
-include("scram.hrl").
-include("ejabberd_auth.hrl").
-include("user_info.hrl").
-include("enrolled_users.hrl").

-record(reg_users_counter, {vhost = <<"">> :: binary(),
                            count = 0 :: integer() | '$1'}).


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
			 {attributes, record_info(fields, reg_users_counter)}]),
    ejabberd_mnesia:create(?MODULE, user_phone,
            [{disc_only_copies, [node()]},
             {index, [phone]},
             {attributes, record_info(fields, user_phone)}]),
    ok.

update_reg_users_counter_table(Server) ->
    Set = get_users(Server, []),
    Size = length(Set),
    LServer = jid:nameprep(Server),
    F = fun () ->
		mnesia:write(#reg_users_counter{vhost = LServer,
						count = Size})
	end,
    mnesia:sync_dirty(F).

use_cache(_Host) ->
    false.

plain_password_required(Server) ->
    store_type(Server) == scram.

store_type(_Server) ->
    plain.
%%    ejabberd_auth:password_format(Server).

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

try_register(Phone, Server, Password) ->
    {ok, Uid} = util_uid:generate_uid(),
    UserId = util_uid:uid_to_binary(Uid),
    try_register_internal(Phone, UserId, Server, Password).

try_register_internal(Phone, UserId, Server, Password) ->
    US = {UserId, Server},
    F = fun () ->
        case mnesia:read({passwd, US}) of
            [] ->
                mnesia:write(#passwd{us = US, password = Password}),
                mnesia:dirty_update_counter(reg_users_counter, Server, 1),
                insert_user_phone(UserId, Phone),
                {ok, Password, UserId};
            [_] ->
                {error, exists}
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Res} ->
            {cache, Res};
        {aborted, Reason} ->
            ?ERROR_MSG("Mnesia transaction failed: ~p", [Reason]),
            {nocache, {error, db_failure, Reason}}
    end.




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

check_password(User, _AuthzId, Server, ProvidedPassword) ->
    case get_password(User, Server) of
        {cache, {ok, StoredPassword}} ->
            {cache, ProvidedPassword == StoredPassword andalso ProvidedPassword /= <<"">>};
        {cache, error} ->
            {cache, false}
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


remove_user(User, Server) ->
    US = {User, Server},
    F = fun () ->
		mnesia:delete({passwd, US}),
		mnesia:dirty_update_counter(reg_users_counter, Server, -1),
		ok
	end,
    remove_enrolled_user(User, Server),
    remove_user_phone(User),
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

need_transform({enrolled_users, {_U, _S}, _Code}) ->
    false;
need_transform({user_ids, {_U, _S}, _Id}) ->
    false;
need_transform(#reg_users_counter{}) ->
    false;
need_transform(#user_phone{}) ->
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


-spec get_uid(Phone :: binary()) -> undefined | binary().
get_uid(Phone) ->
    F = fun () ->
            case mnesia:index_read(user_phone, Phone, #user_phone.phone) of
                [] -> undefined;
                [#user_phone{phone = Phone, uid = Uid}] -> Uid
            end
        end,
    case mnesia:transaction(F) of
        {atomic, Result} ->
            ?DEBUG("Successfully retrieved uid: ~p for phone: ~p, from user_phone", [Result, Phone]),
            Result;
        {aborted, Reason} ->
            ?ERROR_MSG("Failed retrieving user for phone: ~p, from user_phone ~p", [Phone, Reason]),
            {error, invalid, Reason}
    end.

-spec get_phone(Uid :: binary()) -> undefined | binary().
get_phone(Uid) ->
    F = fun () ->
            case mnesia:read(user_phone, Uid) of
                [] -> undefined;
                [#user_phone{phone = Phone, uid = Uid}] -> Phone
            end
        end,
    case mnesia:transaction(F) of
        {atomic, Result} ->
            ?DEBUG("Successfully retrieved phone: ~p for uid: ~p, from user_phone", [Result, Uid]),
            Result;
        {aborted, Reason} ->
            ?ERROR_MSG("Failed retrieving phone for uid: ~p, from user_phone ~p", [Uid, Reason]),
            {error, invalid}
    end.

-spec insert_user_phone(Uid :: binary(), Phone :: binary()) -> ok | {aborted, any()}.
insert_user_phone(Uid, Phone) ->
    mnesia:dirty_write(user_phone, #user_phone{uid = Uid, phone = Phone}).

-spec remove_user_phone(Uid :: binary()) -> ok.
remove_user_phone(Uid) ->
    mnesia:dirty_delete({user_phone, Uid}).


-spec user_exists(User :: binary(), Server :: binary()) -> boolean().
user_exists(User, Server) ->
    case mnesia:dirty_read(passwd, {User, Server}) of
        [#passwd{password = _Password}] -> true;
        _ -> false
    end.

