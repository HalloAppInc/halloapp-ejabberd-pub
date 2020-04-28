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
-include("scram.hrl").
-include("password.hrl").
-include("ejabberd_auth.hrl").
-include("user_info.hrl").
-include("enrolled_users.hrl").

-define(TWILIO, <<"twilio">>).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-export([
    start/1,
    stop/1,
    migrate_all/0,
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
    use_cache/1,
    count_users/2,
    user_exists/2
]).

%%% ---------------------------------------------------------------------
%%% Migration functions : TODO delete later
%%% ---------------------------------------------------------------------

verify_migration() ->
    %% TODO: implement
    ok.

migrate_all() ->
    ?INFO_MSG("start", []),
    %%% Tables to migrate:
    %%% passwd
    %%% enrolled_users
    %%% user_ids
    %%% user_phone

    {atomic, UserPhones} = mnesia:transaction(
        fun () ->
            mnesia:match_object(mnesia:table_info(user_phone, wild_pattern))
        end),
    lists:foreach(fun migrate_user/1, UserPhones),

    {atomic, EnrolledUsers} = mnesia:transaction(
        fun () ->
            mnesia:match_object(mnesia:table_info(enrolled_users, wild_pattern))
        end),
    lists:foreach(fun migrate_sms_codes/1, EnrolledUsers),

    {ok, length(UserPhones), length(EnrolledUsers)}.

