%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Authentication
%%% Created : 23 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
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
-module(ejabberd_auth).
-author('alexey@process-one.net').
-behaviour(gen_server).

%% External exports
-export([
    start_link/0,
    host_up/1,
    host_down/1,
    config_reloaded/0,
    set_password/3,
    check_password/4,
    check_password/6,
    check_password_with_authmodule/4,
    check_password_with_authmodule/6,
    try_register/3,
    check_and_register/5,
    get_users/0,
    get_users/1,
    password_to_scram/1,
    get_users/2,
    import_info/0,
    count_users/1,
    import/5,
    import_start/2,
    count_users/2,
    get_password/2,
    get_password_s/2,
    get_password_with_authmodule/2,
    user_exists/2,
    user_exists_in_other_modules/3,
    remove_user/2,
    remove_user/3,
    plain_password_required/1,
    store_type/1,
    entropy/1,
    backend_type/1,
    password_format/1,
    which_users_exists/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([auth_modules/1]).

-include("scram.hrl").
-include("logger.hrl").

-define(SALT_LENGTH, 16).

-record(state, {host_modules = #{} :: host_modules()}).

-type host_modules() :: #{binary => [module()]}.
-type password() :: binary() | #scram{}.
-type digest_fun() :: fun((binary()) -> binary()).
-export_type([password/0]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-type opts() :: [{prefix, binary()} |
    {from, integer()} |
    {to, integer()} |
    {limit, integer()} |
    {offset, integer()}].

-callback start(binary()) -> any().
-callback stop(binary()) -> any().
-callback reload(binary()) -> any().
-callback plain_password_required(binary()) -> boolean().
-callback store_type(binary()) -> plain | external | scram.
-callback set_password(binary(), binary(), password()) ->
    {ok, password()} | {error, db_failure | not_allowed}.
-callback remove_user(binary(), binary()) -> ok | {error, db_failure | not_allowed}.
-callback user_exists(binary(), binary()) -> boolean() | {error, db_failure}.
-callback check_password(binary(), binary(), binary(), binary()) -> boolean() | {stop, boolean()}.
-callback try_register(binary(), binary(), password()) ->
    {ok, password()} | {error, exists | db_failure | not_allowed}.
-callback get_users(binary(), opts()) -> [{binary(), binary()}].
-callback count_users(binary(), opts()) -> number().
-callback get_password(binary(), binary()) -> {ok, password()} | error.

-optional_callbacks([
    reload/1,
    set_password/3,
    remove_user/2,
    user_exists/2,
    check_password/4,
    try_register/3,
    get_users/2,
    count_users/2,
    get_password/2
]).


-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
    ejabberd_hooks:add(host_up, ?MODULE, host_up, 30),
    ejabberd_hooks:add(host_down, ?MODULE, host_down, 80),
    ejabberd_hooks:add(config_reloaded, ?MODULE, config_reloaded, 40),
    HostModules = lists:foldl(
        fun(Host, Acc) ->
            Modules = auth_modules(Host),
            maps:put(Host, Modules, Acc)
        end, #{}, ejabberd_option:hosts()),
    lists:foreach(
        fun({Host, Modules}) ->
            start(Host, Modules)
        end, maps:to_list(HostModules)),
    {ok, #state{host_modules = HostModules}}.


handle_call(Request, From, State) ->
    ?WARNING_MSG("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.

handle_cast({host_up, Host}, #state{host_modules = HostModules} = State) ->
    Modules = auth_modules(Host),
    start(Host, Modules),
    NewHostModules = maps:put(Host, Modules, HostModules),
    {noreply, State#state{host_modules = NewHostModules}};

handle_cast({host_down, Host}, #state{host_modules = HostModules} = State) ->
    Modules = maps:get(Host, HostModules, []),
    stop(Host, Modules),
    NewHostModules = maps:remove(Host, HostModules),
    {noreply, State#state{host_modules = NewHostModules}};

handle_cast(config_reloaded, #state{host_modules = HostModules} = State) ->
    NewHostModules = lists:foldl(
        fun(Host, Acc) ->
            OldModules = maps:get(Host, HostModules, []),
            NewModules = auth_modules(Host),
            start(Host, NewModules -- OldModules),
            stop(Host, OldModules -- NewModules),
            reload(Host, misc:intersection(OldModules, NewModules)),
            maps:put(Host, NewModules, Acc)
        end,
        HostModules,
        ejabberd_option:hosts()),
    {noreply, State#state{host_modules = NewHostModules}};

handle_cast(Msg, State) ->
    ?WARNING_MSG("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info(Info, State) ->
    ?WARNING_MSG("Unexpected info: ~p", [Info]),
    {noreply, State}.


terminate(_Reason, State) ->
    ejabberd_hooks:delete(host_up, ?MODULE, host_up, 30),
    ejabberd_hooks:delete(host_down, ?MODULE, host_down, 80),
    ejabberd_hooks:delete(config_reloaded, ?MODULE, config_reloaded, 40),
    lists:foreach(
        fun({Host, Modules}) ->
            stop(Host, Modules)
        end,
        maps:to_list(State#state.host_modules)).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


start(Host, Modules) ->
    lists:foreach(fun(M) -> M:start(Host) end, Modules).


stop(Host, Modules) ->
    lists:foreach(fun(M) -> M:stop(Host) end, Modules).


reload(Host, Modules) ->
    lists:foreach(
        fun(M) ->
            case erlang:function_exported(M, reload, 1) of
                true -> M:reload(Host);
                false -> ok
            end
        end,
        Modules).


host_up(Host) ->
    gen_server:cast(?MODULE, {host_up, Host}).


host_down(Host) ->
    gen_server:cast(?MODULE, {host_down, Host}).


config_reloaded() ->
    gen_server:cast(?MODULE, config_reloaded).


-spec plain_password_required(binary()) -> boolean().
plain_password_required(Server) ->
    lists:any(
        fun(M) ->
            M:plain_password_required(Server)
        end,
        auth_modules(Server)).


-spec store_type(binary()) -> plain | scram | external.
store_type(Server) ->
    lists:foldl(
        fun
            (_, external) -> external;
            (M, scram) ->
                case M:store_type(Server) of
                    external -> external;
                    _ -> scram
                end;
            (M, plain) ->
                M:store_type(Server)
        end, plain, auth_modules(Server)).


-spec check_password(binary(), binary(), binary(), binary()) -> boolean().
check_password(User, AuthzId, Server, Password) ->
    check_password(User, AuthzId, Server, Password, <<"">>, undefined).


-spec check_password(binary(), binary(), binary(), binary(), binary(),
        digest_fun() | undefined) -> boolean().
check_password(User, AuthzId, Server, Password, Digest, DigestGen) ->
    case check_password_with_authmodule(
            User, AuthzId, Server, Password, Digest, DigestGen) of
        {true, _AuthModule} -> true;
        false -> false
    end.


-spec check_password_with_authmodule(binary(), binary(), binary(),
        binary()) -> false | {true, atom()}.
check_password_with_authmodule(User, AuthzId, Server, Password) ->
    check_password_with_authmodule(User, AuthzId, Server, Password, <<"">>, undefined).


-spec check_password_with_authmodule(binary(), binary(), binary(), binary(), binary(),
        digest_fun() | undefined) -> false | {true, atom()}.
check_password_with_authmodule(User, AuthzId, Server, Password, Digest, DigestGen) ->
    case validate_credentials(User, Server) of
        {ok, LUser, LServer} ->
            case jid:nodeprep(AuthzId) of
                error -> false;
                LAuthzId ->
                    untag_stop(
                        lists:foldl(
                            fun
                                (Mod, false) ->
                                    case db_check_password(
                                            LUser, LAuthzId, LServer, Password,
                                            Digest, DigestGen, Mod) of
                                        true -> {true, Mod};
                                        false -> false;
                                        {stop, true} -> {stop, {true, Mod}};
                                        {stop, false} -> {stop, false}
                                    end;
                                (_, Acc) -> Acc
                            end,
                            false,
                            auth_modules(LServer)))
            end;
        _ -> false
    end.


-spec set_password(binary(), binary(), password()) -> ok |
        {error, db_failure | not_allowed |invalid_jid | invalid_password}.
set_password(User, Server, Password) ->
    case validate_credentials(User, Server, Password) of
        {ok, LUser, LServer} ->
            lists:foldl(
                fun
                    (M, {error, _}) -> db_set_password(LUser, LServer, Password, M);
                    (_, ok) -> ok
                end,
                {error, not_allowed},
                auth_modules(LServer));
        Err -> Err
    end.


-spec check_and_register(binary(), binary(), password(), binary(), binary()) ->
        ok |{error, db_failure | not_allowed | exists | invalid_jid | invalid_password}.
check_and_register(Phone, Server, Password, Name, UserAgent) ->
    Password1 = case ejabberd_auth_halloapp:store_type(Server) of
        scram -> password_to_scram(Password);
        _ -> Password
    end,
    case ejabberd_auth_halloapp:get_uid(Phone) of
        undefined ->
            case ejabberd_auth_halloapp:try_register(Phone, Server, Password1) of
                {ok, _, UserId} ->
                    ok = model_accounts:set_name(UserId, Name),
                    ok = model_accounts:set_user_agent(UserId, UserAgent),
                    ejabberd_hooks:run(register_user, Server, [UserId, Server, Phone]),
                    {ok, UserId, register};
                Err -> Err
            end;
        UserId ->
            re_register_user(UserId, Server, Phone),
            case ejabberd_auth_halloapp:set_password(UserId, Server, Password1) of
                {ok, _} ->
                    ok = model_accounts:set_name(UserId, Name),
                    ok = model_accounts:set_user_agent(UserId, UserAgent),
                    SessionCount = ejabberd_sm:kick_user(UserId, Server),
                    ?INFO_MSG("~p removed from ~p sessions", [UserId, SessionCount]),
                    {ok, UserId, login};
                Err -> Err
            end
    end.


-spec try_register(binary(), binary(), password()) -> ok |
        {error, db_failure | not_allowed | exists | invalid_jid | invalid_password}.
try_register(User, Server, Password) ->
    case validate_credentials(User, Server, Password) of
        {ok, LUser, LServer} ->
            case user_exists(LUser, LServer) of
                true -> {error, exists};
                false ->
                    case ejabberd_router:is_my_host(LServer) of
                        true ->
                            case lists:foldl(
                                fun
                                    (_, ok) -> ok;
                                    (Mod, _) -> db_try_register(LUser, LServer, Password, Mod)
                                end,
                                {error, not_allowed},
                                auth_modules(LServer)) of
                                    ok -> ejabberd_hooks:run(
                                            register_user, LServer, [LUser, LServer]);
                                    {error, _} = Err -> Err
                            end;
                        false -> {error, not_allowed}
                    end
            end;
        Err -> Err
    end.


-spec get_users() -> [{binary(), binary()}].
get_users() ->
    lists:flatmap(
        fun({Host, Mod}) ->
            db_get_users(Host, [], Mod)
        end,
        auth_modules()).

-spec get_users(binary()) -> [{binary(), binary()}].
get_users(Server) ->
    get_users(Server, []).

-spec get_users(binary(), opts()) -> [{binary(), binary()}].
get_users(Server, Opts) ->
    case jid:nameprep(Server) of
        error -> [];
        LServer ->
            lists:flatmap(
                fun(M) ->
                    db_get_users(LServer, Opts, M)
                end,
                auth_modules(LServer))
    end.


-spec count_users(binary()) -> non_neg_integer().
count_users(Server) ->
    count_users(Server, []).

-spec count_users(binary(), opts()) -> non_neg_integer().
count_users(Server, Opts) ->
    case jid:nameprep(Server) of
        error -> 0;
        LServer ->
            lists:sum(
                lists:map(
                    fun(M) ->
                        db_count_users(LServer, Opts, M)
                    end,
                    auth_modules(LServer)))
    end.


-spec get_password(binary(), binary()) -> false | password().
get_password(User, Server) ->
    case validate_credentials(User, Server) of
        {ok, LUser, LServer} ->
            case lists:foldl(
                fun
                    (M, error) -> db_get_password(LUser, LServer, M);
                    (_M, Acc) -> Acc
                end,
                error,
                auth_modules(LServer)) of
                    {ok, Password} -> Password;
                    error -> false
            end;
        _ -> false
    end.


-spec get_password_s(binary(), binary()) -> password().
get_password_s(User, Server) ->
    case get_password(User, Server) of
        false -> <<"">>;
        Password -> Password
    end.


-spec get_password_with_authmodule(binary(), binary()) -> {false | password(), module()}.
get_password_with_authmodule(User, Server) ->
    case validate_credentials(User, Server) of
        {ok, LUser, LServer} ->
            case lists:foldl(
                fun
                    (M, {error, _}) -> {db_get_password(LUser, LServer, M), M};
                    (_M, Acc) -> Acc
                end,
                {error, undefined},
                auth_modules(LServer)) of
                    {{ok, Password}, Module} -> {Password, Module};
                    {error, Module} -> {false, Module}
            end;
        _ -> {false, undefined}
    end.


-spec user_exists(binary(), binary()) -> boolean().
user_exists(_User, <<"">>) ->
    false;

user_exists(User, Server) ->
    case validate_credentials(User, Server) of
        {ok, LUser, LServer} ->
            lists:any(
                fun(M) ->
                    case db_user_exists(LUser, LServer, M) of
                        {error, _} -> false;
                        Else -> Else
                    end
                end,
                auth_modules(LServer));
        _ -> false
    end.


-spec user_exists_in_other_modules(atom(), binary(), binary()) -> boolean() | maybe.
user_exists_in_other_modules(Module, User, Server) ->
    user_exists_in_other_modules_loop(
        auth_modules(Server) -- [Module], User, Server).

user_exists_in_other_modules_loop([], _User, _Server) ->
    false;

user_exists_in_other_modules_loop([AuthModule | AuthModules], User, Server) ->
    case db_user_exists(User, Server, AuthModule) of
        true -> true;
        false -> user_exists_in_other_modules_loop(AuthModules, User, Server);
        {error, _} -> maybe
    end.


-spec which_users_exists(list({binary(), binary()})) -> list({binary(), binary()}).
which_users_exists(USPairs) ->
    ByServer = lists:foldl(
        fun({User, Server}, Dict) ->
            LServer = jid:nameprep(Server),
            LUser = jid:nodeprep(User),
            case gb_trees:lookup(LServer, Dict) of
                none -> gb_trees:insert(LServer, gb_sets:singleton(LUser), Dict);
                {value, Set} -> gb_trees:update(LServer, gb_sets:add(LUser, Set), Dict)
            end
        end,
        gb_trees:empty(),
        USPairs),
    Set = lists:foldl(
        fun({LServer, UsersSet}, Results) ->
            UsersList = gb_sets:to_list(UsersSet),
            lists:foldl(
                fun(M, Results2) ->
                    try M:which_users_exists(LServer, UsersList) of
                        {error, _} -> Results2;
                        Res ->
                            gb_sets:union(
                                gb_sets:from_list([{U, LServer} || U <- Res]),
                                Results2)
                    catch
                        _:undef ->
                            lists:foldl(
                                fun(U, R2) ->
                                    case user_exists(U, LServer) of
                                        true -> gb_sets:add({U, LServer}, R2);
                                        _ -> R2
                                    end
                                end,
                                Results2,
                                UsersList)
                    end
                end,
                Results,
                auth_modules(LServer))
        end,
        gb_sets:empty(),
        gb_trees:to_list(ByServer)),
    gb_sets:to_list(Set).


-spec remove_user(binary(), binary()) -> ok.
remove_user(User, Server) ->
    case validate_credentials(User, Server) of
        {ok, LUser, LServer} ->
            ejabberd_hooks:run(remove_user, LServer, [LUser, LServer]),
            lists:foreach(
                fun(Mod) ->
                    db_remove_user(LUser, LServer, Mod)
                end,
                auth_modules(LServer));
        _Err -> ok
    end.


-spec re_register_user(User :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(User, Server, Phone) ->
    ejabberd_hooks:run(re_register_user, Server, [User, Server, Phone]).


-spec remove_user(binary(), binary(), password()) -> ok | {error, atom()}.
remove_user(User, Server, Password) ->
    case validate_credentials(User, Server, Password) of
        {ok, LUser, LServer} ->
            case lists:foldl(
                fun
                    (_, ok) -> ok;
                    (Mod, _) ->
                        case db_check_password(
                                LUser, <<"">>, LServer, Password, <<"">>, undefined, Mod) of
                            true -> db_remove_user(LUser, LServer, Mod);
                            {stop, true} -> db_remove_user(LUser, LServer, Mod);
                            false -> {error, not_allowed};
                            {stop, false} -> {error, not_allowed}
                    end
                end,
                {error, not_allowed},
                auth_modules(Server)) of
                    ok -> ejabberd_hooks:run(remove_user, LServer, [LUser, LServer]);
                    Err -> Err
            end;
        Err -> Err
    end.


%% @doc Calculate informational entropy.
-spec entropy(iodata()) -> float().
entropy(B) ->
    case binary_to_list(B) of
        "" -> 0.0;
        S ->
            Set = lists:foldl(
                fun(C, [Digit, Printable, LowLetter, HiLetter, Other]) ->
                    if
                        C >= $a, C =< $z -> [Digit, Printable, 26, HiLetter, Other];
                        C >= $0, C =< $9 -> [9, Printable, LowLetter, HiLetter, Other];
                        C >= $A, C =< $Z -> [Digit, Printable, LowLetter, 26, Other];
                        C >= 33, C =< 126 -> [Digit, 33, LowLetter, HiLetter, Other];
                        true -> [Digit, Printable, LowLetter, HiLetter, 128]
                    end
                end,
                [0, 0, 0, 0, 0],
                S),
            length(S) * math:log(lists:sum(Set)) / math:log(2)
    end.


-spec backend_type(atom()) -> atom().
backend_type(Mod) ->
    case atom_to_list(Mod) of
        "ejabberd_auth_" ++ T -> list_to_atom(T);
        _ -> Mod
    end.


-spec password_format(binary() | global) -> plain | scram.
password_format(LServer) ->
    ejabberd_option:auth_password_format(LServer).


%%%----------------------------------------------------------------------
%%% Backend calls
%%%----------------------------------------------------------------------

-spec db_try_register(binary(), binary(), password(), module()) -> ok |
        {error, exists | db_failure | not_allowed}.
db_try_register(User, Server, Password, Mod) ->
    case erlang:function_exported(Mod, try_register, 3) of
        true ->
            Password1 = case Mod:store_type(Server) of
                scram -> password_to_scram(Password);
                _ -> Password
            end,
            case Mod:try_register(User, Server, Password1) of
                {ok, _} -> ok;
                {error, _} = Err -> Err
            end;
        false -> {error, not_allowed}
    end.


-spec db_set_password(binary(), binary(), password(), module()) -> ok | {error, db_failure | not_allowed}.
db_set_password(User, Server, Password, Mod) ->
    case erlang:function_exported(Mod, set_password, 3) of
        true ->
            Password1 = case Mod:store_type(Server) of
                scram -> password_to_scram(Password);
                _ -> Password
            end,
            case Mod:set_password(User, Server, Password1) of
                {ok, _} -> ok;
                {error, _} = Err -> Err
            end;
        false -> {error, not_allowed}
    end.


db_get_password(User, Server, Mod) ->
    case erlang:function_exported(Mod, get_password, 2) of
        false -> error;
        true -> Mod:get_password(User, Server)
    end.


db_user_exists(User, Server, Mod) ->
    case db_get_password(User, Server, Mod) of
        {ok, _} -> true;
        error ->
            case Mod:store_type(Server) of
                external -> Mod:user_exists(User, Server);
                _ -> false
            end
    end.

db_check_password(User, AuthzId, Server, ProvidedPassword, Digest, DigestFun, Mod) ->
    case db_get_password(User, Server, Mod) of
        {ok, ValidPassword} -> match_passwords(ProvidedPassword, ValidPassword, Digest, DigestFun);
        error ->
            case Mod:store_type(Server) of
                external -> Mod:check_password(User, AuthzId, Server, ProvidedPassword);
                _ -> false
            end
    end.


db_remove_user(User, Server, Mod) ->
    case erlang:function_exported(Mod, remove_user, 2) of
        true ->
            case Mod:remove_user(User, Server) of
                ok -> ok;
                {error, _} = Err -> Err
            end;
        false -> {error, not_allowed}
    end.


db_get_users(Server, Opts, Mod) ->
    case erlang:function_exported(Mod, get_users, 2) of
        true -> Mod:get_users(Server, Opts);
        false -> []
    end.


db_count_users(Server, Opts, Mod) ->
    case erlang:function_exported(Mod, count_users, 2) of
        true -> Mod:count_users(Server, Opts);
        false -> 0
    end.

%%%----------------------------------------------------------------------
%%% SCRAM stuff
%%%----------------------------------------------------------------------

is_password_scram_valid(Password, Scram) ->
    case jid:resourceprep(Password) of
        error -> false;
        _ ->
            IterationCount = Scram#scram.iterationcount,
            Salt = base64:decode(Scram#scram.salt),
            SaltedPassword = scram:salted_password(Password, Salt, IterationCount),
            StoredKey = scram:stored_key(scram:client_key(SaltedPassword)),
            base64:decode(Scram#scram.storedkey) == StoredKey
    end.


password_to_scram(Password) ->
    password_to_scram(Password, ?SCRAM_DEFAULT_ITERATION_COUNT).

password_to_scram(#scram{} = Password, _IterationCount) ->
    Password;

password_to_scram(Password, IterationCount) ->
    Salt = p1_rand:bytes(?SALT_LENGTH),
    SaltedPassword = scram:salted_password(Password, Salt, IterationCount),
    StoredKey = scram:stored_key(scram:client_key(SaltedPassword)),
    ServerKey = scram:server_key(SaltedPassword),
    #scram{storedkey = base64:encode(StoredKey),
        serverkey = base64:encode(ServerKey),
        salt = base64:encode(Salt),
        iterationcount = IterationCount}.


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

-spec auth_modules() -> [{binary(), module()}].
auth_modules() ->
    lists:flatmap(
        fun(Host) ->
            [{Host, Mod} || Mod <- auth_modules(Host)]
        end,
        ejabberd_option:hosts()).

-spec auth_modules(binary()) -> [module()].
auth_modules(Server) ->
    LServer = jid:nameprep(Server),
    Methods = ejabberd_option:auth_method(LServer),
    Modules = [ejabberd:module_name([<<"ejabberd">>, <<"auth">>, misc:atom_to_binary(M)])
        || M <- Methods],
    ?INFO_MSG("auth_modules ~p", [Modules]),
    Modules.


-spec match_passwords(password(), password(), binary(), digest_fun() | undefined) -> boolean().
match_passwords(Password, #scram{} = Scram, <<"">>, undefined) ->
    is_password_scram_valid(Password, Scram);

match_passwords(Password, #scram{} = Scram, Digest, DigestFun) ->
    StoredKey = base64:decode(Scram#scram.storedkey),
    DigRes = if
        Digest /= <<"">> -> Digest == DigestFun(StoredKey);
        true -> false
    end,
    if DigRes ->
        true;
        true -> StoredKey == Password andalso Password /= <<"">>
    end;

match_passwords(ProvidedPassword, ValidPassword, <<"">>, undefined) ->
    ProvidedPassword == ValidPassword andalso ProvidedPassword /= <<"">>;

match_passwords(ProvidedPassword, ValidPassword, Digest, DigestFun) ->
    DigRes = if
        Digest /= <<"">> -> Digest == DigestFun(ValidPassword);
        true -> false
    end,
    if DigRes ->
        true;
        true -> ValidPassword == ProvidedPassword andalso ProvidedPassword /= <<"">>
    end.


-spec validate_credentials(binary(), binary()) -> {ok, binary(), binary()} | {error, invalid_jid}.
validate_credentials(User, Server) ->
    validate_credentials(User, Server, #scram{}).

-spec validate_credentials(binary(), binary(), password()) ->
        {ok, binary(), binary()} | {error, invalid_jid | invalid_password}.
validate_credentials(_User, _Server, <<"">>) ->
    {error, invalid_password};

validate_credentials(User, Server, Password) ->
    case jid:nodeprep(User) of
        error -> {error, invalid_jid};
        LUser ->
            case jid:nameprep(Server) of
                error -> {error, invalid_jid};
                LServer ->
                    if
                        is_record(Password, scram) -> {ok, LUser, LServer};
                        true ->
                            case jid:resourceprep(Password) of
                                error -> {error, invalid_password};
                                _ -> {ok, LUser, LServer}
                            end
                    end
            end
    end.


untag_stop({stop, Val}) -> Val;
untag_stop(Val) -> Val.


import_info() ->
    [{<<"users">>, 3}].


import_start(_LServer, _) ->
    ok.


import(_LServer, {sql, _}, mnesia, <<"users">>, _) ->
    ok;

import(_LServer, {sql, _}, sql, <<"users">>, _) ->
    ok.

