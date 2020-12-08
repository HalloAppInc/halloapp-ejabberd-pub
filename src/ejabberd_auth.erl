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

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% External exports
-export([
    start_link/0,
    set_password/2,
    check_password/2,
    set_spub/2,
    check_spub/2,
    try_register/3,
    try_enroll/2,
    check_and_register/5,
    check_and_register/6,
    get_users/0,
    count_users/0,
    user_exists/1,
    remove_user/2,
    remove_user/3,
    plain_password_required/0,
    store_type/0,
    password_format/0,
    process_auth_result/3
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("logger.hrl").
-include("password.hrl").
-include("account.hrl").
-include("sms.hrl").

-define(SALT_LENGTH, 16).
-define(HOST, util:get_host()).

-type set_cred_fun() :: fun((binary(), binary(), binary()) -> ok |
    {error, db_failure | not_allowed | invalid_jid | invalid_password}).

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
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


terminate(_Reason, _State) ->
    stop(?HOST).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


process_auth_result(State, true, Uid) ->
    ?INFO("Uid: ~p, auth_success", [Uid]),
    State;
process_auth_result(State,
        {false, _Reason}, Uid) ->
    ?INFO("Uid: ~p, auth_failure", [Uid]),
    case model_accounts:is_account_deleted(Uid) of
        true -> State#{account_deleted => true};
        false -> State
    end.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

start(Host) ->
    ejabberd_hooks:add(pb_c2s_auth_result, Host, ?MODULE, process_auth_result, 50),
    ok.


stop(Host) ->
    ejabberd_hooks:delete(pb_c2s_auth_result, Host, ?MODULE, process_auth_result, 50),
    ok.


-spec plain_password_required() -> boolean().
plain_password_required() ->
    true.


-spec store_type() -> plain | scram | external.
store_type() ->
    external.


-spec check_password(binary(), binary()) -> boolean().
check_password(Uid, Password) ->
    ?INFO("Uid:~s", [Uid]),
    {ok, StoredPasswordRecord} = model_auth:get_password(Uid),
    HashedPassword = StoredPasswordRecord#password.hashed_password,
    case HashedPassword of
        undefined  -> ?INFO("No password stored for uid:~p", [Uid]);
        _ -> ok
    end,
    is_password_match(HashedPassword, Password).


-spec set_password(binary(), binary()) -> ok |
        {error, db_failure | not_allowed |invalid_jid | invalid_password}.
set_password(Uid, Password) ->
    ?INFO("Uid:~s", [Uid]),
    {ok, Salt} = bcrypt:gen_salt(),
    {ok, HashedPassword} = hashpw(Password, Salt),
    model_auth:set_password(Uid, Salt, HashedPassword),
    ok.

-spec check_spub(binary(), binary()) -> false | true.
check_spub(Uid, SPub) ->
    ?INFO("uid:~s", [Uid]),
    {ok, SPubRecord} = model_auth:get_spub(Uid),
    StoredSPub = SPubRecord#s_pub.s_pub,
    case StoredSPub of
        undefined  -> ?INFO("No spub stored for uid:~p", [Uid]);
        _ -> ok
    end,
    is_spub_match(StoredSPub, SPub).


-spec set_spub(binary(), binary()) -> ok |
        {error, db_failure | not_allowed | invalid_jid}.
set_spub(Uid, SPub) ->
    ?INFO("uid:~s", [Uid]),
    model_auth:set_spub(Uid, SPub),
    ok.


-spec check_and_register(binary(), binary(), binary(), binary(), binary()) ->
    {ok, binary(), register | login} |
    {error, db_failure | not_allowed | exists | invalid_jid | invalid_password}.
check_and_register(Phone, Server, Cred, Name, UserAgent) ->
    check_and_register(Phone, Server, Cred, fun set_password/2, Name, UserAgent).


-spec check_and_register(binary(), binary(), binary(), set_cred_fun(), binary(), binary()) ->
    {ok, binary(), register | login} |
    {error, db_failure | not_allowed | exists | invalid_jid | invalid_password}.
check_and_register(Phone, Server, Cred, SetCredFn, Name, UserAgent) ->
    case model_phone:get_uid(Phone) of
        {ok, undefined} ->
            case ha_try_register(Phone, Cred, SetCredFn, Name, UserAgent) of
                {ok, _, UserId} ->
                    ejabberd_hooks:run(register_user, Server, [UserId, Server, Phone]),
                    {ok, UserId, register};
                Err -> Err
            end;
        {ok, UserId} ->
            re_register_user(UserId, Server, Phone),
            case SetCredFn(UserId, Cred) of
                ok ->
                    ok = model_accounts:set_name(UserId, Name),
                    ok = model_accounts:set_user_agent(UserId, UserAgent),
                    SessionCount = ejabberd_sm:kick_user(UserId, Server),
                    ?INFO("~p removed from ~p sessions", [UserId, SessionCount]),
                    {ok, UserId, login};
                Err -> Err
            end
    end.


-spec try_register(binary(), binary(), binary()) -> ok |
        {error, db_failure | not_allowed | exists | invalid_jid | invalid_password}.
try_register(Phone, Server, Password) ->
    case user_exists(Phone) of
        true -> {error, exists};
        false ->
            case ejabberd_router:is_my_host(Server) of
                true ->
                    case ha_try_register(Phone, Password, <<"">>, <<"">>) of
                        {ok, _, Uid}  ->
                            ejabberd_hooks:run(register_user, Server, [Uid, Server]);
                        {error, _} = Err -> Err
                    end;
                false -> {error, not_allowed}
            end
    end.


-spec try_enroll(Phone :: binary(), Passcode :: binary()) -> {ok, binary()}.
try_enroll(Phone, Passcode) ->
    ?INFO("phone:~s code:~s", [Phone, Passcode]),
    ok = model_phone:add_sms_code(Phone, Passcode, util:now(), ?TWILIO),
    stat:count("HA/account", "enroll"),
    {ok, Passcode}.


-spec get_users() -> [].
get_users() ->
    ?ERROR("Unimplemented", []),
    [].


-spec count_users() -> non_neg_integer().
count_users() ->
    model_accounts:count_accounts().


-spec user_exists(binary()) -> boolean().
user_exists(User) ->
    model_accounts:account_exists(User).


-spec re_register_user(User :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(User, Server, Phone) ->
    ejabberd_hooks:run(re_register_user, Server, [User, Server, Phone]).


-spec remove_user(binary(), binary()) -> ok.
remove_user(User, Server) ->
    ejabberd_hooks:run(remove_user, Server, [User, Server]),
    ha_remove_user(User).


-spec remove_user(binary(), binary(), binary()) -> ok | {error, atom()}.
remove_user(User, Server, Password) ->
    case check_password(User, Password) of
        true ->
            ok = ha_remove_user(User),
            ejabberd_hooks:run(remove_user, Server, [User, Server]);
        false -> {error, not_allowed}
    end.


-spec password_format() -> plain | scram.
password_format() ->
    plain.


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------


-spec ha_try_register(binary(), binary(), binary(), binary()) ->
        {ok, binary(), binary()}.
ha_try_register(Phone, Password, Name, UserAgent) ->
    ha_try_register(Phone, Password, fun set_password/2, Name, UserAgent).

ha_try_register(Phone, Cred, SetCredFn, Name, UserAgent) ->
    ?INFO("phone:~s", [Phone]),
    {ok, Uid} = util_uid:generate_uid(),
    ok = model_accounts:create_account(Uid, Phone, Name, UserAgent),
    ok = model_phone:add_phone(Phone, Uid),
    ok = SetCredFn(Uid, Cred),
    {ok, Cred, Uid}.


-spec ha_remove_user(Uid :: binary()) -> ok.
ha_remove_user(Uid) ->
    ?INFO("Uid:~s", [Uid]),
    case model_accounts:get_phone(Uid) of
        {ok, Phone} ->
            {ok, PhoneUid} = model_phone:get_uid(Phone),
            case PhoneUid =:= Uid of
                true ->
                    ok = model_phone:delete_phone(Phone);
                false ->
                    ?ERROR("uid mismatch for phone map Uid: ~s Phone: ~s PhoneUid: ~s",
                        [Uid, Phone, PhoneUid]),
                    ok
            end;
        {error, missing} ->
            ok
    end,
    ok = model_auth:delete_password(Uid),
    ok = model_auth:delete_spub(Uid),
    ok = model_accounts:delete_account(Uid),
    ok.


-spec hashpw(Password :: binary(), Salt :: string()) -> {ok, binary()}.
hashpw(Password, Salt) when is_binary(Password) and is_list(Salt) ->
    case bcrypt:hashpw(binary_to_list(Password), Salt) of
        {ok, Hash} -> {ok, list_to_binary(Hash)};
        Error -> Error
    end.


-spec is_spub_match(
        StoredSPub :: binary() | undefined,
        SPub :: binary() | undefined) -> boolean().
is_spub_match(<<"">>, _SPub) ->
    false;
is_spub_match(undefined, _SPub) ->
    false;
is_spub_match(StoredSPub, SPub) when StoredSPub =:= SPub ->
    true;
is_spub_match(_, _) ->
    false.

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