migrate_user(#user_phone{uid = Uid, phone = Phone}) ->
    ?INFO_MSG("Migrating uid:~p phone: ~p", [Uid, Phone]),
    Exists = model_accounts:account_exists(Uid),
    case Exists of
        true ->
            ?INFO_MSG("account ~p exists, skipping", [Uid]);
        false ->
            do_migrate_user(Uid, Phone)
    end,
    ok.

%% TODO: delete the migration code after the migration is successful.
do_migrate_user(Uid, Phone) ->
    Server = <<"s.halloapp.net">>,
    Name = case model_accounts:get_name(Uid) of
               {ok, undefined} -> <<"">>;
               {ok, N} -> N
           end,
    ok = model_accounts:create_account(Uid, Phone, Name, "HalloApp/Android1.0.0"),
    ok = model_phone:add_phone(Phone, Uid),
    {cache, {ok, Password}} = ejabberd_auth_mnesia:get_password(Uid, Server),
    {cache, {ok, Password}} = set_password(Uid, Server, Password),
    ok.

migrate_sms_codes(#enrolled_users{username = {Phone, _Server}, passcode = Passcode}) ->
    ?INFO_MSG("Migrating sms codes for phone:~p code:~p", [Phone, Passcode]),
    ok = model_phone:add_sms_code(Phone, Passcode, util:now(), ?TWILIO),
    ok.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(Host) ->
    ejabberd_auth_mnesia:start(Host),
    ok.

stop(Host) ->
    ejabberd_auth_mnesia:stop(Host),
    ok.

use_cache(_Host) ->
    false.

%% TODO: Those 2 functions don't make much sense
plain_password_required(_Server) ->
    true.

store_type(_Server) ->
    external.

set_password(User, Server, Password) ->
    ?INFO_MSG("Uid:~p", [User]),
    Res = ejabberd_auth_mnesia:set_password(User, Server, Password),
    try set_password_internal(User, Server, Password) of
        Res2 ->
            check_result(set_password, User, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    Res.

set_password_internal(Uid, _Server, Password) ->
    {ok, Salt} = bcrypt:gen_salt(),
    %% TODO: Figure out how to configure the "log rounds"
    {ok, HashedPassword} = bcrypt:hashpw(Password, Salt),
    model_auth:set_password(Uid, Salt, HashedPassword),
    {cache, {ok, Password}}.

-spec hashpw(Password :: binary(), Salt :: string()) -> {ok, binary()}.
hashpw(Password, Salt) when is_binary(Password) and is_list(Salt) ->
    case bcrypt:hashpw(binary_to_list(Password), Salt) of
        {ok, Hash} -> {ok, list_to_binary(Hash)};
        Error -> Error
    end.

check_password(User, AuthzId, Server, Password) ->
    ?INFO_MSG("Uid:~p", [User]),
    Res = ejabberd_auth_mnesia:check_password(User, AuthzId, Server, Password),
    try check_password_internal(User, AuthzId, Server, Password) of
        Res2 ->
            check_result(check_password, User, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    Res.

check_password_internal(User, _AuthzId, _Server, Password) ->
    {ok, StoredPasswordRecord} = model_auth:get_password(User),
    HashedPassword = StoredPasswordRecord#password.hashed_password,
    case HashedPassword of
        undefined  -> ?INFO_MSG("No password stored for Uid:~p", [User]);
        _ -> ok
    end,
    {cache, is_password_match(HashedPassword, Password)}.

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

check_result(Function, Id, Res, Res2) ->
    case Res == Res2 of
        true ->
            ?INFO_MSG("~p check OK id:~p", [Function, Id]);
        false ->
            ?ERROR_MSG("~p checkfail id:~p, ~p --- ~p", [Function, Id, Res, Res2])
    end.

try_register(Phone, Server, Password) ->
    ?INFO_MSG("phone:~p", [Phone]),
    {ok, Uid} = util_uid:generate_uid(),
    UserId = util_uid:uid_to_binary(Uid),
    Res = ejabberd_auth_mnesia:try_register_internal(Phone, UserId, Server, Password),
    try try_register_internal(Phone, UserId, Server, Password) of
        Res2 -> check_result(try_register, UserId, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    Res.

try_register_internal(Phone, Uid, Server, Password) ->
    Name = <<"">>,
    UserAgent = <<"">>,
    ok = model_accounts:create_account(Uid, Phone, Name, UserAgent),
    ok = model_phone:add_phone(Phone, Uid),
    set_password_internal(Uid, Server, Password),
    {cache, {ok, Password, Uid}}.

%% TODO: Not sure about the enroll functions. The can go in sms module.
try_enroll(User, Server, Passcode) ->
    ?INFO_MSG("phone:~p", [User]),
    Res = ejabberd_auth_mnesia:try_enroll(User, Server, Passcode),
    try try_enroll_internal(User, Server, Passcode) of
        Res2 -> check_result(try_enroll, User, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    Res.

try_enroll_internal(User, _Server, Passcode) ->
    ok = model_phone:add_sms_code(User, Passcode, util:now(), ?TWILIO),
    {ok, Passcode}.

get_users(_Server, _Opt) ->
    ?ERROR_MSG("Unimplemented", []),
    [].

count_users(_Server, _) ->
    ?ERROR_MSG("Unimplemented", []),
    0.

get_passcode(User, Server) ->
    ?INFO_MSG("phone:~p", [User]),
    Res = ejabberd_auth_mnesia:get_passcode(User, Server),
    try get_passcode_internal(User, Server) of
        Res2 -> check_result(get_passcode, User, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    Res.

get_passcode_internal(Phone, _Server) ->
    case model_phone:get_sms_code(Phone) of
        {ok, undefined} -> {error, invalid};
        {ok, Code} -> {ok, Code}
    end.


user_exists(User, Server) ->
    ?INFO_MSG("UserId:~p", [User]),
    Res = ejabberd_auth_mnesia:user_exists(User, Server),
    try model_accounts:account_exists(User) of
        Res2 -> check_result(user_exists, User, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    {cache, Res}.


remove_user(User, Server) ->
    ?INFO_MSG("Uid:~p", [User]),
    Res = ejabberd_auth_mnesia:remove_user(User, Server),
    try remove_user_internal(User, Server) of
        Res2 -> check_result(remove_user, User, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    Res.

remove_user_internal(Uid, _Server) ->
    case model_accounts:get_phone(Uid) of
        {ok, Phone} ->
            ok = model_phone:delete_phone(Phone);
        {error, missing} ->
            ok
    end,
    ok = model_auth:delete_password(Uid),
    ok = model_accounts:delete_account(Uid),
    ok.

remove_enrolled_user(User, Server) ->
    ?INFO_MSG("Phone:~p", [User]),
    Res = ejabberd_auth_mnesia:remove_enrolled_user(User, Server),
    try remove_enrolled_user_internal(User, Server) of
        Res2 -> check_result(remove_enrolled_user, User, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    Res.

remove_enrolled_user_internal(Phone, _Server) ->
    ?INFO_MSG("phone:~p", [Phone]),
    ok = model_phone:delete_sms_code(Phone),
    ok.

-spec get_uid(Phone :: binary()) -> undefined | binary().
get_uid(Phone) ->
    Res = ejabberd_auth_mnesia:get_uid(Phone),
    try get_uid_internal(Phone) of
        Res2 -> check_result(get_uid, Phone, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    Res.

get_uid_internal(Phone) ->
    {ok, Uid} = model_phone:get_uid(Phone),
    Uid.

-spec get_phone(Uid :: binary()) -> undefined | binary().
get_phone(Uid) ->
    Res = ejabberd_auth_mnesia:get_phone(Uid),
    try get_phone_internal(Uid) of
        Res2 -> check_result(get_phone, Uid, Res, Res2)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    Res.

get_phone_internal(Uid) ->
    {ok, Phone} = model_accounts:get_phone(Uid),
    Phone.
