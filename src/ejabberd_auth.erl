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

-ifdef(TEST).
-export([ha_try_register/4]).
-endif.

%% External exports
-export([
    set_spub/2,
    check_spub/2,
    try_enroll/2,
    check_and_register/5,
    get_users/0,
    count_users/0,
    user_exists/1,
    remove_user/2
]).

-include("logger.hrl").
-include("password.hrl").
-include("account.hrl").
-include("sms.hrl").

-define(SALT_LENGTH, 16).
-define(HOST, util:get_host()).


%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

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
    {error, db_failure | not_allowed | exists | invalid_jid}.
check_and_register(Phone, Server, Cred, Name, UserAgent) ->
    case model_phone:get_uid(Phone) of
        {ok, undefined} ->
            case ha_try_register(Phone, Cred, Name, UserAgent) of
                {ok, _, UserId} ->
                    ejabberd_hooks:run(register_user, Server, [UserId, Server, Phone]),
                    {ok, UserId, register};
                Err -> Err
            end;
        {ok, UserId} ->
            re_register_user(UserId, Server, Phone),
            case set_spub(UserId, Cred) of
                ok ->
                    ok = model_accounts:set_name(UserId, Name),
                    ok = model_accounts:set_user_agent(UserId, UserAgent),
                    SessionCount = ejabberd_sm:kick_user(UserId, Server),
                    ?INFO("~p removed from ~p sessions", [UserId, SessionCount]),
                    {ok, UserId, login};
                Err -> Err
            end
    end.


-spec try_enroll(Phone :: binary(), Passcode :: binary()) -> {ok, binary()}.
try_enroll(Phone, Passcode) ->
    ?INFO("phone:~s code:~s", [Phone, Passcode]),
    {ok, AttemptId, Timestamp} = model_phone:add_sms_code2(Phone, Passcode),
    stat:count("HA/account", "enroll"),
    {ok, AttemptId, Timestamp}.


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


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

ha_try_register(Phone, Cred, Name, UserAgent) ->
    ?INFO("phone:~s", [Phone]),
    {ok, Uid} = util_uid:generate_uid(),
    ok = model_accounts:create_account(Uid, Phone, Name, UserAgent),
    ok = model_phone:add_phone(Phone, Uid),
    ok = set_spub(Uid, Cred),
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
    ok = model_auth:delete_spub(Uid),
    ok = model_accounts:delete_account(Uid),
    ok.


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


