%%%------------------------------------------------------------------------------------
%%% File: ejabberd_auth.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% HalloApp auth file
%%%
%%%------------------------------------------------------------------------------------
-module(ejabberd_auth).
-author('alexey@process-one.net').
-author('josh').
-behaviour(gen_server).

%% External exports
-export([
    start_link/0,
    set_password/3,
    check_password/4,
    check_password/6,
    check_password_with_authmodule/4,
    check_password_with_authmodule/6,
    try_register/3,
    try_enroll/3,
    check_and_register/5,
    get_users/0,
    get_users/1,
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

-include("logger.hrl").
-include("password.hrl").
-include("account.hrl").
-include("sms.hrl").

-define(SALT_LENGTH, 16).
-define(HOST, util:get_host()).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-type digest_fun() :: fun((binary()) -> binary()).

-type opts() :: [{prefix, binary()} |
    {from, integer()} |
    {to, integer()} |
    {limit, integer()} |
    {offset, integer()}].

%%% TODO: cleanup old Mnesia tables:
%%% passwd,
%%% enrolled_users,
%%% user_ids,
%%% reg_users_counter,
%%% user_phone,

%% TODO: remove unused functions

%%%----------------------------------------------------------------------
%%% Gen Server API
%%%----------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init([]) ->
    start(?HOST),
    {ok, #{}}.


handle_call(Request, From, State) ->
    ?WARNING_MSG("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast(Msg, State) ->
    ?WARNING_MSG("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info(Info, State) ->
    ?WARNING_MSG("Unexpected info: ~p", [Info]),
    {noreply, State}.


terminate(_Reason, _State) ->
    stop(?HOST).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

start(_Host) ->
    ok.


stop(_Host) ->
    ok.


-spec plain_password_required(binary()) -> boolean().
plain_password_required(_Server) ->
    true.


-spec store_type(binary()) -> plain | scram | external.
store_type(_Server) ->
    external.


%% TODO: remote unecessary parameters from the check_password functions
-spec check_password(binary(), binary(), binary(), binary()) -> boolean().
check_password(User, AuthzId, Server, Password) ->
    check_password(User, AuthzId, Server, Password, <<"">>, undefined).


-spec check_password(binary(), binary(), binary(), binary(), binary(),
        digest_fun() | undefined) -> boolean().
check_password(User, AuthzId, Server, Password, Digest, DigestGen) ->
    case check_password_with_authmodule(User, AuthzId, Server, Password, Digest, DigestGen) of
        {true, _AuthModule} -> true;
        false -> false
    end.


-spec check_password_with_authmodule(binary(), binary(), binary(),
        binary()) -> false | {true, atom()}.
check_password_with_authmodule(User, AuthzId, Server, Password) ->
    check_password_with_authmodule(User, AuthzId, Server, Password, <<"">>, undefined).


-spec check_password_with_authmodule(binary(), binary(), binary(), binary(), binary(),
        digest_fun() | undefined) -> false | {true, atom()}.
check_password_with_authmodule(Uid, _AuthzId, _Server, Password, _Digest, _DigestGen) ->
    ?INFO_MSG("Uid:~s", [Uid]),
    {ok, StoredPasswordRecord} = model_auth:get_password(Uid),
    HashedPassword = StoredPasswordRecord#password.hashed_password,
    case HashedPassword of
        undefined  -> ?INFO_MSG("No password stored for uid:~p", [Uid]);
        _ -> ok
    end,
    case is_password_match(HashedPassword, Password) of
        true -> {true, ejabberd_auth_halloapp};
        false -> false
    end.


-spec set_password(binary(), binary(), binary()) -> ok |
        {error, db_failure | not_allowed |invalid_jid | invalid_password}.
set_password(Uid, _Server, Password) ->
    ?INFO_MSG("Uid:~s", [Uid]),
    {ok, Salt} = bcrypt:gen_salt(),
    {ok, HashedPassword} = hashpw(Password, Salt),
    model_auth:set_password(Uid, Salt, HashedPassword),
    ok.


-spec check_and_register(binary(), binary(), binary(), binary(), binary()) ->
    {ok, binary(), register | login} |
    {error, db_failure | not_allowed | exists | invalid_jid | invalid_password}.
check_and_register(Phone, Server, Password, Name, UserAgent) ->
    case model_phone:get_uid(Phone) of
        {ok, undefined} ->
            case ha_try_register(Phone, Server, Password, Name, UserAgent) of
                {ok, _, UserId} ->
                    ejabberd_hooks:run(register_user, Server, [UserId, Server, Phone]),
                    {ok, UserId, register};
                Err -> Err
            end;
        {ok, UserId} ->
            re_register_user(UserId, Server, Phone),
            case set_password(UserId, Server, Password) of
                ok ->
                    ok = model_accounts:set_name(UserId, Name),
                    ok = model_accounts:set_user_agent(UserId, UserAgent),
                    SessionCount = ejabberd_sm:kick_user(UserId, Server),
                    ?INFO_MSG("~p removed from ~p sessions", [UserId, SessionCount]),
                    {ok, UserId, login};
                Err -> Err
            end
    end.


-spec try_register(binary(), binary(), binary()) -> ok |
        {error, db_failure | not_allowed | exists | invalid_jid | invalid_password}.
try_register(Phone, Server, Password) ->
    case user_exists(Phone, Server) of
        true -> {error, exists};
        false ->
            case ejabberd_router:is_my_host(Server) of
                true ->
                    case ha_try_register(Phone, Server, Password, <<"">>, <<"">>) of
                        {ok, _, Uid}  ->
                            ejabberd_hooks:run(register_user, Server, [Uid, Server]);
                        {error, _} = Err -> Err
                    end;
                false -> {error, not_allowed}
            end
    end.


-spec try_enroll(Phone :: binary(), Server :: binary(), Passcode :: binary()) -> {ok, binary()}.
try_enroll(Phone, _Server, Passcode) ->
    ?INFO_MSG("phone:~s code:~s", [Phone, Passcode]),
    ok = model_phone:add_sms_code(Phone, Passcode, util:now(), ?TWILIO),
    stat:count("HA/account", "enroll"),
    {ok, Passcode}.


-spec get_users() -> [].
get_users() ->
    get_users(?HOST, []).

-spec get_users(binary()) -> [].
get_users(Server) ->
    get_users(Server, []).

-spec get_users(binary(), opts()) -> [].
get_users(_Server, _Opts) ->
    ?ERROR_MSG("Unimplemented", []),
    [].


-spec count_users(binary()) -> non_neg_integer().
count_users(Server) ->
    count_users(Server, []).

-spec count_users(binary(), opts()) -> non_neg_integer().
count_users(_Server, _Opts) ->
    model_accounts:count_accounts().


% this function is not implemented in the HA auth file, will always return false
-spec get_password(binary(), binary()) -> false | binary().
get_password(_User, _Server) ->
    false.


% this function is not implemented in the HA auth file
-spec get_password_s(binary(), binary()) -> binary().
get_password_s(User, Server) ->
    case get_password(User, Server) of
        false -> <<"">>;
        Password -> Password
    end.


% this function is not implemented in the HA auth file
-spec get_password_with_authmodule(binary(), binary()) -> {false | binary(), module()}.
get_password_with_authmodule(User, Server) ->
    {false, undefined}.


-spec user_exists(binary(), binary()) -> boolean().
user_exists(_User, <<"">>) ->
    false;

user_exists(User, _Server) ->
    case model_accounts:account_exists(User) of
        {error, _} = Err ->
            ?ERROR_MSG("Uid: ~s, Error: ~p", [User, Err]),
            false;
        Else ->
            ?INFO_MSG("Uid:~s Result: ~p", [User, Else]),
            Else
    end.


% function not implemented in HA auth file
-spec which_users_exists(list({binary(), binary()})) -> list({binary(), binary()}).
which_users_exists(USPairs) ->
    ByServer = lists:foldl(
        fun({User, Server}, Dict) ->
            case gb_trees:lookup(Server, Dict) of
                none -> gb_trees:insert(Server, gb_sets:singleton(User), Dict);
                {value, Set} -> gb_trees:update(Server, gb_sets:add(User, Set), Dict)
            end
        end,
        gb_trees:empty(),
        USPairs),
    Set = lists:foldl(
        fun({LServer, UsersSet}, Results) ->
            UsersList = gb_sets:to_list(UsersSet),
            try ejabberd_auth_halloapp:which_users_exists(LServer, UsersList) of
                {error, _} -> Results;
                Res ->
                    gb_sets:union(
                        gb_sets:from_list([{U, LServer} || U <- Res]),
                        Results)
            catch
                _:undef ->
                    lists:foldl(
                        fun(U, R2) ->
                            case user_exists(U, LServer) of
                                true -> gb_sets:add({U, LServer}, R2);
                                _ -> R2
                            end
                        end,
                        Results,
                        UsersList)
            end
        end,
        gb_sets:empty(),
        gb_trees:to_list(ByServer)),
    gb_sets:to_list(Set).


-spec re_register_user(User :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(User, Server, Phone) ->
    ejabberd_hooks:run(re_register_user, Server, [User, Server, Phone]).


-spec remove_user(binary(), binary()) -> ok.
remove_user(User, Server) ->
    ejabberd_hooks:run(remove_user, Server, [User, Server]),
    ha_remove_user(User, Server).


-spec remove_user(binary(), binary(), binary()) -> ok | {error, atom()}.
remove_user(User, Server, Password) ->
    case check_password(User, <<"">>, Server, Password) of
        true ->
            ok = ha_remove_user(User, Server),
            ejabberd_hooks:run(remove_user, Server, [User, Server]);
        false -> {error, not_allowed}
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
password_format(_LServer) ->
    plain.


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

-spec ha_try_register(binary(), binary(), binary(), binary(), binary()) ->
        {ok, binary(), binary()}.
ha_try_register(Phone, Server, Password, Name, UserAgent) ->
    ?INFO_MSG("Phone:~s", [Phone]),
    {ok, Uid} = util_uid:generate_uid(),
    ok = model_accounts:create_account(Uid, Phone, Name, UserAgent),
    ok = model_phone:add_phone(Phone, Uid),
    ok = ejabberd_auth:set_password(Uid, Server, Password),
    {ok, Password, Uid}.


-spec ha_remove_user(Uid :: binary(), Server :: binary()) -> ok.
ha_remove_user(Uid, _Server) ->
    ?INFO_MSG("Uid:~s", [Uid]),
    case model_accounts:get_phone(Uid) of
        {ok, Phone} ->
            ok = model_phone:delete_phone(Phone);
        {error, missing} ->
            ok
    end,
    ok = model_auth:delete_password(Uid),
    ok = model_accounts:delete_account(Uid),
    ok.


-spec hashpw(Password :: binary(), Salt :: string()) -> {ok, binary()}.
hashpw(Password, Salt) when is_binary(Password) and is_list(Salt) ->
    case bcrypt:hashpw(binary_to_list(Password), Salt) of
        {ok, Hash} -> {ok, list_to_binary(Hash)};
        Error -> Error
    end.


-spec is_password_match(
        HashedPassword :: binary() | undefined,
        ProvidedPassword :: binary() | undefined) -> boolean().
is_password_match(<<"">>, _ProvidedPassword) ->
    false;

is_password_match(undefined, _ProvidedPassword) ->
    false;

is_password_match(_HashedPassword, undefined) ->
    false;

is_password_match(HashedPassword, ProvidedPassword)
    when is_binary(HashedPassword) and is_binary(ProvidedPassword) ->
    HashedPasswordStr = binary_to_list(HashedPassword),
    {ok, HashedPassword} =:= hashpw(ProvidedPassword, HashedPasswordStr);

is_password_match(HashedPassword, ProvidedPassword) ->
    erlang:error(badarg, [util:type(HashedPassword), util:type(ProvidedPassword)]).


import_info() ->
    [{<<"users">>, 3}].


import_start(_LServer, _) ->
    ok.


import(_LServer, {sql, _}, mnesia, <<"users">>, _) ->
    ok;

import(_LServer, {sql, _}, sql, <<"users">>, _) ->
    ok.

