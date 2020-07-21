%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%% Authentication and account creation functions for HalloApp.
%%% @end
%%% Created : 09. Apr 2020 2:29 PM
%%%-------------------------------------------------------------------
-module(ejabberd_auth_halloapp).
-author('nikola@halloapp.com').

-behaviour(ejabberd_auth).

-include("logger.hrl").
-include("password.hrl").
-include("account.hrl").
-include("sms.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-export([
    start/1,
    stop/1,
    try_register/3,
    remove_user/2,
    try_enroll/3,
    remove_enrolled_user/2,
    get_passcode/2,
    set_password/3,
    check_password/4,
    get_uid/1,
    get_phone/1,
    get_users/2,
    plain_password_required/1,
    store_type/1,
    count_users/2,
    user_exists/2
]).

%%% TODO: cleanup old Mnesia tables:
%%% passwd,
%%% enrolled_users,
%%% user_ids,
%%% reg_users_counter,
%%% user_phone,


%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(_Host) ->
    ok.

stop(_Host) ->
    ok.

plain_password_required(_Server) ->
    true.

store_type(_Server) ->
    external.


set_password(Uid, _Server, Password) ->
    ?INFO_MSG("uid:~s", [Uid]),
    {ok, Salt} = bcrypt:gen_salt(),
    {ok, HashedPassword} = hashpw(Password, Salt),
    model_auth:set_password(Uid, Salt, HashedPassword),
    {ok, Password}.


check_password(Uid, _AuthzId, _Server, Password) ->
    ?INFO_MSG("uid:~s", [Uid]),
    {ok, StoredPasswordRecord} = model_auth:get_password(Uid),
    HashedPassword = StoredPasswordRecord#password.hashed_password,
    case HashedPassword of
        undefined  -> ?INFO_MSG("No password stored for uid:~p", [Uid]);
        _ -> ok
    end,
    is_password_match(HashedPassword, Password).


try_register(Phone, Server, Password) ->
    ?INFO_MSG("phone:~s", [Phone]),
    {ok, UidInt} = util_uid:generate_uid(),
    Uid = util_uid:uid_to_binary(UidInt),
    % TODO: This is kind of stupid, but the name is set a bit later.
    % User agent is also set later, with the name.
    % This will get fixed when we merge this code with ejabberd_auth.
    Name = <<"">>,
    UserAgent = <<"">>,
    ok = model_accounts:create_account(Uid, Phone, Name, UserAgent),
    ok = model_phone:add_phone(Phone, Uid),
    {ok, Password} = set_password(Uid, Server, Password),
    {ok, Password, Uid}.


-spec try_enroll(Phone :: binary(), Server :: binary(), Passcode :: binary()) -> {ok, binary()}.
try_enroll(Phone, _Server, Passcode) ->
    ?INFO_MSG("phone:~s code:~s", [Phone, Passcode]),
    ok = model_phone:add_sms_code(Phone, Passcode, util:now(), ?TWILIO),
    stat:count("HA/account", "enroll"),
    {ok, Passcode}.


% TODO: delete
get_users(_Server, _Opt) ->
    ?ERROR_MSG("Unimplemented", []),
    [].


-spec count_users(Server :: binary(), Options :: any()) -> integer().
count_users(_Server, _) ->
    % TODO: implement user counter in redis
    ?ERROR_MSG("Unimplemented", []),
    0.


% TODO: API is not great. The model return makes more sense
-spec get_passcode(Phone :: binary(), _Server :: binary()) -> {ok, binary()} | {error, invalid}.
get_passcode(Phone, _Server) ->
    ?INFO_MSG("phone:~s", [Phone]),
    case model_phone:get_sms_code(Phone) of
        {ok, undefined} -> {error, invalid};
        {ok, Code} -> {ok, Code}
    end.


-spec user_exists(Uid :: binary(), Server :: binary()) -> boolean().
user_exists(Uid, _Server) ->
    Res = model_accounts:account_exists(Uid),
    ?INFO_MSG("uid:~s result: ~p", [Uid, Res]),
    Res.


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    ?INFO_MSG("uid:~s", [Uid]),
    case model_accounts:get_phone(Uid) of
        {ok, Phone} ->
            ok = model_phone:delete_phone(Phone);
        {error, missing} ->
            ok
    end,
    ok = model_auth:delete_password(Uid),
    ok = model_accounts:delete_account(Uid),
    ok.


-spec remove_enrolled_user(Phone :: binary(), Server :: binary()) -> ok.
remove_enrolled_user(Phone, _Server) ->
    ?INFO_MSG("phone:~s", [Phone]),
    ok = model_phone:delete_sms_code(Phone),
    ok.


-spec get_uid(Phone :: binary()) -> undefined | binary().
get_uid(Phone) ->
    {ok, Uid} = model_phone:get_uid(Phone),
    Uid.


-spec get_phone(Uid :: binary()) -> undefined | binary().
get_phone(Uid) ->
    case model_accounts:get_phone(Uid) of
        {ok, Phone} -> Phone;
        {error, missing} -> undefined
    end.

%%% ----------------------------------------------------------------
%%% Internal
%%% ----------------------------------------------------------------


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
