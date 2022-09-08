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
-export([ha_try_register/5]).
-endif.

%% External exports
-export([
    set_spub/2,
    check_spub/2,
    try_enroll/3,
    check_and_register/6,
    get_users/0,
    count_users/0,
    user_exists/1,
    remove_user/2
]).

-include("logger.hrl").
-include("password.hrl").
-include("account.hrl").
-include("sms.hrl").
-include("monitor.hrl").
-include_lib("stdlib/include/assert.hrl").

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
        {error, any()}.
set_spub(Uid, SPub) ->
    ?INFO("uid:~s", [Uid]),
    model_auth:set_spub(Uid, SPub).


check_and_register(Phone, Host, SPub, Name, UserAgent, CampaignId) ->
    ?assert(byte_size(SPub) > 0),
    Result = check_and_register_internal(Phone, Host, SPub, Name, UserAgent, CampaignId),
    case Result of
        {ok, Uid, login} ->
            ?INFO("Login into existing account uid:~p for phone:~p", [Uid, Phone]),
            {ok, Uid, login};
        {ok, Uid, register} ->
            ?INFO("Registering new account uid:~p for phone:~p", [Uid, Phone]),
            {ok, Uid, register};
        {error, Reason} ->
            ?INFO("Login/Registration for phone:~p failed. ~p", [Phone, Reason]),
            {error, Reason}
    end.


-spec try_enroll(Phone :: binary(), Passcode :: binary(), CampaignId :: binary()) -> {ok, binary(), integer()}.
try_enroll(Phone, Passcode, CampaignId) ->
    ?INFO("phone:~s code:~s", [Phone, Passcode]),
    {ok, AttemptId, Timestamp} = model_phone:add_sms_code2(Phone, Passcode, CampaignId),
    case Phone of
        ?MONITOR_PHONE -> ok;
        _ -> stat:count("HA/account", "enroll")
    end,
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


-spec re_register_user(User :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
re_register_user(User, Server, Phone, CampaignId) ->
    ejabberd_hooks:run(re_register_user, Server, [User, Server, Phone, CampaignId]).


-spec remove_user(binary(), binary()) -> ok.
remove_user(User, Server) ->
    ejabberd_hooks:run(remove_user, Server, [User, Server]),
    ha_remove_user(User).


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

-spec check_and_register_internal(binary(), binary(), binary(), binary(), binary(), binary()) ->
    {ok, binary(), register | login} |
    {error, db_failure | not_allowed | exists | invalid_jid}.
check_and_register_internal(Phone, Server, Cred, Name, UserAgent, CampaignId) ->
    case model_phone:get_uid(Phone) of
        {ok, undefined} ->
            case ha_try_register(Phone, Cred, Name, UserAgent, CampaignId) of
                {ok, _, UserId} ->
                    ejabberd_hooks:run(register_user, Server, [UserId, Server, Phone, CampaignId]),
                    {ok, UserId, register};
                Err -> Err
            end;
        {ok, UserId} ->
            re_register_user(UserId, Server, Phone, CampaignId),
            case set_spub(UserId, Cred) of
                ok ->
                    ok = model_accounts:set_name(UserId, Name),
                    ok = model_accounts:set_user_agent(UserId, UserAgent),
                    ok = model_accounts:set_last_registration_ts_ms(UserId, util:now_ms()),
                    SessionCount = ejabberd_sm:kick_user(UserId, Server),
                    ?INFO("~p removed from ~p sessions", [UserId, SessionCount]),
                    {ok, UserId, login};
                Err -> Err
            end
    end.


ha_try_register(Phone, Cred, Name, UserAgent, CampaignId) ->
    ?INFO("phone:~s", [Phone]),
    {ok, Uid} = util_uid:generate_uid(),
    ok = model_accounts:create_account(Uid, Phone, Name, UserAgent, CampaignId),
    ok = model_phone:add_phone(Phone, Uid),
    case set_spub(Uid, Cred) of
        ok ->{ok, Cred, Uid};
        Err -> Err
    end.


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


