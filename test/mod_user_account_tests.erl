%%%-------------------------------------------------------------------
%%% File: mod_user_account_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_user_account_tests).
-author('murali').

-include("account.hrl").
-include("packets.hrl").

-include("tutil.hrl").

-define(UID1, <<"1">>).
-define(SERVER1, <<"s.halloapp.net">>).
-define(PHONE1, <<"+14703381473">>).
-define(PHONE2, <<"+4703381473">>).
-define(NORM_PHONE1, <<"14703381473">>).
-define(USERNAME1, <<"username1">>).
-define(USERNAME2, <<"username2">>).


setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    mod_libphonenumber:start(<<>>, <<>>),
    CleanupInfo = tutil:setup([
        {meck, model_accounts, get_account, fun(_) -> {ok, #account{phone = ?NORM_PHONE1, username = ?USERNAME1}} end},
        {meck, model_friends, get_friends, fun(_) -> {ok, []} end},
        {meck, model_contacts, get_contacts, fun(_) -> {ok, []} end},
        {meck, model_phone, get_uids, fun(_, _) -> #{} end},
        {meck, ha_events, log_event, fun(_, _) -> ok end},
        {meck, ejabberd_auth, remove_user, fun(_, _) -> ok end}
    ]),
    CleanupInfo.


create_delete_account_iq(Uid, _Server, Type, Phone, Username) ->
    #pb_iq{
        from_uid = Uid,
        type = Type,
        payload = #pb_delete_account{
                phone = Phone,
                username = Username
            }
    }.


user_account_test_() ->
    tutil:setup_once(fun setup/0, [fun delete_account_iq_phone/1, fun delete_account_iq_username/1, fun delete_account_iq_errors/1]).


delete_account_iq_phone(_) ->
    IQ = create_delete_account_iq(?UID1, ?SERVER1, set, ?PHONE1, undefined),
    IQRes = mod_user_account:process_local_iq(IQ),
    [?_assertEqual(ignore, IQRes)].


delete_account_iq_username(_) ->
    IQ = create_delete_account_iq(?UID1, ?SERVER1, set, undefined, ?USERNAME1),
    IQRes = mod_user_account:process_local_iq(IQ),
    [?_assertEqual(ignore, IQRes)].


delete_account_iq_errors(_) ->
    IQ1 = create_delete_account_iq(?UID1, ?SERVER1, get, undefined, undefined),
    IQRes1 = mod_user_account:process_local_iq(IQ1),

    IQ2 = create_delete_account_iq(?UID1, ?SERVER1, set, ?PHONE2, undefined),
    IQRes2 = mod_user_account:process_local_iq(IQ2),

    IQ3 = create_delete_account_iq(?UID1, ?SERVER1, set, undefined, ?USERNAME2),
    IQRes3 = mod_user_account:process_local_iq(IQ3),

    IQ4 = create_delete_account_iq(?UID1, ?SERVER1, set, undefined, undefined),
    IQRes4 = mod_user_account:process_local_iq(IQ4),

    [
        ?_assertEqual(util:err(invalid_request), tutil:get_error_iq_sub_el(IQRes1)),
        ?_assertEqual(util:err(invalid_phone_and_username), tutil:get_error_iq_sub_el(IQRes2)),
        ?_assertEqual(util:err(invalid_phone_and_username), tutil:get_error_iq_sub_el(IQRes3)),
        ?_assertEqual(util:err(invalid_phone_and_username), tutil:get_error_iq_sub_el(IQRes4))
    ].

